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
        guard let processor = whisperProcessor else { return "N/A" }
        let bytes = processor.estimatedMemoryBytes
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    // MARK: - Model Loading
    
    func loadModel(at path: String) async throws {
        // Unload existing model first
        unloadModel()
        
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.modelFileNotFound(path)
        }
        
        do {
            let processor = try await WhisperProcessor.load(modelPath: path)
            whisperProcessor = processor
            currentModelPath = path
            print("[TranscriptionEngine] Model loaded: \(path)")
        } catch {
            // Clean up on failure
            whisperProcessor = nil
            currentModelPath = nil
            print("[TranscriptionEngine] Model load failed: \(error.localizedDescription)")
            throw error
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
        
        let result = try await processor.transcribe(
            audioURL: audioURL,
            language: language,
            task: task,
            progressHandler: progressHandler
        )
        
        return result
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
                fraction: Double(index) / Double(audioURLs.count),
                phase: "File \(index + 1)/\(audioURLs.count)"
            )
            progressHandler(fileProgress)
            
            do {
                let result = try await processor.transcribe(
                    audioURL: url,
                    language: language,
                    task: task,
                    progressHandler: { phaseProgress in
                        let overallFraction = Double(index) / Double(audioURLs.count)
                        let phaseFraction = phaseProgress.fraction / Double(audioURLs.count)
                        progressHandler(TranscriptionProgress(
                            fraction: overallFraction + phaseFraction,
                            phase: phaseProgress.phase
                        ))
                    }
                )
                results.append(result)
            } catch {
                print("[TranscriptionEngine] Failed to transcribe \(url.lastPathComponent): \(error)")
                // Continue with remaining files
            }
        }
        
        progressHandler(TranscriptionProgress(fraction: 1.0, phase: "Complete"))
        return results
    }
}

// MARK: - Engine Errors

enum EngineError: LocalizedError {
    case noModelLoaded
    case modelFileNotFound(String)
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No model loaded. Please download and load a model first."
        case .modelFileNotFound(let path):
            return "Model file not found at: \(path)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
