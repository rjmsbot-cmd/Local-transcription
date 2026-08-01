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
        case id, modelId, author, tags, downloads, likes, lastModified
        case pipelineTag = "pipeline_tag"
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
    let type: String // "file", "directory" or "symlink"
    let lfs: LFSPayload?
    
    var isDirectory: Bool { type == "directory" }
    /// Some CoreML repos expose .mlpackage/.mlmodelc entries as symlinks
    /// ("symlink" type in the HF tree API). Treat them as directories when
    /// listing variants so they are not silently dropped.
    var isSymlink: Bool { type == "symlink" }
    /// True for directory-like entries (real dirs or symlinks).
    var isDirectoryLike: Bool { isDirectory || isSymlink }
    var displayName: String {
        if path.isEmpty { return "Raíz del repositorio" }
        return path.split(separator: "/").last?.description ?? path
    }
    
    /// A directory-like entry that looks like a CoreML model bundle.
    var isCoreMLBundleName: Bool {
        let name = path.lowercased()
        return name.contains("mlmodelc") || name.contains("mlpackage")
    }
    
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

