import Foundation
import SwiftData

@Model
final class DownloadedModel {
    var id: UUID
    var name: String
    var repoId: String
    var fileName: String
    var localPath: String
    var fileSizeBytes: Int64
    var downloadedAt: Date
    var isDefault: Bool
    var modelSource: String
    
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
    
    var localURL: URL {
        URL(fileURLWithPath: localPath)
    }
    
    init(name: String, repoId: String, fileName: String, localPath: String, fileSizeBytes: Int64, modelSource: String = "huggingface") {
        self.id = UUID()
        self.name = name
        self.repoId = repoId
        self.fileName = fileName
        self.localPath = localPath
        self.fileSizeBytes = fileSizeBytes
        self.downloadedAt = Date()
        self.isDefault = false
        self.modelSource = modelSource
    }
}
