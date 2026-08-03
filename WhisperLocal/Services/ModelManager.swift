import Foundation
import SwiftData
import SwiftUI

@MainActor
final class ModelManager: ObservableObject {
    @Published var downloadedModels: [DownloadedModel] = []
    @Published var availableModels: [HFRepoInfo] = []
    @Published var recommendedModels: [HFRepoInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var diskSpaceAvailable: String = ""
    /// True once the user has run a search; drives whether the Models tab
    /// shows search results or the initial "Recomendados" list.
    @Published var hasSearched = false
    
    private let modelDirName = "WhisperModels"
    
    init(modelContext: ModelContext) {
        loadLocalModels(context: modelContext)
        updateDiskSpace()
        Task { await loadRecommendations() }
    }
    
    func updateDiskSpace() {
        diskSpaceAvailable = DiskSpace.availableFormatted()
    }
    
    // MARK: - Local Models
    
    func loadLocalModels(context: ModelContext) {
        let desc = FetchDescriptor<DownloadedModel>()
        downloadedModels = (try? context.fetch(desc)) ?? []
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
    
    func searchModels(query: String, coreMLOnly: Bool = true) async {
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
            // Round 6: never offer repos WhisperKit cannot load (Qwen3-ASR,
            // Parakeet, Nemotron...). They download fine but fail at load.
            availableModels = results.filter { !$0.isIncompatibleArchitecture }
        } catch {
            errorMessage = error.localizedDescription
            availableModels = []
        }
        isLoading = false
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
            // which WhisperKit 0.9.4 cannot load).
            recommendedModels = models.filter { $0.isCoreML && !$0.isIncompatibleArchitecture }
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
            
            // For Qwen multi-component models (variant="" or quant dir like
            // "f32/"), we must download ALL files under that path to get
            // the complete model (encoder + decoder + embedding).
            // For WhisperKit variants, the variant folder already contains
            // everything needed.
            let downloadedBytes = try await HuggingFaceService.shared.downloadFiles(
                repoId: repo.modelId,
                files: fileItems,
                destinationURL: localDir,
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
            if let size = Self.tokenizerSize(from: sizeSource) {
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

    /// Maps a variant folder name (e.g. `openai_whisper-base`,
    /// `whisper-large-v3-turbo`) to the matching `openai/whisper-*` repo
    /// suffix used for the tokenizer files.
    static func tokenizerSize(from variant: String) -> String? {
        let lower = variant.lowercased()
        if lower.contains("large-v3-turbo") { return "large-v3-turbo" }
        if lower.contains("large-v3") { return "large-v3" }
        if lower.contains("large-v2") { return "large-v2" }
        if lower.contains("large") { return "large" }
        if lower.contains("medium") { return "medium" }
        if lower.contains("small") { return "small" }
        if lower.contains("base") { return "base" }
        if lower.contains("tiny") { return "tiny" }
        return nil
    }
}
