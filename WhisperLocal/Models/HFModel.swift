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
