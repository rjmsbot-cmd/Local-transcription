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

    private func encode<T: Codable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "{}"
    }
    
    private func decode<T: Codable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(T.self, from: data))
    }
}

@Model
final class TranscriptionSegment: Codable {
    enum CodingKeys: String, CodingKey {
        case startTime, endTime, text, tokens, tokenLogProbs, temperature, avgLogProb, compressionRatio, noSpeechProb
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        text = try container.decode(String.self, forKey: .text)
        tokens = try container.decode([Int].self, forKey: .tokens)
        tokenLogProbs = try container.decode([[Double]].self, forKey: .tokenLogProbs)
        temperature = try container.decode(Double.self, forKey: .temperature)
        avgLogProb = try container.decode(Double.self, forKey: .avgLogProb)
        compressionRatio = try container.decode(Double.self, forKey: .compressionRatio)
        noSpeechProb = try container.decode(Double.self, forKey: .noSpeechProb)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(text, forKey: .text)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(tokenLogProbs, forKey: .tokenLogProbs)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(avgLogProb, forKey: .avgLogProb)
        try container.encode(compressionRatio, forKey: .compressionRatio)
        try container.encode(noSpeechProb, forKey: .noSpeechProb)
    }
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
    

    // MARK: - Computed properties for ExportService compatibility
    
    var start: TimeInterval { startTime }
    var end: TimeInterval { endTime }
    
    var startTimeFormatted: String {
        String(format: "%02d:%02d", Int(startTime) / 60, Int(startTime) % 60)
    }
    
    var endTimeFormatted: String {
        String(format: "%02d:%02d", Int(endTime) / 60, Int(endTime) % 60)
    }
    
    var tokens: [Int] {
        get { (try? JSONDecoder().decode([Int].self, from: tokensJSON.data(using: .utf8)!)) ?? [] }
        set { tokensJSON = (try String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }
    
    var tokenLogProbs: [[Double]] {
        get { (try? JSONDecoder().decode([[Double]].self, from: tokenLogProbsJSON.data(using: .utf8)!)) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue), let str = String(data: data, encoding: .utf8) { tokenLogProbsJSON = str } else { tokenLogProbsJSON = "[]" } }
    }
}

@Model
final class TranscriptionWordTimestamp: Codable {
    enum CodingKeys: String, CodingKey {
        case word, start, end
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(word, forKey: .word)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
    var word: String
    var start: TimeInterval
    var end: TimeInterval
    
    init(word: String, start: TimeInterval, end: TimeInterval) {
        self.word = word
        self.start = start
        self.end = end
    }
}
