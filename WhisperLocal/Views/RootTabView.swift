import SwiftUI

struct RootTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            TranscribeView()
                .tabItem {
                    Label("Record", systemImage: "mic")
                }
                .tag(0)
            
            TranscribeView()
                .tabItem {
                    Label("Transcribe", systemImage: "waveform")
                }
                .tag(1)
            
            ModelsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
                .tag(2)
            
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(3)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(4)
        }
        .tint(.accentColor)
    }
}
