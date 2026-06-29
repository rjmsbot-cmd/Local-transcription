import Foundation
import SwiftData

@Model
final class Transcription {
    var id: UUID
    var title: String
    var fullText: String
    var segmentsData: Data
    var createdAt: Date
    var duration: TimeInterval
    var detectedLanguage: String
    var modelName: String
    var sourceFileName: String?
    var wordCount: Int
    
    var segments: [Segment] {
        get {
            (try? JSONDecoder().decode([Segment].self, from: segmentsData)) ?? []
        }
        set {
            segmentsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
    
    init(title: String, fullText: String, segments: [Segment], duration: TimeInterval, detectedLanguage: String, modelName: String, sourceFileName: String? = nil) {
        self.id = UUID()
        self.title = title
        self.fullText = fullText
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.createdAt = Date()
        self.duration = duration
        self.detectedLanguage = detectedLanguage
        self.modelName = modelName
        self.sourceFileName = sourceFileName
        self.wordCount = fullText.split(separator: " ").count
    }
    
    struct Segment: Codable, Identifiable, Hashable {
        var id: Int
        var start: Double
        var end: Double
        var text: String
        
        var startTimeFormatted: String { formatTimestamp(start) }
        var endTimeFormatted: String { formatTimestamp(end) }
        
        private func formatTimestamp(_ seconds: Double) -> String {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let s = Int(seconds) % 60
            let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
            if h > 0 {
                return String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
            }
            return String(format: "%02d:%02d.%03d", m, s, ms)
        }
    }
}
