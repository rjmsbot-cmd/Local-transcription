import Foundation
import SwiftData

// MARK: - Codable value types (stored as JSON inside Transcription)
//
// These are lightweight value types persisted as JSON blobs inside the
// `Transcription` SwiftData model (`segmentsJSON` / `wordTimestampsJSON`).
// They are intentionally NOT SwiftData models — SwiftData cannot reliably
// nest @Model types inside other @Model types, and the previous @Model +
// Codable combination produced unstable metadata.

/// A transcribed segment — plain Codable struct.
struct TranscriptionSegment: Codable, Equatable {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var tokens: [Int]
    var tokenLogProbs: [[Double]]
    var temperature: Double
    var avgLogProb: Double
    var compressionRatio: Double
    var noSpeechProb: Double
    
    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        tokens: [Int] = [],
        tokenLogProbs: [[Double]] = [],
        temperature: Double = 0,
        avgLogProb: Double = 0,
        compressionRatio: Double = 0,
        noSpeechProb: Double = 0
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.tokens = tokens
        self.tokenLogProbs = tokenLogProbs
        self.temperature = temperature
        self.avgLogProb = avgLogProb
        self.compressionRatio = compressionRatio
        self.noSpeechProb = noSpeechProb
    }
    
    // MARK: - ExportService compatibility
    
    var start: TimeInterval { startTime }
    var end: TimeInterval { endTime }
    
    var startTimeFormatted: String {
        String(format: "%02d:%02d", Int(startTime) / 60, Int(startTime) % 60)
    }
    
    var endTimeFormatted: String {
        String(format: "%02d:%02d", Int(endTime) / 60, Int(endTime) % 60)
    }
}

/// Word-level timestamp — plain Codable struct.
struct TranscriptionWordTimestamp: Codable, Equatable {
    var word: String
    var start: TimeInterval
    var end: TimeInterval
    
    init(word: String, start: TimeInterval, end: TimeInterval) {
        self.word = word
        self.start = start
        self.end = end
    }
}

// MARK: - SwiftData root model
//
// NOTE: the persisted schema below is UNCHANGED from previous builds
// (same stored property names/types), so existing on-device stores keep
// opening without migration errors.

@Model
final class Transcription {
    var id: UUID
    var audioFileName: String
    var audioFilePath: String
    var modelName: String
    var modelVariant: String
    var language: String
    var fullText: String
    var duration: TimeInterval
    var createdAt: Date
    var chunkSize: ChunkSize
    var useVad: Bool
    var wordTimestampsEnabled: Bool
    
    // Segments stored as encoded JSON (SwiftData doesn't support nested struct arrays)
    var segmentsJSON: String
    var wordTimestampsJSON: String
    var specialResultsJSON: String
    
    init(
        audioFileName: String,
        audioFilePath: String,
        modelName: String,
        modelVariant: String,
        language: String,
        fullText: String,
        duration: TimeInterval,
        segments: [TranscriptionSegment],
        wordTimestamps: [TranscriptionWordTimestamp],
        wordTimestampsEnabled: Bool,
        useVad: Bool,
        chunkSize: ChunkSize,
        specialResults: SpecialResults?
    ) {
        self.id = UUID()
        self.audioFileName = audioFileName
        self.audioFilePath = audioFilePath
        self.modelName = modelName
        self.modelVariant = modelVariant
        self.language = language
        self.fullText = fullText
        self.duration = duration
        self.createdAt = Date()
        self.useVad = useVad
        self.chunkSize = chunkSize
        self.wordTimestampsEnabled = wordTimestampsEnabled
        self.segmentsJSON = Self.encode(segments)
        self.wordTimestampsJSON = Self.encode(wordTimestamps)
        self.specialResultsJSON = specialResults != nil ? Self.encode(specialResults!) : "{}"
    }
    
    // MARK: - Computed properties (decoded on demand)
    
    var segments: [TranscriptionSegment] {
        get { Self.decode(segmentsJSON) ?? [] }
        set { segmentsJSON = Self.encode(newValue) }
    }
    
    var wordTimestamps: [TranscriptionWordTimestamp] {
        get { Self.decode(wordTimestampsJSON) ?? [] }
        set { wordTimestampsJSON = Self.encode(newValue) }
    }
    
    var specialResults: SpecialResults? {
        guard !specialResultsJSON.isEmpty, specialResultsJSON != "{}" else { return nil }
        return Self.decode(specialResultsJSON)
    }
    

    // MARK: - Computed properties for ExportService compatibility
    
    var title: String {
        audioFileName
            .replacingOccurrences(of: ".wav", with: "")
            .replacingOccurrences(of: ".m4a", with: "")
            .replacingOccurrences(of: ".mp3", with: "")
            .replacingOccurrences(of: ".flac", with: "")
    }
    
    var detectedLanguage: String { language }
    
    var wordCount: Int {
        fullText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
    }

    // JSON helpers — static to avoid @Model macro backing-field issues
    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
    
    private static func decode<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
