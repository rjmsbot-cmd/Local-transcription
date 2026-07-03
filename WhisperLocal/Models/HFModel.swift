import Foundation

// MARK: - HuggingFace API Models

struct HFModel: Identifiable, Codable, Hashable {
    let id: String
    let modelId: String
    let author: String?
    let pipelineTag: String?
    let tags: [String]?
    let downloads: Int
    let likes: Int
    let lastModified: String?
    
    var displayName: String {
        modelId.split(separator: "/").last.map(String.init) ?? modelId
    }
    
    var isWhisperCompatible: Bool {
        let lower = modelId.lowercased()
        return tags?.contains("whisper") == true ||
               pipelineTag == "automatic-speech-recognition" ||
               lower.contains("whisper") ||
               lower.contains("asr")
    }

    /// Whether this model likely has Core ML variants (based on tags/name)
    var likelyHasCoreML: Bool {
        let lower = modelId.lowercased()
        let tagLower = tags?.map { $0.lowercased() } ?? []
        return tagLower.contains("coreml") ||
               tagLower.contains("core-ml") ||
               lower.contains("coreml") ||
               lower.contains("core-ml") ||
               lower.contains("openai/whisper") ||
               lower.contains("dtlarry") ||
               lower.contains("alvanlee")
    }

    
    enum CodingKeys: String, CodingKey {
        case id, modelId, author, pipelineTag, tags, downloads, likes, lastModified
    }
}

struct HFFileItem: Codable {
    let path: String
    let type: String
    let size: Int64?
    let lfs: HFLFSInfo?
    
    var isDirectory: Bool { type == "directory" }
    
    var isCoreML: Bool {
        path.hasSuffix(".mlpackage") || path.hasSuffix(".mlmodelc")
    }
    
    var isGGUF: Bool { path.hasSuffix(".gguf") }
    
    var isModelFile: Bool {
        path.hasSuffix(".bin") || path.hasSuffix(".pt") || 
        path.hasSuffix(".onnx") || isCoreML || isGGUF ||
        path.hasSuffix(".mlmodel")
    }
}

struct HFLFSInfo: Codable {
    let oid: String?
    let size: Int64?
    let pointerSize: Int?
}

// MARK: - Model Variant Types

enum ModelFormat: String, Codable, Hashable, CaseIterable {
    case coreML
    case gguf
    case onnx
    case bin
    case pt
    
    var icon: String {
        switch self {
        case .coreML: return "brain.head.profile"
        case .gguf: return "doc.badge.g"
        case .onnx: return "doc.badge.o"
        case .bin: return "doc.badge.b"
        case .pt: return "doc.badge.p"
        }
    }
    
    static func fromFileName(_ fileName: String) -> ModelFormat {
        let lower = fileName.lowercased()
        if lower.contains("coreml") || lower.hasSuffix(".mlpackage") || lower.hasSuffix(".mlmodelc") || lower.hasSuffix(".mlmodel") {
            return .coreML
        } else if lower.hasSuffix(".gguf") {
            return .gguf
        } else if lower.hasSuffix(".onnx") {
            return .onnx
        } else if lower.hasSuffix(".bin") {
            return .bin
        } else if lower.hasSuffix(".pt") {
            return .pt
        }
        return .bin
    }
}

struct ModelVariant: Identifiable, Codable, Hashable {
    let id: String
    let fileName: String
    let fileSize: Int64?
    let format: ModelFormat
    
    var fileSizeFormatted: String {
        guard let size = fileSize else { return "Unknown size" }
        let bytes = Double(size)
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", bytes / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", bytes / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", bytes / 1024)
        }
        return String(format: "%.0f B", bytes)
    }
}
