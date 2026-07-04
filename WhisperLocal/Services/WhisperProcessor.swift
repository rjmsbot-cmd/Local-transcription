import Foundation
import WhisperKit

/// Thin wrapper around Argmax's WhisperKit.
///
/// WhisperKit already implements the full CoreML Whisper pipeline:
/// mel-spectrogram extraction, encoder + autoregressive decoder with KV
/// cache, BPE tokenization, language detection, 30s/VAD windowing and
/// word/segment timestamps — all tuned for the Apple Neural Engine.
///
/// The previous version of this file reimplemented all of that by hand
/// (a single `model.prediction()` call plus a "tokenizer" that treated
/// token IDs as raw bytes). That reimplementation is what produced empty
/// or garbled transcriptions with any real Whisper CoreML model — see
/// sección 1.1 del informe de viabilidad. This version delegates
/// everything to WhisperKit instead of re-solving an already-solved
/// problem.
actor WhisperProcessor {

    private var whisperKit: WhisperKit?
    private(set) var loadedModelFolder: String?

    var isLoaded: Bool { whisperKit != nil }

    // MARK: - Model lifecycle

    /// Loads a WhisperKit-compatible model from a local folder.
    ///
    /// - Important: `folderPath` must point to the **folder** that contains
    ///   the full set of compiled CoreML packages WhisperKit expects
    ///   (typically `AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`,
    ///   `MelSpectrogram.mlmodelc`, `config.json` and the tokenizer files),
    ///   NOT the path to a single `.mlmodelc` file. On HuggingFace these are
    ///   published as a directory, not a single blob — if your download
    ///   layer only fetches one file today, it needs to fetch the whole
    ///   directory first (see informe, sección 1.3). We validate that here
    ///   so the failure is explicit and actionable instead of a silent
    ///   garbage transcription.
    func loadModel(folderPath: String) async throws {
        unload()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WhisperProcessorError.notAModelFolder(folderPath)
        }

        guard Self.looksLikeWhisperKitModelFolder(at: folderPath) else {
            throw WhisperProcessorError.incompleteModelFolder(folderPath)
        }

        let config = WhisperKitConfig(
            modelFolder: folderPath,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            download: false // The model is already on disk; never hit the network from here.
        )

        do {
            whisperKit = try await WhisperKit(config)
            loadedModelFolder = folderPath
        } catch {
            whisperKit = nil
            loadedModelFolder = nil
            throw WhisperProcessorError.loadFailed(error.localizedDescription)
        }
    }

    func unload() {
        whisperKit = nil
        loadedModelFolder = nil
    }

    /// Best-effort sanity check that a folder actually looks like a
    /// WhisperKit model bundle before we hand it to WhisperKit and get a
    /// confusing low-level error back. Not exhaustive by design — WhisperKit
    /// itself is the source of truth for what a given version requires.
    private static func looksLikeWhisperKitModelFolder(at path: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        let hasEncoder = contents.contains { $0.contains("AudioEncoder") && $0.hasSuffix(".mlmodelc") }
        let hasDecoder = contents.contains { $0.contains("TextDecoder") && $0.hasSuffix(".mlmodelc") }
        return hasEncoder && hasDecoder
    }

    // MARK: - Transcription

    /// Transcribes a full array of 16kHz mono Float32 samples.
    ///
    /// WhisperKit internally handles 30s windowing / voice-activity-based
    /// chunking, language detection and BPE decoding, so the caller does
    /// not need to pre-chunk the audio (unlike the previous implementation,
    /// which fed the whole file into a model that expects fixed-size
    /// windows — see informe, sección 1.4).
    func transcribe(
        samples: [Float],
        language: String?,
        task: TranscriptionTask,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> WhisperResult {
        guard let whisperKit else { throw WhisperProcessorError.notLoaded }

        var options = DecodingOptions()
        options.task = (task == .translate) ? .translate : .transcribe
        options.language = language
        options.detectLanguage = (language == nil)
        options.wordTimestamps = true

        onProgress(0.05, "Cargando modelo en el Neural Engine…")

        // NOTE on progress: WhisperKit's `callback` fires repeatedly while
        // decoding, but the exact shape of `TranscriptionProgress` (field
        // names such as window index, tokens/sec, etc.) has changed between
        // WhisperKit releases — check the version actually resolved by
        // Xcode (Quick Help on `TranscriptionProgress`) if you want to wire
        // up a more granular bar than the two steps below.
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: { _ in
                onProgress(0.5, "Transcribiendo…")
                return true // returning false would cancel decoding early
            }
        )

        onProgress(1.0, "Completado")

        // A single call can return multiple chunk results when WhisperKit's
        // VAD-based chunking splits long audio into independently decoded
        // windows — stitch them back into one continuous result.
        let text = results.map(\.text).joined(separator: " ")
        let segments: [WhisperSegment] = results.flatMap { result in
            result.segments.map { seg in
                WhisperSegment(start: TimeInterval(seg.start), end: TimeInterval(seg.end), text: seg.text)
            }
        }
        let detectedLanguage = results.first?.language

        return WhisperResult(text: text, segments: segments, detectedLanguage: detectedLanguage)
    }
}

// MARK: - Result types

struct WhisperSegment {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct WhisperResult {
    let text: String
    let segments: [WhisperSegment]
    let detectedLanguage: String?
}

enum WhisperProcessorError: LocalizedError {
    case notAModelFolder(String)
    case incompleteModelFolder(String)
    case notLoaded
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAModelFolder(let path):
            return "\"\(path)\" no es una carpeta. WhisperKit necesita la carpeta completa del modelo, no un único archivo."
        case .incompleteModelFolder(let path):
            return "La carpeta \"\(path)\" no contiene un modelo WhisperKit completo (faltan AudioEncoder.mlmodelc y/o TextDecoder.mlmodelc). Revisa que la descarga haya traído todos los archivos del repositorio, no solo uno."
        case .notLoaded:
            return "No hay ningún modelo cargado."
        case .loadFailed(let reason):
            return "No se pudo cargar el modelo: \(reason)"
        }
    }
}
