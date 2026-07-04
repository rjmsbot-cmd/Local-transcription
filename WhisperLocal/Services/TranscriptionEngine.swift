import Foundation
import SwiftData

/// Orchestrates model loading and transcription on top of `WhisperProcessor`
/// (which wraps WhisperKit).
///
/// This class no longer does its own mel-spectrogram extraction, token
/// decoding, or manual 30s chunking — WhisperKit handles all of that once
/// given a valid model folder and a raw 16kHz mono sample array. The public
/// API is kept identical to before so `TranscribeView`, `RecordView`,
/// `ModelsView` and `SettingsView` don't need to change.
@MainActor
final class TranscriptionEngine {
    private let processor = WhisperProcessor()

    // Mirrors the actor's state on the main actor so the UI can keep
    // reading these synchronously, exactly like before.
    private(set) var whisperProcessorLoaded = false
    private(set) var loadedModelPath: String?

    var modelMemoryFormatted: String {
        // WhisperKit doesn't expose exact live memory usage today. Rather
        // than show a made-up number (the old "~50 MB" constant was not
        // measuring anything real either), we're explicit about that.
        whisperProcessorLoaded ? "Cargado" : "N/A"
    }

    // MARK: - Model Loading

    /// - Parameter path: normally `model.localPath` from a `DownloadedModel`.
    ///   WhisperKit needs the **folder** containing the full model bundle
    ///   (see `WhisperProcessor.loadModel`). If `path` still points at a
    ///   single file — which is what the current download layer produces —
    ///   we fall back to its containing folder as a best effort, but this
    ///   only actually works once the downloader fetches the whole model
    ///   directory instead of one file (informe, sección 1.3). We surface a
    ///   clear, actionable error rather than silently failing later.
    func loadModel(at path: String) async throws {
        unloadModel()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw EngineError.modelFileNotFound(path)
        }
        let folderPath = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent

        do {
            try await processor.loadModel(folderPath: folderPath)
            whisperProcessorLoaded = true
            loadedModelPath = folderPath
            print("[TranscriptionEngine] Modelo cargado: \(folderPath)")
        } catch {
            whisperProcessorLoaded = false
            loadedModelPath = nil
            print("[TranscriptionEngine] Fallo al cargar el modelo: \(error.localizedDescription)")
            throw EngineError.modelLoadFailed(error.localizedDescription)
        }
    }

    func unloadModel() {
        print("[TranscriptionEngine] Descargando modelo")
        whisperProcessorLoaded = false
        loadedModelPath = nil
        Task { await processor.unload() }
    }

    // MARK: - Transcription

    func transcribe(
        audioAt audioURL: URL,
        language: String?,
        task: TranscriptionTask,
        progressHandler: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        guard whisperProcessorLoaded else {
            throw EngineError.noModelLoaded
        }

        progressHandler(TranscriptionProgress(taskId: "load_audio", fraction: 0.0, phase: "Leyendo audio…"))

        let samples: [Float]
        do {
            // Fully qualified because WhisperKit also exports a type named
            // `AudioProcessor` — without the module prefix this becomes an
            // ambiguous-type error once `import WhisperKit` is added anywhere
            // in the module. This app's own `AudioProcessor` (Services/AudioProcessor.swift)
            // already resamples to 16kHz mono Float32, which is exactly what
            // WhisperKit's `transcribe(audioArray:)` expects.
            samples = try WhisperLocal.AudioProcessor().loadAudio(from: audioURL).samples
        } catch {
            throw EngineError.transcriptionFailed("No se pudo leer el audio: \(error.localizedDescription)")
        }

        let whisperResult = try await processor.transcribe(
            samples: samples,
            language: language,
            task: task,
            onProgress: { fraction, phase in
                Task { @MainActor in
                    progressHandler(TranscriptionProgress(taskId: "transcribe", fraction: fraction, phase: phase))
                }
            }
        )

        let segments: [Transcription.Segment] = whisperResult.segments.enumerated().map { idx, seg in
            Transcription.Segment(id: idx, start: seg.start, end: seg.end, text: seg.text)
        }

        return TranscriptionResult(
            text: whisperResult.text,
            segments: segments,
            duration: Double(samples.count) / 16000.0,
            language: whisperResult.detectedLanguage ?? (language ?? "auto")
        )
    }

    // MARK: - Batch Transcription

    func transcribeBatch(
        audioURLs: [URL],
        language: String?,
        task: TranscriptionTask,
        progressHandler: @MainActor @escaping (TranscriptionProgress) -> Void
    ) async throws -> [TranscriptionResult] {
        guard whisperProcessorLoaded else {
            throw EngineError.noModelLoaded
        }

        var results: [TranscriptionResult] = []

        for (index, url) in audioURLs.enumerated() {
            progressHandler(TranscriptionProgress(
                taskId: "batch_\(index)",
                fraction: Double(index) / Double(audioURLs.count),
                phase: "Archivo \(index + 1)/\(audioURLs.count)"
            ))

            do {
                let result = try await transcribe(
                    audioAt: url,
                    language: language,
                    task: task,
                    progressHandler: progressHandler
                )
                results.append(result)
            } catch {
                print("[TranscriptionEngine] Fallo al transcribir \(url.lastPathComponent): \(error)")
                // Seguimos con el resto de los archivos del lote.
            }
        }

        progressHandler(TranscriptionProgress(taskId: "batch_complete", fraction: 1.0, phase: "Completado"))
        return results
    }
}

// MARK: - Engine Errors

enum EngineError: LocalizedError {
    case noModelLoaded
    case modelFileNotFound(String)
    case transcriptionFailed(String)
    case modelLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No hay ningún modelo cargado. Descarga y carga un modelo primero."
        case .modelFileNotFound(let path):
            return "No se encontró el modelo en: \(path)"
        case .transcriptionFailed(let reason):
            return "La transcripción falló: \(reason)"
        case .modelLoadFailed(let reason):
            return "No se pudo cargar el modelo: \(reason)"
        }
    }
}
