import Foundation
import SwiftData
import SwiftUI

@MainActor
final class ModelManager: ObservableObject {
    @Published var downloadedModels: [DownloadedModel] = []
    /// Search hits with a per-repo compatibility signal (see
    /// HuggingFaceService.classifySearchResults). Sorted installable-first.
    @Published var availableModels: [ModelSearchResult] = []
    @Published var recommendedModels: [ModelSearchResult] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var diskSpaceAvailable: String = ""
    /// True once the user has run a search; drives whether the Models tab
    /// shows search results or the initial "Recomendados" list.
    @Published var hasSearched = false

    /// Monotonic counter to discard stale search results: every search
    /// bumps it; a search whose results arrive after a newer search started
    /// (or after its Task was cancelled mid-request) sees a mismatched
    /// generation and drops its output instead of clobbering the UI
    /// (Ronda 14 — this race made the search look "broken" when typing
    /// fast: a cancelled request's error/empty state overwrote the results
    /// of the search the user actually saw).
    private var searchGeneration = 0
    
    private let modelDirName = "WhisperModels"
    private let modelContext: ModelContext
    private var batchCompletedObserver: NSObjectProtocol?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadLocalModels(context: modelContext)
        updateDiskSpace()
        // A download that finished while the app was closed (background
        // session) is picked up here: flip .downloading → .ready and
        // re-arm anything still pending.
        reconcileDownloads(context: modelContext)
        // Also reconcile when a background batch completes while the app
        // is open (e.g. the user closed the download sheet earlier).
        batchCompletedObserver = NotificationCenter.default.addObserver(
            forName: .modelBatchCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.reconcileDownloads(context: self.modelContext)
            }
        }
        Task { await loadRecommendations() }
    }

    deinit {
        if let batchCompletedObserver {
            NotificationCenter.default.removeObserver(batchCompletedObserver)
        }
    }
    
    func updateDiskSpace() {
        diskSpaceAvailable = DiskSpace.availableFormatted()
    }
    
    // MARK: - Local Models
    
    func loadLocalModels(context: ModelContext) {
        let desc = FetchDescriptor<DownloadedModel>()
        downloadedModels = (try? context.fetch(desc)) ?? []
    }
    
    /// Flips models that finished downloading in the background (while the
    /// app was closed) from `.downloading` to `.ready`, and backfills the
    /// tokenizer that the foreground path would have fetched. Called on
    /// manager creation.
    func reconcileDownloads(context: ModelContext) {
        let completed = BackgroundDownloadManager.shared.consumeCompletedBatches()
        guard !completed.isEmpty else { return }
        for model in downloadedModels where model.status == .downloading {
            guard completed.contains("\(model.name)#\(model.variant)") else { continue }
            Task {
                if let size = HuggingFaceService.tokenizerSize(from: model.variant.isEmpty ? model.name : model.variant),
                   let folder = model.fullPath {
                    try? await HuggingFaceService.shared.downloadTokenizerFiles(
                        modelSize: size,
                        destinationURL: folder,
                        progress: { _, _ in }
                    )
                }
                model.status = .ready
                try? context.save()
            }
        }
    }

    /// Re-runs a failed download by re-enqueuing the persisted batch
    /// (files already on disk are skipped). Used by the row's "Reintentar".
    func retryDownload(_ model: DownloadedModel, context: ModelContext) async throws {
        guard let folder = model.fullPath else { throw HFError.notFound }
        model.status = .downloading
        model.errorMessage = ""
        try context.save()
        do {
            let allFiles = try await HuggingFaceService.shared.listAllFiles(
                repoId: model.name,
                path: model.variant
            )
            let fileItems = allFiles
                .filter { !$0.isDirectory }
                .filter { model.variant.isEmpty ? Self.isWhisperKitModelFile($0.path) : true }
            let destinationDir = model.variant.isEmpty ? folder : folder.deletingLastPathComponent()
            let total = try await BackgroundDownloadManager.shared.enqueueBatch(
                repoId: model.name,
                variant: model.variant,
                destinationDir: destinationDir,
                files: fileItems,
                progress: nil
            )
            model.sizeBytes = total
            model.status = .ready
            try context.save()
        } catch {
            model.status = .failed
            model.errorMessage = error.localizedDescription
            try? context.save()
            throw error
        }
    }

    func addLocalModel(
        name: String, author: String, variant: String,
        format: String, sizeBytes: Int64, relativePath: String,
        status: ModelStatus = .ready,
        context: ModelContext
    ) throws {
        let model = DownloadedModel(
            name: name, author: author, variant: variant,
            format: format, sizeBytes: sizeBytes,
            relativePath: relativePath, status: status
        )
        context.insert(model)
        try context.save()
        downloadedModels.append(model)
    }
    
    func removeModel(_ model: DownloadedModel, context: ModelContext) throws {
        // Delete files on disk
        if let path = model.fullPath {
            try? FileManager.default.removeItem(at: path)
        }
        context.delete(model)
        try context.save()
        downloadedModels.removeAll { $0.id == model.id }
    }
    
    func totalSize() -> Int64 {
        downloadedModels.reduce(0) { $0 + $1.sizeBytes }
    }
    
    // MARK: - Search

    /// Known WhisperKit-CoreML repos that actually ship CoreML bundles
    /// (.mlmodelc) WhisperKit can load — curated so the search always
    /// surfaces installable options, regardless of HF's name-based search.
    /// Only `argmaxinc/whisperkit-coreml` is currently public & ungated
    /// (Ronda 14: nickmcdonald/openb3/LucasLarson return 401 — gated — so
    /// they were removed instead of showing a green "compatible" badge and
    /// then failing at download).
    static let curatedWhisperKitRepos = [
        "argmaxinc/whisperkit-coreml"      // canonical (8M+ downloads)
    ]

    /// Builds an `HFRepoInfo` for a curated repo id (no extra network call).
    static func curatedRepo(_ repoId: String) -> HFRepoInfo {
        let parts = repoId.split(separator: "/")
        return HFModel(
            id: repoId,
            modelId: repoId,
            author: parts.first.map(String.init) ?? "",
            pipelineTag: "automatic-speech-recognition",
            tags: ["coreml", "whisper"],
            downloads: nil,
            likes: nil,
            lastModified: nil
        )
    }

    /// True when the query plausibly targets Whisper/CoreML models, or when
    /// it directly names one of the curated repos ("nickmcdonald", …).
    static func curatedRepoMatchesQuery(_ repoId: String, query: String) -> Bool {
        let q = query.lowercased()
        let whisperHints = ["whisper", "coreml", "turbo", "large", "v3", "distil", "base", "small", "medium", "argmax", "rápido", "rapido", "realtime", "asr", "voz", "transcribir"]
        if whisperHints.contains(where: { q.contains($0) }) { return true }
        let lower = repoId.lowercased()
        return q.split(separator: " ").contains { lower.contains($0) }
    }
    
    func searchModels(query: String, coreMLOnly: Bool = true) async {
        searchGeneration += 1
        let generation = searchGeneration
        hasSearched = true
        isLoading = true
        errorMessage = nil
        do {
            // Sort by downloads (most popular first) for ASR relevance
            let results = try await HuggingFaceService.shared.searchModels(
                query: query,
                coreMLOnly: coreMLOnly,
                sort: "downloads",
                direction: "-1"
            )
            // A newer search superseded us while the network call was in
            // flight: drop these results entirely (Ronda 14).
            guard generation == searchGeneration else { return }
            // Every hit gets a compatibility signal from a cheap top-level
            // probe (cached 10 min), sorted installable-first. Repos that
            // WhisperKit cannot load (Qwen3-ASR, Parakeet, Nemotron...) are
            // ranked last and surfaced with a clear "not compatible" badge
            // instead of silently opening an empty variant picker.
            let classified = await HuggingFaceService.shared.classifySearchResults(results)
            guard generation == searchGeneration else { return }
            // Ronda 12: HF search is by NAME, so "whisper large v3" never
            // returns argmaxinc/whisperkit-coreml (its name has none of those
            // tokens) — the one repo every Whisper user needs was invisible.
            // Inject the known WhisperKit-CoreML repos (curated, .compatible)
            // whenever the query sounds Whisper-ish, deduped vs HF hits.
            let curated = Self.curatedWhisperKitRepos.compactMap { repoId -> ModelSearchResult? in
                guard !classified.contains(where: { $0.model.modelId == repoId }) else { return nil }
                if Self.curatedRepoMatchesQuery(repoId, query: query) {
                    return ModelSearchResult(model: Self.curatedRepo(repoId), status: .compatible)
                }
                return nil
            }
            availableModels = curated + classified
            isLoading = false
        } catch is CancellationError {
            // Task was cancelled (user kept typing / cleared the field):
            // never surface "cancelled" as an error. A newer search owns
            // the UI now.
            guard generation == searchGeneration else { return }
            availableModels = []
            isLoading = false
        } catch let urlError as URLError where urlError.code == .cancelled {
            guard generation == searchGeneration else { return }
            availableModels = []
            isLoading = false
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = error.localizedDescription
            availableModels = []
            isLoading = false
        }
    }
    
    /// Back to the initial state: clears search results and shows the
    /// "Recomendados" section again.
    func resetSearch() {
        hasSearched = false
        availableModels = []
        errorMessage = nil
        isLoading = false
    }
    
    /// Loads the initial "Recomendados" list (most-downloaded CoreML ASR
    /// models). Failures are surfaced through `errorMessage` only while the
    /// user hasn't searched yet, so a failed recommendation fetch can't
    /// clobber search results.
    func loadRecommendations() async {
        guard !hasSearched else { return }
        do {
            let models = try await HuggingFaceService.shared.fetchRecommendedModels()
            // Round 6: keep only WhisperKit-loadable repos (the Hub's
            // top CoreML ASR downloads include Parakeet/Qwen/Nemotron,
            // which WhisperKit 0.9.4 cannot load). Each hit gets the same
            // compatibility signal as search results.
            let filtered = models.filter { $0.isCoreML && !$0.isIncompatibleArchitecture }
            recommendedModels = await HuggingFaceService.shared.classifySearchResults(filtered)
        } catch {
            if !hasSearched {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    // MARK: - Download
    
    /// Downloads a CoreML model bundle.
    ///
    /// - Parameters:
    ///   - repo: the Hugging Face repo.
    ///   - variant: the **actual directory name** inside the repo that
    ///     contains the model bundle (e.g. `openai_whisper-base` or
    ///     `whisper-base.mlpackage`). For Qwen ASR multi-component models
    ///     this can be a quantization dir like `f32/` or empty (root).
    ///     The old code invented `<repoId>.mlpackage`, which does not exist
    ///     in most repos, so the download always 404'd.
    func downloadModel(
        _ repo: HFRepoInfo,
        variant: String,
        context: ModelContext,
        progress: ((Double, String) -> Void)? = nil
    ) async throws -> DownloadedModel {
        // Round 6: never download repos WhisperKit cannot load (Qwen3-ASR,
        // Parakeet, Nemotron...). The variant picker already filters them,
        // but this is defense in depth for any future code path.
        guard !repo.isIncompatibleArchitecture else {
            throw HFError.incompatibleModel
        }
        let safeName = sanitizePathComponent(repo.modelId)
        let relativePath = "\(modelDirName)/\(safeName)/\(variant)"
        
        // The search API no longer returns `author`; derive it from the
        // model id (e.g. "argmaxinc/whisperkit-coreml_01-30-24" →
        // "argmaxinc") so display names stay readable.
        let author = repo.author ?? repo.modelId.split(separator: "/").first.map(String.init) ?? ""
        
        // Create DownloadedModel entry
        let model = DownloadedModel(
            name: repo.modelId,
            author: author,
            variant: variant,
            format: "coreml",
            sizeBytes: 0,
            relativePath: relativePath,
            status: .downloading
        )
        context.insert(model)
        try context.save()
        downloadedModels.append(model)
        
        // The destination is the models root; files land under
        // <root>/<variant>/... preserving the repo-relative layout.
        let modelsRoot = documentsDirectory().appendingPathComponent(modelDirName)
        let localDir = modelsRoot.appendingPathComponent(safeName)
        
        do {
            // Pre-flight: list the whole variant with a single recursive
            // tree call. Fails fast ("repositorio no encontrado") when the
            // variant is empty, and checks disk space against the REAL
            // total size instead of an arbitrary floor.
            let allFiles = try await HuggingFaceService.shared.listAllFiles(
                repoId: repo.modelId,
                path: variant
            )
            // Root-bundle repos (variant == "") mix the model files with
            // unrelated repo content (README, .gitattributes, .safetensors
            // weights for other formats...). Only download what WhisperKit
            // actually needs, so "instalar la raíz" never drags in GBs of
            // junk. Named variants are already just the model folder.
            let fileItems = allFiles
                .filter { !$0.isDirectory }
                .filter { variant.isEmpty ? Self.isWhisperKitModelFile($0.path) : true }
            guard !fileItems.isEmpty else {
                throw HFError.notFound
            }
            let totalBytes = fileItems.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
            _ = try DiskSpace.ensureSpace(for: max(totalBytes + 50 * 1024 * 1024, 200 * 1024 * 1024))
            
            // Background transfer: the batch survives app termination, so
            // closing the app no longer kills a multi-GB download — and a
            // model is only marked .ready when EVERY file is on disk.
            let downloadedBytes = try await BackgroundDownloadManager.shared.enqueueBatch(
                repoId: repo.modelId,
                variant: variant,
                destinationDir: localDir,
                files: fileItems,
                progress: { fraction, phase in
                    progress?(fraction, phase)
                }
            )
            
            // WhisperKit loads the tokenizer from the model folder if
            // tokenizer.json exists there; otherwise it falls back to a
            // network download, which breaks offline loading. The CoreML
            // bundles on the Hub (argmaxinc etc.) do NOT ship a tokenizer,
            // so fetch it from the matching openai/whisper-* repo.
            // Qwen ASR models include vocab.json in the repo.
            let modelFolder = localDir.appendingPathComponent(variant)
            // For root-bundle repos the variant is empty; fall back to the
            // repo id to detect the model size.
            let sizeSource = variant.isEmpty ? repo.modelId : variant
            if let size = HuggingFaceService.tokenizerSize(from: sizeSource) {
                try? await HuggingFaceService.shared.downloadTokenizerFiles(
                    modelSize: size,
                    destinationURL: modelFolder,
                    progress: { fraction, phase in
                        progress?(fraction, phase)
                    }
                )
            }
            
            // Update status with the real downloaded size
            model.sizeBytes = downloadedBytes
            model.status = .ready
            try context.save()
        } catch {
            model.status = .failed
            model.errorMessage = error.localizedDescription
            try context.save()
            throw error
        }
        
        return model
    }
    
    // MARK: - Helpers
    
    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private func sanitizePathComponent(_ input: String) -> String {
        input.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }
    
    /// Files WhisperKit needs when a CoreML bundle lives at the repo root:
    /// the three compiled model artifacts (.mlmodelc/.mlpackage trees),
    /// config.json and the tokenizer files. Everything else (READMEs,
    /// .safetensors, .onnx, .gitattributes…) is unrelated to loading and is
    /// skipped to keep root installs lean.
    static func isWhisperKitModelFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        let support = [
            "config.json", "tokenizer.json", "vocab.json", "merges.txt",
            "added_tokens.json", "special_tokens_map.json", "tokenizer_config.json",
            "normalizer.json"
        ]
        if support.contains(where: { lower == $0 || lower.hasSuffix("/" + $0) }) { return true }
        if lower.contains(".mlmodelc") || lower.contains(".mlpackage") { return true }
        return ["melspectrogram", "audioencoder", "textdecoder"].contains {
            lower.contains($0 + ".ml")
        }
    }
}
