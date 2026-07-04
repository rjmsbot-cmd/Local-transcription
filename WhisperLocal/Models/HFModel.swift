import Foundation

// MARK: - HuggingFace API Models

struct HFModel: Identifiable, Codable, Hashable {
    let id: String
    let modelId: String
    let author: String?
    let pipelineTag: String?
    let tags: [String]?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    
    /// Full display name (author/modelId or just modelId)
    var displayName: String {
        if let author = author {
            return "\(author)/\(modelId)"
        }
        return modelId
    }
    
    /// Short name (just the model part after the last /)
    var shortName: String {
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

/// Typealias used by ModelManager/ModelsView (resolves C2 — "Cannot find type 'HFRepoInfo'")
typealias HFRepoInfo = HFModel

extension HFModel {
    /// Whether this repo likely has downloadable Core ML model files
    var isCoreML: Bool {
        likelyHasCoreML || isWhisperCompatible
    }
}

// MARK: - HF File Tree Types

struct HFModelFile: Identifiable, Codable, Hashable {
    let id: String
    let path: String
    let size: Int?
    let type: String // "file" or "directory"
    let lfs: LFSPayload?
    
    var isDirectory: Bool { type == "directory" }
    var displayName: String { path.split(separator: "/").last?.description ?? path }
    
    struct LFSPayload: Codable, Hashable {
        let sha256: String
        let size: Int
        let pointerSize: Int
    }
}

/// Legacy alias for compatibility with older code that references HFFileItem
typealias HFFileItem = HFModelFile

/// Legacy alias for LFS info
typealias HFLFSInfo = HFModelFile.LFSPayload

