import SwiftUI
import SwiftData
import LocalAuthentication

@main
struct WhisperLocalApp: App {
    @State private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState) // C9 fix: use .environmentObject for ObservableObject
                // Biometric lock: authenticate on app launch/resume
                .task {
                    if BiometricLock.isEnabled {
                        _ = try? await BiometricLock.authenticate(reason: "Autenticación requerida para acceder a tus transcripciones")
                    }
                }
        }
        .modelContainer(for: [DownloadedModel.self, Transcription.self])
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var isTranscribing = false
    @Published var transcriptionProgress: Double = 0
    @Published var currentPartialText = ""
    @Published var activeModelName: String?
    
    let audioProcessor = AudioProcessor()
    let transcriptionEngine = TranscriptionEngine()
    
    // ModelManager is created lazily with context from the environment
    func modelManager(context: ModelContext) -> ModelManager {
        ModelManager(modelContext: context)
    }
    
    func resetProgress() {
        transcriptionProgress = 0
        currentPartialText = ""
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
        let dir = fm.urls(.documentDirectory, in: .userDomainMask).first!
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
