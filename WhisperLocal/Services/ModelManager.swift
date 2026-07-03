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

    func listVariants(repoId: String) async throws -> [ModelVariant] {
        try await hfService.listModelVariants(repoId: repoId)
    }

    // MARK: - Download

    func downloadModel(
        _ hfModel: HFModel,
        variant: ModelVariant,
        progressHandler: @MainActor @escaping (Double) -> Void
    ) async throws -> DownloadedModel {
        let localURL = try await hfService.downloadFile(
            repoId: hfModel.modelId,
            fileName: variant.fileName,
            progressHandler: progressHandler
        )

        let fileSize = variant.fileSize ?? (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0

        return DownloadedModel(
            name: hfModel.displayName,
            repoId: hfModel.modelId,
            fileName: variant.fileName,
            localPath: localURL.path,
            fileSizeBytes: fileSize
        )
    }

    func downloadModelWithProgress(
        _ hfModel: HFModel,
        variant: ModelVariant
    ) async throws -> (DownloadedModel, AsyncThrowingStream<Double, Error>) {
        let stream = await hfService.downloadFileWithProgress(repoId: hfModel.modelId, fileName: variant.fileName)

        // Compute the expected local path upfront (must match HuggingFaceService)
        let safeName = variant.fileName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let localPath = modelsDirectory.appendingPathComponent(safeName).path

        let displayName = variant.quantization != "Default"
            ? hfModel.displayName + " (\(variant.quantization))"
            : hfModel.displayName

        let model = DownloadedModel(
            name: displayName,
            repoId: hfModel.modelId,
            fileName: variant.fileName,
            localPath: localPath,
            fileSizeBytes: variant.fileSize ?? 0
        )

        return (model, stream)
    }

    // MARK: - Management

    func deleteModel(_ model: DownloadedModel) throws {
        // Try direct path
        let url = URL(fileURLWithPath: model.localPath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Try safe name path
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

    func listLocalModels() -> [URL] {
        var result: [URL] = []
        guard let contents = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) else {
            return result
        }
        result = contents
        return result
    }
}
