import SwiftUI

struct RootTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            TranscribeView()
                .tabItem {
                    Label("Transcribe", systemImage: "waveform")
                }
                .tag(0)
            
            ModelsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
                .tag(1)
            
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(2)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(3)
        }
        .tint(.accentColor)
    }
}
