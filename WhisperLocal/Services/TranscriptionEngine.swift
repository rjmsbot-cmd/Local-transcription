import Foundation
import WhisperKit
import SwiftData

@MainActor
final class TranscriptionEngine: ObservableObject {
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    @Published var currentPhase: String = ""
    @Published var errorMessage: String?
    
    private var whisperKit: WhisperKit?
    private var currentModelPath: String?
    
    init() {}
    
    func loadModel(at modelPath: URL) async throws {
        currentPhase = "Cargando modelo..."
        
        do {
            whisperKit = try await WhisperKit()
            try await whisperKit?.loadModels()
            currentModelPath = modelPath.path()
            currentPhase = "Modelo cargado"
        } catch {
            self.errorMessage = "Error cargando modelo: \(error.localizedDescription)"
            throw error
        }
    }
    
    func transcribe(
        audioAt audioURL: URL,
        language: String?,
        task: TranscriptionTask? = nil,
        progressHandler: ((TranscriptionProgress) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        
        isTranscribing = true
        progress = 0
        currentPhase = "Preparando audio..."
        errorMessage = nil
        
        progressHandler?(TranscriptionProgress(fraction: 0, phase: "Preparando audio..."))
        
        do {
            currentPhase = "Transcribiendo..."
            progressHandler?(TranscriptionProgress(fraction: 0.1, phase: "Transcribiendo..."))
            
            let result = try await whisperKit.transcribe(audioPath: audioURL.path())
            
            progress = 1.0
            currentPhase = "Completado"
            progressHandler?(TranscriptionProgress(fraction: 1.0, phase: "Completado"))
            isTranscribing = false
            
            return TranscriptionResult(
                text: result.text,
                segments: result.segments.map { seg in
                    TranscriptionSegment(
                        startTime: seg.startTime,
                        endTime: seg.endTime,
                        text: seg.text,
                        tokens: seg.tokens ?? [],
                        tokenLogProbs: seg.tokenLogProbs ?? [],
                        temperature: seg.temperature ?? 0,
                        avgLogProb: seg.avgLogProb ?? 0,
                        compressionRatio: seg.compressionRatio ?? 0,
                        noSpeechProb: seg.noSpeechProb ?? 0
                    )
                },
                duration: result.duration,
                language: result.language ?? "unknown"
            )
        } catch {
            self.errorMessage = "Error en transcripción: \(error.localizedDescription)"
            isTranscribing = false
            throw error
        }
    }
    
    func transcribe(
        audioURL: URL,
        model: DownloadedModel,
        language: String = "auto",
        context: ModelContext
    ) async throws -> Transcription {
        let lang = language == "auto" ? nil : language
        
        if whisperKit == nil {
            guard let path = model.fullPath else {
                throw TranscriptionError.modelNotLoaded
            }
            try await loadModel(at: path)
        }
        
        let result = try await transcribe(audioAt: audioURL, language: lang)
        
        let transcription = Transcription(
            audioFileName: audioURL.lastPathComponent,
            audioFilePath: audioURL.path(),
            modelName: model.displayName,
            modelVariant: model.variant,
            language: result.language,
            fullText: result.text,
            duration: result.duration,
            segments: result.segments,
            wordTimestamps: [],
            wordTimestampsEnabled: false,
            useVad: false,
            chunkSize: .default,
            specialResults: nil
        )
        
        context.insert(transcription)
        try context.save()
        
        return transcription
    }
    
    func cancel() {
        isTranscribing = false
        progress = 0
        currentPhase = "Cancelado"
    }
}

enum TranscriptionTask: String, CaseIterable, Identifiable {
    case transcribe = "transcribe"
    case translate = "translate"
    
    var id: String { rawValue }
    
    var localized: String {
        switch self {
        case .transcribe: return "Transcribir"
        case .translate: return "Traducir"
        }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case audioProcessingFailed(String)
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No hay ningún modelo cargado. Descarga un modelo primero."
        case .audioProcessingFailed(let msg):
            return "Error procesando audio: \(msg)"
        case .transcriptionFailed(let msg):
            return "Error en la transcripción: \(msg)"
        }
    }
}
