import Foundation

// MARK: - Chunk Size

enum ChunkSize: String, CaseIterable, Identifiable, Codable {
    case `default` = "default"
    case short   = "short"
    case medium  = "medium"
    case long    = "long"
    
    var id: String { rawValue }
    
    var localized: String {
        switch self {
        case .default: return "Por defecto"
        case .short:   return "Corto (~10s)"
        case .medium:  return "Medio (~30s)"
        case .long:    return "Largo (~60s)"
        }
    }
    
    var interval: TimeInterval {
        switch self {
        case .default: return 0   // WhisperKit auto
        case .short:   return 10
        case .medium:  return 30
        case .long:    return 60
        }
    }
}

// MARK: - Special Results

struct SpecialResults: Codable {
    var timestamps: [TimestampEntry]?
    var tokens: [TokenEntry]?
    var segments: [SegmentEntry]?
    
    struct TimestampEntry: Codable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }
    
    struct TokenEntry: Codable {
        var id: Int
        var text: String
        var logprob: Double
    }
    
    struct SegmentEntry: Codable {
        var id: Int
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var tokens: [Int]
        var tokenLogProbs: [[Double]]
    }
}

// MARK: - Compatibility types (used by Views)

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
    let duration: TimeInterval
    let language: String
}

struct TranscriptionProgress {
    let fraction: Double
    let phase: String
}

// MARK: - Transcription convenience init (for Views compatibility)

extension Transcription {
    convenience init(
        title: String,
        fullText: String,
        segments: [TranscriptionSegment],
        duration: TimeInterval,
        detectedLanguage: String,
        modelName: String,
        sourceFileName: String
    ) {
        self.init(
            audioFileName: sourceFileName,
            audioFilePath: "",
            modelName: modelName,
            modelVariant: "unknown",
            language: detectedLanguage,
            fullText: fullText,
            duration: duration,
            segments: segments,
            wordTimestamps: [],
            wordTimestampsEnabled: false,
            useVad: false,
            chunkSize: .default,
            specialResults: nil
        )
    }
}
