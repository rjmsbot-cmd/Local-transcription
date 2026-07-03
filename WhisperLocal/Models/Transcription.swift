import Foundation
import SwiftData

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
    
    // Segments stored as encoded JSON (SwiftData doesn't support nested @Model arrays well)
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
        self.segmentsJSON = encode(segments)
        self.wordTimestampsJSON = encode(wordTimestamps)
        self.specialResultsJSON = specialResults != nil ? encode(specialResults!) : "{}"
    }
    
    var segments: [TranscriptionSegment] {
        decode(segmentsJSON) ?? []
    }
    
    var wordTimestamps: [TranscriptionWordTimestamp] {
        decode(wordTimestampsJSON) ?? []
    }
    
    var specialResults: SpecialResults? {
        guard !specialResultsJSON.isEmpty, specialResultsJSON != "{}" else { return nil }
        return decode(specialResultsJSON)
    }
    
    private func encode<T: Codable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value).flatMap { String(bytes: $0, encoding: .utf8) }) ?? "{}"
    }
    
    private func decode<T: Codable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(T.self, from: data))
    }
}

@Model
final class TranscriptionSegment {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var tokensJSON: String
    var tokenLogProbsJSON: String
    var temperature: Double
    var avgLogProb: Double
    var compressionRatio: Double
    var noSpeechProb: Double
    
    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        tokens: [Int],
        tokenLogProbs: [[Double]],
        temperature: Double,
        avgLogProb: Double,
        compressionRatio: Double,
        noSpeechProb: Double
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
    
    var tokens: [Int] {
        get { (try? JSONDecoder().decode([Int].self, from: tokensJSON.data(using: .utf8)!)) ?? [] }
        set { tokensJSON = (try? JSONEncoder().encode(newValue).flatMap { String(bytes: $0, encoding: .utf8) }) ?? "[]" }
    }
    
    var tokenLogProbs: [[Double]] {
        get { (try? JSONDecoder().decode([[Double]].self, from: tokenLogProbsJSON.data(using: .utf8)!)) ?? [] }
        set { tokenLogProbsJSON = (try? JSONEncoder().encode(newValue).flatMap { String(bytes: $0, encoding: .utf8) }) ?? "[]" }
    }
}

@Model
final class TranscriptionWordTimestamp {
    var word: String
    var start: TimeInterval
    var end: TimeInterval
    
    init(word: String, start: TimeInterval, end: TimeInterval) {
        self.word = word
        self.start = start
        self.end = end
    }
}
