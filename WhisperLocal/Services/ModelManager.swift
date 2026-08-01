import Foundation
import SwiftData
import SwiftUI

@MainActor
final class ModelManager: ObservableObject {
    @Published var downloadedModels: [DownloadedModel] = []
    @Published var availableModels: [HFRepoInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var diskSpaceAvailable: String = ""
    
    private let modelDirName = "WhisperModels"
    
    init(modelContext: ModelContext) {
        loadLocalModels(context: modelContext)
        updateDiskSpace()
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
    
    func searchModels(query: String) async {
        isLoading = true
        errorMessage = nil
        do {
            availableModels = try await HuggingFaceService.shared.searchModels(query: query)
        } catch {
            errorMessage = error.localizedDescription
            availableModels = []
        }
        isLoading = false
    }
    
    // MARK: - Download
    
    /// Downloads a CoreML model bundle.
    ///
    /// - Parameters:
    ///   - repo: the Hugging Face repo.
    ///   - variant: the **actual directory name** inside the repo that
    ///     contains the model bundle (e.g. `openai_whisper-base` or
    ///     `whisper-base.mlpackage`). The old code invented
    ///     `<repoId>.mlpackage`, which does not exist in most repos, so the
    ///     download always 404'd.
    func downloadModel(
        _ repo: HFRepoInfo,
        variant: String,
        context: ModelContext,
        progress: ((Double, String) -> Void)? = nil
    ) async throws -> DownloadedModel {
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
            // Floor check only; the real total is recorded after the download.
            _ = try DiskSpace.ensureSpace(for: 200 * 1024 * 1024)
            
            let downloadedBytes = try await HuggingFaceService.shared.downloadDirectory(
                repoId: repo.modelId,
                directoryPath: variant,
                expectedSha256: nil,
                destinationURL: localDir,
                progress: { fraction, phase in
                    progress?(fraction, phase)
                }
            )
            
            guard downloadedBytes > 0 else {
                throw HFError.notFound
            }
            
            // WhisperKit loads the tokenizer from the model folder if
            // tokenizer.json exists there; otherwise it falls back to a
            // network download, which breaks offline loading. The CoreML
            // bundles on the Hub (argmaxinc etc.) do NOT ship a tokenizer,
            // so fetch it from the matching openai/whisper-* repo.
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
