import Foundation

enum TranscriptionTask: String, CaseIterable, Identifiable {
    case transcribe = "transcribe"
    case translate = "translate"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .transcribe: return "Transcribe"
        case .translate: return "Translate"
        }
    }
}

struct TranscriptionProgress {
    let taskId: UUID
    let fraction: Double
    let phase: String
}

struct TranscriptionResult {
    let text: String
    let segments: [Transcription.Segment]
    let duration: TimeInterval
    let language: String
}

enum TranscriptionError: Error {
    case noModelLoaded
    case processingFailed(String)
    case cancelled
}

class TranscriptionEngine {
    private let audioProcessor = AudioProcessor()
    private let whisperProcessor = WhisperProcessor()
    private var whisperProcessorLoaded = false
    private var loadedModelPath: String?
    private var modelManager: ModelManager?

    func setModelManager(_ manager: ModelManager) {
        self.modelManager = manager
    }

    func loadModel(path: String) async throws {
        try await whisperProcessor.loadModel(path: path)
        loadedModelPath = path
        whisperProcessorLoaded = true
    }

    func loadModel(at path: String) async throws {
        try await whisperProcessor.loadModel(path: path)
        loadedModelPath = path
        whisperProcessorLoaded = true
    }

    func transcribe(
        audioAt url: URL,
        language: String? = nil,
        task: TranscriptionTask = .transcribe,
        progressHandler: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard whisperProcessorLoaded else { throw TranscriptionError.noModelLoaded }

        let duration = try await MainActor.run { try audioProcessor.getAudioDuration(at: url) }

        if duration > 1800 {
            return try await transcribeChunked(url: url, language: language, task: task, totalDuration: duration, progressCallback: progressCallback)
        }

        await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 0.1, phase: "Loading audio..."))
        let (samples, _) = try await MainActor.run { try audioProcessor.loadAudio(from: url) }

        await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 0.3, phase: "Transcribing..."))
        let result = try await whisperProcessor.transcribe(samples: samples, language: language)

        let segments = result.segments.enumerated().map { i, seg in
            Transcription.Segment(id: i, start: seg.start, end: seg.end, text: seg.text)
        }

        await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 1.0, phase: "Complete"))

        return TranscriptionResult(
            text: result.text,
            segments: segments,
            duration: duration,
            language: language ?? "en"
        )
    }

    private func transcribeChunked(
        url: URL,
        language: String?,
        task: TranscriptionTask,
        totalDuration: TimeInterval,
        progressHandler: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        let chunks = try await MainActor.run { try audioProcessor.splitIntoChunks(at: url) }
        var allSegments: [Transcription.Segment] = []
        var fullTextParts: [String] = []
        var globalSegmentId = 0

        for (idx, chunk) in chunks.enumerated() {
            let chunkFrac = Double(idx) / Double(chunks.count)
            await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 0.1 + chunkFrac * 0.8, phase: "Chunk \(idx + 1)/\(chunks.count)..."))

            let (samples, _) = try await MainActor.run { try audioProcessor.loadAudio(from: chunk.fileURL) }
            let result = try await whisperProcessor.transcribe(samples: samples, language: language)

            for seg in result.segments {
                allSegments.append(Transcription.Segment(
                    id: globalSegmentId, start: seg.start + chunk.startTime,
                    end: seg.end + chunk.startTime, text: seg.text
                ))
                globalSegmentId += 1
            }
            fullTextParts.append(result.text)
        }

        await MainActor.run { audioProcessor.cleanupChunks(chunks) }
        await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 1.0, phase: "Complete"))

        return TranscriptionResult(
            text: fullTextParts.joined(separator: " "),
            segments: allSegments, duration: totalDuration, language: language ?? "en"
        )
    }
}
