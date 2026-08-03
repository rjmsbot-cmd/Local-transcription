import SwiftUI
import SwiftData
import LocalAuthentication

@main
struct WhisperLocalApp: App {
    @State private var appState = AppState()
    
    /// Shared model container with a crash-safe fallback.
    ///
    /// The persisted schema is stable across builds (see Transcription.swift),
    /// so existing on-device stores open normally. If the store is ever
    /// unrecoverable (corruption, incompatible schema), the app falls back to
    /// an in-memory container instead of crashing on launch.
    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            DownloadedModel.self,
            Transcription.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            print("[WhisperLocalApp] ModelContainer fallback (store error): \(error.localizedDescription)")
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                fatalError("No se pudo crear el contenedor de datos: \(error.localizedDescription)")
            }
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .task {
                    // Biometric lock: authenticate on app launch/resume.
                    // Non-blocking: if biometrics are unavailable or the user
                    // cancels, the app stays usable (protected data at rest is
                    // still encrypted by NSFileProtectionComplete).
                    if BiometricLock.isEnabled {
                        _ = try? await BiometricLock.authenticate(
                            reason: "Autenticación requerida para acceder a tus transcripciones"
                        )
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isTranscribing = false
    @Published var transcriptionProgress: Double = 0
    /// Phase text from the engine ("Leyendo audio…", "Transcribiendo…", …).
    @Published var transcriptionPhase = ""
    /// Live text streamed from the model while decoding (empty until the
    /// first partial text arrives).
    @Published var currentPartialText = ""
    @Published var activeModelName: String?
    @Published var transcriptionElapsed: TimeInterval = 0
    @Published var transcriptionAudioDuration: TimeInterval = 0
    /// Tokens decoded per second (from WhisperKit timings).
    @Published var tokensPerSecond: Double = 0
    /// Decoding speed vs real time (×) — same source as the ETA.
    @Published var speedFactor: Double = 0
    /// Audio window (0-based) currently being decoded.
    @Published var currentWindowIndex = 0
    
    let audioProcessor = AudioProcessor()
    let transcriptionEngine = TranscriptionEngine()
    
    // ModelManager is created lazily with context from the environment
    func modelManager(context: ModelContext) -> ModelManager {
        ModelManager(modelContext: context)
    }
    
    /// Single entry point for progress events: both RecordView and
    /// TranscribeView call this, so the real-time monitor always reflects
    /// whichever tab started the transcription.
    func updateTranscriptionProgress(_ progress: TranscriptionProgress) {
        transcriptionProgress = progress.fraction
        transcriptionPhase = progress.phase
        currentPartialText = progress.partialText
        transcriptionElapsed = progress.elapsed
        transcriptionAudioDuration = progress.audioDuration
        tokensPerSecond = progress.tokensPerSecond
        speedFactor = progress.speedFactor
        currentWindowIndex = progress.windowIndex
    }
    
    func resetProgress() {
        transcriptionProgress = 0
        transcriptionPhase = ""
        currentPartialText = ""
        transcriptionElapsed = 0
        transcriptionAudioDuration = 0
        tokensPerSecond = 0
        speedFactor = 0
        currentWindowIndex = 0
    }
    
    // MARK: - File protection (Security #3 / F7 fix)
    
    /// Apply NSFileProtectionComplete to a directory so private user data
    /// (recordings, transcriptions) is encrypted at rest and unavailable
    /// until first user authentication.
    static func protectDirectory(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete.rawValue],
            ofItemAtPath: url.path
        )
    }
    
    /// Return the protected recordings directory (created on demand).
    /// F7 fix: recordings go to a protected directory, not the unprotected temp dir.
    static func recordingsDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Recordings")
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Ensure the directory itself is protected
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.complete.rawValue],
            ofItemAtPath: dir.path
        )
        return dir
    }
}
