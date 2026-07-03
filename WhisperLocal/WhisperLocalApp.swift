import SwiftUI
import SwiftData

@main
struct WhisperLocalApp: App {
    @StateObject private var appState = AppState()
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Transcription.self,
            DownloadedModel.self,
            TranscriptionSegment.self,
            TranscriptionWordTimestamp.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer error: \(error)")
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
        }
        .modelContainer(sharedModelContainer)
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
}
