import Foundation
import SwiftData

@Model
final class DownloadedModel {
    var id: UUID
    var name: String
    var author: String
    var variant: String
    var format: String
    var sizeBytes: Int64
    var relativePath: String
    var downloadedAt: Date
    var status: ModelStatus
    
    var errorMessage: String = ""
    
    @Relationship(deleteRule: .cascade)
    var transcriptions: [Transcription]?
    
    init(name: String, author: String, variant: String, format: String, sizeBytes: Int64, relativePath: String, status: ModelStatus = .ready) {
        self.id = UUID()
        self.name = name
        self.author = author
        self.variant = variant
        self.format = format
        self.sizeBytes = sizeBytes
        self.relativePath = relativePath
        self.downloadedAt = Date()
        self.status = status
    }
    
    /// Full resolved path at runtime — survives app updates since we store relative.
    var fullPath: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent(relativePath)
    }
    
    var displayName: String {
        "\(author)/\(name)"
    }
}

enum ModelStatus: String, Codable, CaseIterable {
    case downloading
    case ready
    case failed
    case verifying
}
