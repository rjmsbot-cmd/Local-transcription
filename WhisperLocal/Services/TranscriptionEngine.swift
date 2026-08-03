import Foundation
import Combine
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
final class TranscriptionEngine: ObservableObject {
    private let processor = WhisperProcessor()

    // Mirrors the actor's state on the main actor so the UI can keep
    // reading these synchronously, exactly like before. @Published lets
    // the views react to load/unload immediately (load/unload toggles,
    // status pills, etc.).
    @Published private(set) var whisperProcessorLoaded = false
    @Published private(set) var loadedModelPath: String?
    /// True while a model is being loaded into memory (WhisperKit init can
    /// take several seconds for large models) — drives spinners in the UI.
    @Published private(set) var isLoadingModel = false
    /// Resolved folder of the model currently being loaded, so each row can
    /// show its own spinner instead of a global one.
    @Published private(set) var loadingModelPath: String?

    /// Guards against stale async work: every load/unload bumps it, and an
    /// in-flight `loadModel` discards its result if the generation moved on
    /// (e.g. the user hit ⏏ while the model was still loading).
    private var loadGeneration = 0

    /// True when the given model folder is the one currently loaded in memory.
    func isModelLoaded(at path: String?) -> Bool {
        guard let path, whisperProcessorLoaded, let loadedModelPath else { return false }
        return loadedModelPath == Self.resolvedFolder(for: path)
    }

    /// WhisperKit needs the **folder** containing the full model bundle. If a
    /// call passes a single file path (the download layer historically stored
    /// one file), resolve to its containing folder so every comparison and
    /// load is consistent.
    private static func resolvedFolder(for path: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return (path as NSString).deletingLastPathComponent
    }

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
        let folderPath = Self.resolvedFolder(for: path)

        // If the same model folder is already loaded, skip reload.
        if whisperProcessorLoaded, loadedModelPath == folderPath {
            print("[TranscriptionEngine] Modelo ya cargado: \(folderPath)")
            return
        }

        let generation = loadGeneration + 1
        loadGeneration = generation
        isLoadingModel = true
        loadingModelPath = folderPath
        whisperProcessorLoaded = false
        loadedModelPath = nil

        // Serialize with any in-flight unload: the processor actor runs
        // these in order, so awaiting here guarantees the previous model is
        // fully gone before we start loading the new one. (The old code
        // spawned `Task { await processor.unload() }` fire-and-forget, which
        // could land AFTER the load and silently unload the fresh model.)
        await processor.unload()

        defer {
            isLoadingModel = false
            loadingModelPath = nil
        }

        // Backfill the tokenizer if it is missing (downloads that predate
        // the tokenizer step, or that were interrupted before it):
        // WhisperKit refuses to load without tokenizer.json in the model
        // folder and would otherwise fail with a cryptic error.
        if !FileManager.default.fileExists(atPath: folderPath + "/tokenizer.json"),
           let size = HuggingFaceService.tokenizerSize(from: (folderPath as NSString).lastPathComponent) {
            try? await HuggingFaceService.shared.downloadTokenizerFiles(
                modelSize: size,
                destinationURL: URL(fileURLWithPath: folderPath),
                progress: { _, _ in }
            )
        }

        do {
            try await processor.loadModel(folderPath: folderPath)
            // A newer load/unload superseded us while we were loading; don't
            // clobber the state it set.
            guard generation == loadGeneration else { return }
            whisperProcessorLoaded = true
            loadedModelPath = folderPath
            print("[TranscriptionEngine] Modelo cargado: \(folderPath)")
        } catch {
            guard generation == loadGeneration else { return }
            whisperProcessorLoaded = false
            loadedModelPath = nil
            print("[TranscriptionEngine] Fallo al cargar el modelo: \(error.localizedDescription)")
            throw EngineError.modelLoadFailed(error.localizedDescription)
        }
    }

    func unloadModel() {
        // Bump the generation so any in-flight loadModel discards its result.
        // The UI state flips immediately; the actual processor teardown is
        // serialized on the processor actor (and any later loadModel awaits
        // it before loading).
        loadGeneration += 1
        isLoadingModel = false
        loadingModelPath = nil
        whisperProcessorLoaded = false
        loadedModelPath = nil
        print("[TranscriptionEngine] Descargando modelo")
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

        let audioDuration = Double(samples.count) / 16000.0
        let whisperResult = try await processor.transcribe(
            samples: samples,
            language: language,
            task: task,
            onProgress: { progress in
                Task { @MainActor in
                    progressHandler(progress)
                }
            }
        )

        let segments: [TranscriptionSegment] = whisperResult.segments.map { seg in
            TranscriptionSegment(
                startTime: seg.start,
                endTime: seg.end,
                text: seg.text,
                tokens: [],
                tokenLogProbs: [],
                temperature: 0,
                avgLogProb: 0,
                compressionRatio: 0,
                noSpeechProb: 0
            )
        }

        return TranscriptionResult(
            text: whisperResult.text,
            segments: segments,
            duration: audioDuration,
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
