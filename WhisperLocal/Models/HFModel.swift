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
               tagLower.contains("whisperkit") ||
               lower.contains("coreml") ||
               lower.contains("core-ml") ||
               lower.contains("whisperkit")
    }

    
    enum CodingKeys: String, CodingKey {
        case id, modelId, author, tags, downloads, likes, lastModified
        case pipelineTag = "pipeline_tag"
    }
}

/// Typealias used by ModelManager/ModelsView (resolves C2 — "Cannot find type 'HFRepoInfo'")
typealias HFRepoInfo = HFModel

extension HFModel {
    /// Whether this repo likely has downloadable Core ML model files.
    /// Prioritizes tags over name matching to avoid false positives.
    var isCoreML: Bool {
        likelyHasCoreML
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
    
    /// Human-readable display name for a model variant folder.
    ///
    /// Examples:
    ///   openai_whisper-base          → "Base"
    ///   openai_whisper-small_216MB   → "Small · 216 MB"
    ///   openai_whisper-base.en       → "Base (English-only)"
    ///   distil-whisper_distil-large-v3_turbo_600MB → "Distil Whisper · Large V3 Turbo · 600 MB"
    var displayName: String {
        if path.isEmpty { return "Raíz del repositorio" }
        let raw = path.split(separator: "/").last.map(String.init) ?? path
        return Self.prettyVariantName(raw)
    }
    
    /// Short family label (OpenAI Whisper / Distil-Whisper / …).
    var variantFamily: String {
        if path.isEmpty { return "" }
        let raw = path.split(separator: "/").last.map(String.init) ?? path
        let lower = raw.lowercased()
        if lower.hasPrefix("distil-whisper_") || lower.hasPrefix("distil_whisper_") {
            return "Distil-Whisper"
        }
        if lower.hasPrefix("openai_whisper-") || lower.hasPrefix("openai_whisper_") {
            return "OpenAI Whisper"
        }
        return ""
    }
    
    /// The model size (tiny, base, small, medium, large, …) extracted from the dir name.
    var variantModelSize: String {
        if path.isEmpty { return "" }
        let raw = path.split(separator: "/").last.map(String.init) ?? path
        let lower = raw.lowercased()
        if lower.contains("large-v3-v20240930") { return "large v3 (v20240930)" }
        if lower.contains("large-v3-turbo") || lower.contains("large_v3_turbo") { return "large v3 turbo" }
        if lower.contains("large-v3") || lower.contains("large_v3") { return "large v3" }
        if lower.contains("large-v2-turbo") || lower.contains("large_v2_turbo") { return "large v2 turbo" }
        if lower.contains("large-v2") || lower.contains("large_v2") { return "large v2" }
        if lower.contains("large") { return "large" }
        if lower.contains("medium") { return "medium" }
        if lower.contains("small") { return "small" }
        if lower.contains("base") { return "base" }
        if lower.contains("tiny") { return "tiny" }
        return ""
    }
    
    /// Quantization-size badge extracted from the dir name, e.g. "547 MB" from "…_547MB".
    var variantSizeSuffix: String? {
        if path.isEmpty { return nil }
        let raw = path.split(separator: "/").last.map(String.init) ?? path
        let pattern = try? NSRegularExpression(pattern: "_(\\d+)MB$", options: [.caseInsensitive])
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        if let match = pattern?.firstMatch(in: raw, range: range),
           let digRange = Range(match.range(at: 1), in: raw) {
            return "\(raw[digRange])\u{202F}MB"
        }
        return nil
    }
    
    /// Sort rank: root bundle first, then tiny → large v3, Distil after OpenAI.
    var variantSortRank: Int {
        if path.isEmpty { return -1 }
        let lower = path.lowercased()
        var rank: Int
        if lower.contains("tiny") { rank = 1 }
        else if lower.contains("base") { rank = 2 }
        else if lower.contains("small") { rank = 3 }
        else if lower.contains("medium") { rank = 4 }
        else if lower.contains("large-v3") { rank = 6 }
        else if lower.contains("large-v2") { rank = 5 }
        else if lower.contains("large") { rank = 5 }
        else { rank = 50 }
        if lower.contains("distil-whisper") { rank += 20 }
        return rank
    }
    
    /// Turns a raw variant folder name into a UI-friendly label.
    static func prettyVariantName(_ raw: String) -> String {
        let lower = raw.lowercased()
        
        // --- Distil-Whisper family: "distil-whisper_distil-large-v3_turbo_600MB" ---
        if lower.hasPrefix("distil-whisper_") {
            var s = String(raw.dropFirst("distil-whisper_".count))
            s = s.replacingOccurrences(of: "distil-", with: "")
            s = s.replacingOccurrences(of: "_", with: " ")
            // Nice-case tokens
            for (k, v) in variantNiceWords { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
            // Pull trailing _NNNMB into a pretty badge
            if let m = try? NSRegularExpression(pattern: " (\\d+)MB$", options: .caseInsensitive)
                .firstMatch(in: s, range: NSMakeRange(0, s.utf16.count)),
               let r = Range(m.range(at: 1), in: s) {
                s = String(s.prefix(m.range.lowerBound)) + " · " + String(s[r]) + "\u{202F}MB"
            }
            return "Distil Whisper · " + s
        }
        
        // OpenAI Whisper family: "openai_whisper-base", "openai_whisper-small_216MB"
        if lower.hasPrefix("openai_whisper-") {
            var s = String(raw.dropFirst("openai_whisper-".count))
            s = s.replacingOccurrences(of: "_", with: " ")
            for (k, v) in variantNiceWords { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
            // English-only suffix (".en" at end or before size suffix)
            s = s.replacingOccurrences(of: ".en ", with: " (English-only) ", options: .caseInsensitive)
            if s.hasSuffix(".en") { s = String(s.dropLast(3)) + " (English-only)" }
            if s.contains(".en(") { s = s.replacingOccurrences(of: ".en(", with: " (English-only)(", options: .caseInsensitive) }
            // Size badge " NNNMB" → "· NNN MB"
            if let m = try? NSRegularExpression(pattern: " (\\d+)MB$", options: .caseInsensitive)
                .firstMatch(in: s, range: NSMakeRange(0, s.utf16.count)),
               let badge = Range(m.range(at: 1), in: s) {
                s = String(s.prefix(m.range.lowerBound)) + " · " + String(s[badge]) + "\u{202F}MB"
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        
        // Generic: underscores → spaces
        return raw.replacingOccurrences(of: "_", with: " ")
    }
    
    /// Tokens for pretty-printing Distil Whisper + OpenAI variants.
    private static let variantNiceWords: [(String, String)] = [
        ("large-v3-v20240930 turbo", "Large V3 Turbo · Sep 2024"),
        ("large-v3-v20240930", "Large V3 · Sep 2024"),
        ("v20240930", "Sep 2024"),
        ("large-v3-turbo", "Large V3 Turbo"),
        ("large-v3", "Large V3"),
        ("large-v2-turbo", "Large V2 Turbo"),
        ("large-v2", "Large V2"),
        ("large", "Large"),
        ("medium", "Medium"),
        ("small", "Small"),
        ("base", "Base"),
        ("tiny", "Tiny"),
        ("turbo", "Turbo")
    ]
    /// A directory-like entry whose path looks like a CoreML model bundle.
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