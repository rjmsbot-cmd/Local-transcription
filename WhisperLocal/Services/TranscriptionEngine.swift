import Foundation

@MainActor
class TranscriptionEngine {
    private var audioProcessor = AudioProcessor()
    private var whisperProcessor = WhisperProcessor()
    
    // MARK: - Public State (for UI status indicators)
    var whisperProcessorLoaded: Bool = false
    var loadedModelPath: String?
    var estimatedMemoryBytes: Int64 = 0
    
    /// Human-readable memory estimate
    var modelMemoryFormatted: String {
        guard estimatedMemoryBytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: estimatedMemoryBytes, countStyle: .memory)
    }
    
    // MARK: - Model Lifecycle
    
    func loadModel(at path: String) async throws {
        whisperProcessor = WhisperProcessor()
        try await whisperProcessor.loadModel(path: path)
        loadedModelPath = path
        whisperProcessorLoaded = true
        
        // Estimate memory usage from file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            estimatedMemoryBytes = size
        }
    }
    
    func unloadModel() {
        whisperProcessor = WhisperProcessor()
        whisperProcessorLoaded = false
        loadedModelPath = nil
        estimatedMemoryBytes = 0
    }
    
    // MARK: - Transcription
    
    func transcribe(
        audioAt url: URL,
        language: String? = nil,
        task: TranscriptionTask = .transcribe,
        progressHandler: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard whisperProcessorLoaded else { throw TranscriptionError.noModelLoaded }
        
        let duration = try audioProcessor.getAudioDuration(at: url)
        
        if duration > 1800 {
            return try await transcribeChunked(
                url: url, language: language, task: task, totalDuration: duration,
                progressHandler: progressHandler
            )
        }
        
        await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 0.1, phase: "Loading audio..."))
        let (samples, _) = try audioProcessor.loadAudio(from: url)
        
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
        let chunks = try audioProcessor.splitIntoChunks(at: url)
        var allSegments: [Transcription.Segment] = []
        var fullTextParts: [String] = []
        var globalSegmentId = 0
        
        for (idx, chunk) in chunks.enumerated() {
            let chunkFrac = Double(idx) / Double(chunks.count)
            await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 0.1 + chunkFrac * 0.8, phase: "Chunk \(idx + 1)/\(chunks.count)..."))
            
            let (samples, _) = try audioProcessor.loadAudio(from: chunk.fileURL)
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
        
        audioProcessor.cleanupChunks(chunks)
        await progressHandler(TranscriptionProgress(taskId: task.id, fraction: 1.0, phase: "Complete"))
        
        return TranscriptionResult(
            text: fullTextParts.joined(separator: " "),
            segments: allSegments, duration: totalDuration, language: language ?? "en"
        )
    }
}
