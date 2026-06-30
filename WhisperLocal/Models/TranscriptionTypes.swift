import Foundation

// MARK: - Transcription Task

enum TranscriptionTask: String, CaseIterable, Identifiable {
    case transcribe = "transcribe"
    case translate  = "translate"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .transcribe: return "Transcribe"
        case .translate:  return "Translate to English"
        }
    }
}

// MARK: - Transcription Progress

struct TranscriptionProgress: Identifiable {
    let id: UUID
    let taskId: String
    let fraction: Double
    let phase: String
    
    init(taskId: String, fraction: Double, phase: String) {
        self.id = UUID()
        self.taskId = taskId
        self.fraction = fraction
        self.phase = phase
    }
}

// MARK: - Transcription Result

struct TranscriptionResult {
    let text: String
    let segments: [Transcription.Segment]
    let duration: TimeInterval
    let language: String
}

// MARK: - Transcription Errors

enum TranscriptionError: LocalizedError {
    case noModelLoaded
    case audioLoadFailed(String)
    case transcriptionFailed(String)
    case modelLoadFailed(String)
    case chunkProcessingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No model loaded. Please download and load a model first."
        case .audioLoadFailed(let msg):
            return "Failed to load audio: \(msg)"
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        case .modelLoadFailed(let msg):
            return "Failed to load model: \(msg)"
        case .chunkProcessingFailed(let msg):
            return "Chunk processing failed: \(msg)"
        }
    }
}
