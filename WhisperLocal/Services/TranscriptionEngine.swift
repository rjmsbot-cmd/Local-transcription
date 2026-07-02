import Foundation
import SwiftData

@MainActor
final class TranscriptionEngine {
    private var whisperProcessor: WhisperProcessor?
    private var currentModelPath: String?
    
    // Public accessors for UI status
    var whisperProcessorLoaded: Bool { whisperProcessor != nil }
    var loadedModelPath: String? { currentModelPath }
    var modelMemoryFormatted: String {
        guard whisperProcessor != nil else { return "N/A" }
        return "~50 MB" // WhisperProcessor doesn't expose memory usage
    }
    
    // MARK: - Model Loading
    
    func loadModel(at path: String) async throws {
        // Unload existing model first
        unloadModel()
        
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.modelFileNotFound(path)
        }
        
        // Validate that the path is a Core ML model directory
        let url = URL(fileURLWithPath: path)
        let fileExt = url.pathExtension
        let fileName = url.lastPathComponent
        let extLower = fileExt.lowercased()
        let nameLower = fileName.lowercased()
        
        guard extLower == "mlmodelc" || nameLower.contains("mlmodelc") || extLower == "mlpackage" else {
            let reported = extLower.isEmpty ? nameLower : extLower
            throw EngineError.invalidModelFormat(
                "Only Core ML models (.mlmodelc) are supported. Got: \(reported)"
            )
        }
        
        do {
            let processor = WhisperProcessor()
            try await processor.loadModel(path: path)
            whisperProcessor = processor
            currentModelPath = path
            print("[TranscriptionEngine] Model loaded: \(path)")
        } catch {
            // Clean up on failure
            whisperProcessor = nil
            currentModelPath = nil
            print("[TranscriptionEngine] Model load failed: \(error.localizedDescription)")
            throw EngineError.modelLoadFailed(error.localizedDescription)
        }
    }
    
    func unloadModel() {
        print("[TranscriptionEngine] Unloading model")
        whisperProcessor = nil
        currentModelPath = nil
    }
    
    // MARK: - Transcription
    
    func transcribe(
        audioAt audioURL: URL,
        language: String?,
        task: TranscriptionTask,
        progressHandler: @MainActor (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard let processor = whisperProcessor else {
            throw EngineError.noModelLoaded
        }
        
        let samples = try AudioProcessor().loadAudio(from: audioURL).samples
        let whisperResult = try await processor.transcribe(samples: samples, language: language)
        
        let segments: [Transcription.Segment] = whisperResult.segments.enumerated().map { idx, seg in
            Transcription.Segment(
                id: idx,
                start: seg.start,
                end: seg.end,
                text: seg.text
            )
        }
        
        return TranscriptionResult(
            text: whisperResult.text,
            segments: segments,
            duration: Double(samples.count) / 16000,
            language: language ?? "auto"
        )
    }
    
    // MARK: - Batch Transcription
    
    func transcribeBatch(
        audioURLs: [URL],
        language: String?,
        task: TranscriptionTask,
        progressHandler: @MainActor (TranscriptionProgress) -> Void
    ) async throws -> [TranscriptionResult] {
        guard let processor = whisperProcessor else {
            throw EngineError.noModelLoaded
        }
        
        var results: [TranscriptionResult] = []
        
        for (index, url) in audioURLs.enumerated() {
            let fileProgress = TranscriptionProgress(
                taskId: "batch_\(index)",
                fraction: Double(index) / Double(audioURLs.count),
                phase: "File \(index + 1)/\(audioURLs.count)"
            )
            progressHandler(fileProgress)
            
            do {
                let samples = try AudioProcessor().loadAudio(from: url).samples
                let whisperResult = try await processor.transcribe(samples: samples, language: language)
                
                let segments: [Transcription.Segment] = whisperResult.segments.enumerated().map { idx, seg in
                    Transcription.Segment(
                        id: idx,
                        start: seg.start,
                        end: seg.end,
                        text: seg.text
                    )
                }
                
                let result = TranscriptionResult(
                    text: whisperResult.text,
                    segments: segments,
                    duration: Double(samples.count) / 16000,
                    language: language ?? "auto"
                )
                results.append(result)
            } catch {
                print("[TranscriptionEngine] Failed to transcribe \(url.lastPathComponent): \(error)")
                // Continue with remaining files
            }
        }
        
        progressHandler(TranscriptionProgress(taskId: "batch_complete", fraction: 1.0, phase: "Complete"))
        return results
    }
}

// MARK: - Engine Errors

enum EngineError: LocalizedError {
    case noModelLoaded
    case modelFileNotFound(String)
    case transcriptionFailed(String)
    case invalidModelFormat(String)
    case modelLoadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No model loaded. Please download and load a model first."
        case .modelFileNotFound(let path):
            return "Model file not found at: \(path)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .invalidModelFormat(let detail):
            return "Invalid model format: \(detail). Download a Core ML (.mlmodelc) model."
        case .modelLoadFailed(let reason):
            return "Unable to load model: \(reason)"
        }
    }
}
