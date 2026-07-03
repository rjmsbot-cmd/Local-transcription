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
    
    func downloadModel(
        _ repo: HFRepoInfo,
        variant: String,
        context: ModelContext
    ) async throws -> DownloadedModel {
        // Check disk space first
        let estimatedSize: Int64 = 2_000_000_000 // ~2GB estimate for Core ML Whisper
        _ = try DiskSpace.ensureSpace(for: estimatedSize)
        
        let safeName = sanitizePathComponent(repo.modelId)
        let relativePath = "\(modelDirName)/\(safeName)/\(variant)"
        
        // Create DownloadedModel entry
        let model = DownloadedModel(
            name: repo.modelId,
            author: repo.author,
            variant: variant,
            format: "coreml",
            sizeBytes: estimatedSize,
            relativePath: relativePath,
            status: .downloading
        )
        context.insert(model)
        try context.save()
        downloadedModels.append(model)
        
        let localDir = try documentsDirectory().appendingPathComponent(relativePath)
        
        do {
            // Download the .mlpackage directory tree
            let mlPackageDir = "\(variant).mlpackage"
            _ = try await HuggingFaceService.shared.downloadDirectory(
                repoId: repo.modelId,
                remoteDir: mlPackageDir,
                to: localDir,
                progress: { _ in }
            )
            
            // Update status
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
}
