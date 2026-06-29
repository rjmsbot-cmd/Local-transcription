import Foundation
import SwiftData

/// Manages model downloads, local storage, and lifecycle.
actor ModelManager {
    private let hfService = HuggingFaceService()
    
    var modelsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    // MARK: - Search
    
    func searchModels(query: String) async throws -> [HFModel] {
        try await hfService.searchModels(query: query)
    }
    
    func getPopularModels() async throws -> [HFModel] {
        try await hfService.getPopularWhisperModels()
    }
    
    // MARK: - Download
    
    func downloadModel(
        _ hfModel: HFModel,
        progressHandler: @MainActor @escaping (Double) -> Void
    ) async throws -> DownloadedModel {
        guard let file = try await hfService.findBestModelFile(repoId: hfModel.modelId) else {
            throw HFError.noCompatibleFile
        }
        
        let localURL = try await hfService.downloadFile(
            repoId: hfModel.modelId,
            fileName: file.path,
            progressHandler: progressHandler
        )
        
        let fileSize = file.size ?? (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        
        return DownloadedModel(
            name: hfModel.displayName,
            repoId: hfModel.modelId,
            fileName: file.path,
            localPath: localURL.path,
            fileSizeBytes: fileSize
        )
    }
    
    func downloadModelWithProgress(_ hfModel: HFModel) async throws -> (DownloadedModel, AsyncThrowingStream<Double, Error>) {
        guard let file = try await hfService.findBestModelFile(repoId: hfModel.modelId) else {
            throw HFError.noCompatibleFile
        }
        
        let stream = await hfService.downloadFileWithProgress(repoId: hfModel.modelId, fileName: file.path)
        
        let modelsDir = modelsDirectory
        let safeName = file.path.replacingOccurrences(of: "/", with: "_")
        let localPath = modelsDir.appendingPathComponent(safeName).path
        let fileSize = file.size ?? 0
        
        let model = DownloadedModel(
            name: hfModel.displayName,
            repoId: hfModel.modelId,
            fileName: file.path,
            localPath: localPath,
            fileSizeBytes: fileSize
        )
        
        return (model, stream)
    }
    
    // MARK: - Management
    
    func deleteModel(_ model: DownloadedModel) throws {
        let url = URL(fileURLWithPath: model.localPath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Also try the models directory
        let alt = modelsDirectory.appendingPathComponent(model.fileName.replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: alt.path) {
            try FileManager.default.removeItem(at: alt)
        }
    }
    
    func getLocalFileSize(_ model: DownloadedModel) -> Int64 {
        let url = URL(fileURLWithPath: model.localPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return attrs[.size] as? Int64 ?? 0
    }
    
    func fileExists(_ model: DownloadedModel) -> Bool {
        FileManager.default.fileExists(atPath: model.localPath)
    }
}
