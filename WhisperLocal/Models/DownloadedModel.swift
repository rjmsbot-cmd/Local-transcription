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
    var isDefault: Bool = false
    
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
        if author.isEmpty {
            return name
        }
        // Avoid double author when `name` already contains it
        if name.hasPrefix("\(author)/") {
            return name
        }
        return "\(author)/\(name)"
    }

    /// Whether the downloaded folder actually contains the three artifacts
    /// WhisperKit's loadModels() requires (MelSpectrogram, AudioEncoder and
    /// TextDecoder as .mlmodelc/.mlpackage bundles).
    ///
    /// Folders from incompatible architectures (e.g. Qwen3-ASR, downloaded
    /// before the Round 6 filter) fail this check and are flagged in the
    /// UI instead of offering a broken "Cargar" button.
    var isWhisperKitCompatibleFolder: Bool {
        guard let url = fullPath else { return false }
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            contents.contains {
                $0.hasPrefix(name) && ($0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage"))
            }
        }
    }
}

enum ModelStatus: String, Codable, CaseIterable {
    case downloading
    case ready
    case failed
    case verifying
}
