import Foundation
import AVFoundation
import CoreML

/// Core transcription engine. Uses WhisperKit when available, falls back to
/// a pure Core ML pipeline for Whisper models.
actor TranscriptionEngine {
    
    private var loadedModelPath: String?
    private var whisperProcessor: WhisperProcessor?
    private let audioProcessor = AudioProcessor()
    
    var isModelLoaded: Bool { loadedModelPath != nil }
    var currentModelName: String? { loadedModelPath?.components(separatedBy: "/").last }
    
    // MARK: - Model Loading
    
    func loadModel(at path: String) async throws {
        if loadedModelPath == path { return }
        
        // Try to load as a Core ML package first
        let modelURL = URL(fileURLWithPath: path)
        
        if modelURL.pathExtension == "mlmodelc" || modelURL.pathExtension == "mlpackage" {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let _ = try MLModel(contentsOf: modelURL, configuration: config)
        }
        
        whisperProcessor = try WhisperProcessor(modelPath: path)
        loadedModelPath = path
    }
    
    // MARK: - Transcription
    
    func transcribe(
        audioAt url: URL,
        language: String?,
        task: TranscriptionTask,
        progressCallback: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard whisperProcessor != nil || loadedModelPath != nil else {
            throw TranscriptionError.noModelLoaded
        }
        
        let duration = try audioProcessor.getAudioDuration(at: url)
        
        // For very long audio (>30 min), chunk it
        if duration > 1800 {
            return try await transcribeChunked(
                audioAt: url, language: language, task: task,
                totalDuration: duration, progressCallback: progressCallback
            )
        }
        
        return try await transcribeDirect(
            audioAt: url, language: language, task: task,
            duration: duration, progressCallback: progressCallback
        )
    }
    
    private func transcribeDirect(
        audioAt url: URL,
        language: String?,
        task: TranscriptionTask,
        duration: TimeInterval,
        progressCallback: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        // Convert audio to Whisper's expected format
        let (samples, _) = try await audioProcessor.convertToWhisperPCM(at: url)
        
        // Run inference
        let segments = try await runInference(
            samples: samples,
            language: language,
            task: task
        ) { progress in
            Task { @MainActor in
                progressCallback(progress)
            }
        }
        
        let fullText = segments.map(\.text).joined(separator: " ")
        
        await progressCallback(TranscriptionProgress(
            fractionComplete: 1.0,
            currentSegmentIndex: segments.count,
            totalSegments: segments.count,
            currentText: fullText,
            phase: .complete
        ))
        
        return TranscriptionResult(
            text: fullText,
            segments: segments,
            language: language ?? "auto",
            duration: duration
        )
    }
    
    private func transcribeChunked(
        audioAt url: URL,
        language: String?,
        task: TranscriptionTask,
        totalDuration: TimeInterval,
        progressCallback: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        let chunks = try audioProcessor.splitIntoChunks(at: url)
        var allSegments: [Transcription.Segment] = []
        var fullTextParts: [String] = []
        var globalSegmentId = 0
        
        for (chunkIndex, chunk) in chunks.enumerated() {
            let (samples, _) = try await audioProcessor.convertToWhisperPCM(at: chunk.url)
            
            let chunkSegments = try await runInference(
                samples: samples,
                language: language,
                task: task
            ) { _ in } // Individual chunk progress not surfaced
            
            // Offset timestamps by chunk start time
            for seg in chunkSegments {
                allSegments.append(Transcription.Segment(
                    id: globalSegmentId,
                    start: seg.start + chunk.offset,
                    end: seg.end + chunk.offset,
                    text: seg.text
                ))
                globalSegmentId += 1
            }
            
            fullTextParts.append(chunkSegments.map(\.text).joined(separator: " "))
            
            let overallProgress = Double(chunkIndex + 1) / Double(chunks.count)
            await progressCallback(TranscriptionProgress(
                fractionComplete: overallProgress,
                currentSegmentIndex: allSegments.count,
                totalSegments: Int(totalDuration / 2.5),
                currentText: chunkSegments.last?.text ?? "",
                phase: .transcribing
            ))
        }
        
        // Cleanup temp chunks
        audioProcessor.cleanupChunks(chunks)
        
        let fullText = fullTextParts.joined(separator: " ")
        
        await progressCallback(TranscriptionProgress(
            fractionComplete: 1.0,
            currentSegmentIndex: allSegments.count,
            totalSegments: allSegments.count,
            currentText: fullText,
            phase: .complete
        ))
        
        return TranscriptionResult(
            text: fullText,
            segments: allSegments,
            language: language ?? "auto",
            duration: totalDuration
        )
    }
    
    // MARK: - Inference
    
    private func runInference(
        samples: [Float],
        language: String?,
        task: TranscriptionTask,
        progressCallback: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> [Transcription.Segment] {
        guard let processor = whisperProcessor else {
            throw TranscriptionError.noModelLoaded
        }
        
        await progressCallback(TranscriptionProgress(
            fractionComplete: 0.1,
            currentSegmentIndex: 0,
            totalSegments: 0,
            currentText: "",
            phase: .processing
        ))
        
        let result = try processor.transcribe(
            audioSamples: samples,
            language: language,
            task: task == .transcribe ? .transcribe : .translate
        )
        
        return result.enumerated().map { index, seg in
            Transcription.Segment(id: index, start: seg.start, end: seg.end, text: seg.text)
        }
    }
}

// MARK: - Supporting Types

enum TranscriptionTask: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case translate = "Translate"
    
    var id: String { rawValue }
}

struct TranscriptionResult {
    let text: String
    let segments: [Transcription.Segment]
    let language: String
    let duration: TimeInterval
}

struct TranscriptionProgress {
    let fractionComplete: Double
    let currentSegmentIndex: Int
    let totalSegments: Int
    let currentText: String
    let phase: TranscriptionPhase
}

enum TranscriptionPhase {
    case loading
    case processing
    case transcribing
    case complete
}

enum TranscriptionError: LocalizedError {
    case noModelLoaded
    case inferenceFailed(String)
    case audioConversionFailed
    
    var errorDescription: String? {
        switch self {
        case .noModelLoaded: return "No model loaded. Download a model from the Models tab first."
        case .inferenceFailed(let msg): return "Inference failed: \(msg)"
        case .audioConversionFailed: return "Could not convert audio to the required format."
        }
    }
}
