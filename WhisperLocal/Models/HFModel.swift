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

    /// Whether the repo belongs to a known non-Whisper CoreML architecture
    /// that WhisperKit cannot load (Qwen3-ASR/FluidAudio, NVIDIA Parakeet,
    /// Nemotron, SpeakerKit, ...). Name-based fast check — the definitive
    /// gate is the artifact-level check in `HuggingFaceService.listModelVariants`.
    var isIncompatibleArchitecture: Bool {
        let lower = modelId.lowercased()
        return HuggingFaceService.incompatibleArchitectureKeywords.contains { lower.contains($0) }
    }
}

// MARK: - HF File Tree Types

struct HFModelFile: Identifiable, Codable, Hashable {
    /// The tree API does NOT return an `id` field (only `path`, `type`,
    /// `size`, `oid`) — path is the stable unique key, so `id` is computed.
    var id: String { path }
    let path: String
    let size: Int?
    /// "file", "directory" or "symlink". Optional defensively: decoding a
    /// variant list must NEVER fail on a missing/odd field.
    let type: String?
    let lfs: LFSPayload?

    init(path: String, size: Int? = nil, type: String? = nil, lfs: LFSPayload? = nil) {
        self.path = path
        self.size = size
        self.type = type
        self.lfs = lfs
    }
    
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
    
    /// Name shown in the variant picker / download button.
    var variantDisplayName: String {
        displayName
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
    
    /// True for distilled/turbo variants: much faster than the full-size
    /// model with nearly the same quality (large-v3-turbo ≈ 6× faster than
    /// large-v3). Surfaced as a "⚡ Rápido" badge in the variant picker.
    var isTurboVariant: Bool {
        let lower = path.lowercased()
        return lower.contains("turbo") || lower.contains("distil")
    }

    /// Precision of a variant, derived from its folder name.
    ///
    /// WhisperKit repos (argmaxinc/whisperkit-coreml …) name quantized
    /// variants with a size suffix (`openai_whisper-large-v3_947MB`) and
    /// full-precision ones without it (`openai_whisper-large-v3_turbo`).
    /// Quantization keywords are checked first so non-Whisper names like
    /// `…-CoreML-INT8` are classified correctly too.
    var precision: VariantPrecision {
        let lower = path.lowercased()
        let quantWords = ["int8", "int4", "q8", "q4", "quant", "_8bit", "_6bit", "_4bit", "6bit", "4bit", "8bit"]
        if quantWords.contains(where: { lower.contains($0) }) { return .quantized }
        // `_NNNMB` suffix = quantized in every argmaxinc variant name.
        if lower.range(of: #"_\d+mb$"#, options: .regularExpression) != nil { return .quantized }
        // Known full-precision families ship WITHOUT the size suffix.
        if lower.contains("openai_whisper") || lower.contains("distil-whisper") { return .fullPrecision }
        return .unknown
    }

    var isFullPrecision: Bool { precision == .fullPrecision }

    /// Sort rank: root bundle first, then tiny → large v3, Distil after
    /// OpenAI, and full-precision variants BEFORE their quantized siblings
    /// (×10 keeps the family order, +1 pushes quantized to the end).
    var variantSortRank: Int {
        if path.isEmpty { return -10 }
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
        // Turbo/distilled variants sort ahead of their plain siblings:
        // they are ≈6× faster AND load far more reliably on iPhone memory
        // (the fp16 large-v3 3,2 GB outranked and never finished loading on
        // Raúl's device — Ronda 13). Applied before ×10 so a turbo small/med
        // also floats above a plain larger sibling, which is what we want.
        if lower.contains("turbo") || lower.contains("distil") { rank -= 1 }
        return rank * 10 + (precision == .quantized ? 1 : 0)
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
        /// Real tree API LFS payloads use `oid`, not `sha256` (verified
        /// against huggingface.co: {"oid": …, "size": …, "pointerSize": …}).
        /// All fields optional: some entries carry `lfs: {}` or nulls, and
        /// decoding must never fail because of it.
        let oid: String?
        let size: Int?
        let pointerSize: Int?
    }
}

/// Precision of a model variant (full precision fp16 vs quantized).
enum VariantPrecision: String {
    case fullPrecision
    case quantized
    case unknown
}

/// Compatibility signal attached to every search result, computed by
/// `HuggingFaceService.classifySearchResults` from a cheap top-level tree
/// probe (plus tag heuristics) so the user sees — BEFORE tapping — whether
/// a repo can actually be installed. This replaces the old design where
/// compatibility was only discovered inside the variant picker, after an
/// expensive full-recursive listing.
///
/// Priority order (used for sorting): compatible → likelyCompatible →
/// unknown → authRequired → incompatible.
enum ModelSearchStatus: String {
    /// WhisperKit bundle confirmed: top-level Whisper naming
    /// (openai_whisper-*, distil-whisper-*) or the three artifacts as a
    /// root bundle. Tap opens the variant picker.
    case compatible
    /// CoreML-tagged ASR repo but not yet verified against the file tree.
    /// Tap opens the variant picker (which does the real check).
    case likelyCompatible
    /// Whisper-named repo that only ships raw weights (safetensors/ONNX),
    /// e.g. `openai/whisper-large-v3`. WhisperKit needs CoreML bundles
    /// (.mlmodelc), so it can never load these — tapping explains instead
    /// of showing an empty variant picker (Ronda 12).
    case safetensorsOnly
    /// No usable signal (neither CoreML tag nor Whisper naming).
    /// Tap opens the variant picker for a definitive check.
    case unknown
    /// Known non-Whisper architecture (Parakeet, Qwen3-ASR, Nemotron…).
    /// Tap shows an explanation instead of an empty picker.
    case incompatible
    /// Gated/private repo — needs an HF token in Ajustes.
    case authRequired

    static func rank(_ s: ModelSearchStatus) -> Int {
        switch s {
        case .compatible: 0
        case .likelyCompatible: 1
        case .unknown: 2
        case .authRequired: 3
        case .incompatible: 4
        case .safetensorsOnly: 5
        }
    }

    var isBlocked: Bool {
        switch self {
        case .incompatible, .authRequired, .safetensorsOnly: true
        default: false
        }
    }
}

/// One search hit: the repo plus its compatibility signal and, when known,
/// how many WhisperKit variants its tree exposes.
struct ModelSearchResult: Equatable, Identifiable {
    let model: HFRepoInfo
    var status: ModelSearchStatus

    var id: String { model.id }
}

/// Legacy alias for compatibility with older code that references HFFileItem
typealias HFFileItem = HFModelFile

/// Legacy alias for LFS info
typealias HFLFSInfo = HFModelFile.LFSPayload