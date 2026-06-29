import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Query private var models: [DownloadedModel]
    @Query private var transcriptions: [Transcription]
    @AppStorage("defaultLanguage") private var defaultLanguage = "auto"
    @AppStorage("defaultExportFormat") private var defaultExportFormat = "txt"
    @AppStorage("hapticEnabled") private var hapticEnabled = true
    @State private var showAbout = false
    
    var body: some View {
        NavigationStack {
            List {
                // Status
                Section {
                    StatusRow(
                        icon: "brain.head.profile",
                        iconColor: .purple,
                        title: "Neural Engine",
                        subtitle: "A17 Pro • 16-core • 35 TOPS",
                        status: .active
                    )
                    
                    StatusRow(
                        icon: "cpu",
                        iconColor: .blue,
                        title: "Active Model",
                        subtitle: appState.activeModelName ?? "None",
                        status: appState.activeModelName != nil ? .active : .warning
                    )
                    
                    StatusRow(
                        icon: "internaldrive",
                        iconColor: .green,
                        title: "Downloaded Models",
                        subtitle: "\(models.count) model\(models.count == 1 ? "" : "s")",
                        status: models.isEmpty ? .warning : .active
                    )
                    
                    StatusRow(
                        icon: "lock.shield",
                        iconColor: .green,
                        title: "Privacy",
                        subtitle: "100% on-device processing",
                        status: .active
                    )
                    
                    StatusRow(
                        icon: "clock.arrow.circlepath",
                        iconColor: .orange,
                        title: "Transcriptions",
                        subtitle: "\(transcriptions.count) saved",
                        status: .neutral
                    )
                } header: {
                    Text("Status")
                }
                
                // Preferences
                Section("Preferences") {
                    Picker("Default Language", selection: $defaultLanguage) {
                        Text("Auto-detect").tag("auto")
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                    }
                    
                    Toggle(isOn: $hapticEnabled) {
                        Label("Haptic Feedback", systemImage: "hand.tap")
                    }
                }
                
                // Info
                Section {
                    Button { showAbout = true } label: {
                        Label("About Whisper Local", systemImage: "info.circle")
                    }
                    
                    Link(destination: URL(string: "https://huggingface.co/models?pipeline_tag=automatic-speech-recognition&sort=downloads")!) {
                        Label("Browse Models on HuggingFace", systemImage: "globe")
                    }
                }
                
                // Footer
                Section {
                    VStack(spacing: 6) {
                        Text("Whisper Local v1.0")
                            .font(.footnote.weight(.medium))
                        Text("Optimized for iPhone 15 Pro with Apple Neural Engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("All transcription is performed entirely on your device.\nNo audio or text ever leaves your iPhone.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAbout) { AboutView() }
        }
    }
}

// MARK: - Status Row

enum StatusLevel { case active, warning, neutral }

struct StatusRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let status: StatusLevel
    
    var statusIcon: String {
        switch status {
        case .active: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "minus.circle.fill"
        }
    }
    
    var statusColor: Color {
        switch status {
        case .active: return .green
        case .warning: return .orange
        case .neutral: return .gray
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 70))
                        .foregroundStyle(.blue.gradient)
                    
                    Text("Whisper Local")
                        .font(.title.weight(.bold))
                    Text("Version 1.0")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("Fully local speech-to-text transcription powered by OpenAI's Whisper models, optimized for iPhone 15 Pro's Apple Neural Engine (A17 Pro).")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        FeatureRow(icon: "brain.head.profile", text: "Neural Engine optimized (35 TOPS)")
                        FeatureRow(icon: "lock.shield.fill", text: "100% on-device — zero network calls for inference")
                        FeatureRow(icon: "icloud.and.arrow.down", text: "Download models from HuggingFace")
                        FeatureRow(icon: "doc.text", text: "Export to SRT, VTT, TXT, JSON, CSV, Markdown")
                        FeatureRow(icon: "clock.arrow.circlepath", text: "Process audio files of any length")
                        FeatureRow(icon: "globe", text: "15+ languages supported")
                    }
                    .padding(.horizontal, 30)
                }
                .padding(.vertical, 30)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}
