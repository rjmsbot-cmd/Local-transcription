import SwiftUI
import SwiftData
import AVFoundation

struct RecordView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \DownloadedModel.downloadedAt, order: .reverse) private var allModels: [DownloadedModel]
    @Query(filter: #Predicate<DownloadedModel> { $0.isDefault }) private var defaultModels: [DownloadedModel]
    
    @StateObject private var recorder = RecordingService.shared
    @State private var inboxFiles: [URL] = []
    @State private var selectedAudioURL: URL?
    @State private var audioFileName = ""
    @State private var audioDuration: TimeInterval = 0
    @State private var transcriptionTitle = ""
    @State private var selectedLanguage = "auto"
    @State private var selectedTask: TranscriptionTask = .transcribe
    @State private var transcriptionResult: TranscriptionResult?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showingExport = false
    
    private var activeModel: DownloadedModel? {
        defaultModels.first ?? allModels.first
    }
    
    private let languages = [
        ("auto", "Auto-detect"),
        ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("ar", "Arabic"), ("hi", "Hindi"), ("ru", "Russian"),
        ("nl", "Dutch"), ("sv", "Swedish"), ("pl", "Polish"),
        ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese")
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    
                    if recorder.state == .idle && selectedAudioURL == nil {
                        recordAndImportSection
                        if !inboxFiles.isEmpty {
                            inboxSection
                        }
                    }
                    
                    if recorder.state == .recording || recorder.state == .paused {
                        recordingControlsCard
                    }
                    
                    if selectedAudioURL != nil && recorder.state != .recording && recorder.state != .paused {
                        selectedAudioCard
                    }
                    
                    if selectedAudioURL != nil && recorder.state != .recording && recorder.state != .paused {
                        settingsCard
                        startButton
                    }
                    
                    if appState.isTranscribing {
                        progressCard
                    }
                    
                    if let result = transcriptionResult, !appState.isTranscribing {
                        resultCard(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Record")
            .background(Color(.systemGroupedBackground))
            .onAppear { refreshInbox() }
            .onChange(of: scenePhase) { _, phase in
                // Refresh when returning from the share sheet / Voice Memos.
                if phase == .active { refreshInbox() }
            }
            .sheet(isPresented: $showingExport) {
                if let result = transcriptionResult {
                    let t = makeTranscription(from: result)
                    ExportSheet(transcription: t)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }
    
    // MARK: - Header
    
    private var headerCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "mic.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red.gradient)
            }
            
            Text("Grabar Nota de Voz")
                .font(.title3.weight(.semibold))
            
            Text("Graba directamente o importa desde tus notas de voz")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if let model = activeModel {
                HStack(spacing: 6) {
                    Image(systemName: "cpu.fill")
                        .font(.caption2)
                    Text(model.name)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.blue.opacity(0.1))
                .clipShape(Capsule())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("No hay modelo cargado")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Record & Import Section
    
    private var recordAndImportSection: some View {
        VStack(spacing: 12) {
            // Big record button
            Button {
                Task {
                    do {
                        try await recorder.startRecording()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.red, lineWidth: 4)
                        .frame(width: 100, height: 100)
                    Circle()
                        .fill(Color.red.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            
            Text("Toca para grabar")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()
                .padding(.vertical, 8)
            
            Text("O importa audio existente")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // Import options
            HStack(spacing: 12) {
                // Voice Memos (same picker: it can browse iCloud Drive → Notas
                // de Voz; direct sharing from Voice Memos arrives in the inbox
                // section below).
                Button {
                    importAudio()
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                                .frame(width: 50, height: 50)
                        Image(systemName: "waveform.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)
                        }
                        Text("Notas de Voz")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                
                // File picker
                Button {
                    importAudio()
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(.blue.opacity(0.15))
                                .frame(width: 50, height: 50)
                            Image(systemName: "doc.badge.plus")
                                .font(.title2)
                                .foregroundStyle(.blue)
                        }
                        Text("Archivo")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            
            Text("Notas de Voz: usa Compartir → Whisper Local desde la app Notas de Voz. Lo que compartas aparecerá abajo en «Notas de voz recibidas».")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    // MARK: - Inbox (Share Extension)
    
    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundColor(.purple)
                Text("Notas de voz recibidas (\(inboxFiles.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            
            ForEach(inboxFiles, id: \.self) { url in
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .foregroundColor(.purple)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(inboxDate(url)) · \(inboxSize(url))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        useInboxFile(url)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                    .accessibilityLabel("Usar esta nota")
                    
                    Button {
                        InboxStore.delete(url)
                        refreshInbox()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .accessibilityLabel("Eliminar")
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
            Text("Llegan aquí cuando compartes una grabación desde Notas de Voz (o Archivos) con Compartir → Whisper Local.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Recording Controls
    
    private var recordingControlsCard: some View {
        VStack(spacing: 16) {
            // Duration
            Text(formatDuration(recorder.currentDuration))
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            
            // Meter visual
            recordingMeterView
            
            // Status
            HStack(spacing: 8) {
                if recorder.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Grabando...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                } else if recorder.isPaused {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text("Pausado")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            
            // Controls
            HStack(spacing: 30) {
                // Discard
                Button {
                    recorder.discardRecording()
                    clearSelection()
                } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                
                // Pause / Resume
                Button {
                    if recorder.isRecording {
                        recorder.pauseRecording()
                    } else {
                        recorder.resumeRecording()
                    }
                } label: {
                    Image(systemName: recorder.isRecording ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                
                // Stop
                Button {
                    Task {
                        do {
                            let url = try recorder.stopRecording()
                            selectedAudioURL = url
                            audioFileName = "Nota de voz"
                            transcriptionTitle = "Nota de voz"
                            transcriptionResult = nil
                            
                            Task {
                                audioDuration = (try? appState.audioProcessor.getAudioDuration(at: url)) ?? 0
                            }
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Meter Visual
    
    private var recordingMeterView: some View {
        HStack(spacing: 3) {
            ForEach(0..<20, id: \.self) { i in
                let threshold = Float(i) / 20.0
                Circle()
                    .fill(recorder.dBLevel > threshold ? .green : .gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Selected Audio Card
    
    private var selectedAudioCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(audioFileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(ExportService.formatDuration(audioDuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                clearSelection()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Settings
    
    private var settingsCard: some View {
        VStack(spacing: 10) {
            TextField("Título de la transcripción", text: $transcriptionTitle)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Text("Idioma")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $selectedLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                Text("Tarea")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $selectedTask) {
                    ForEach(TranscriptionTask.allCases) { task in
                        Text(task.rawValue).tag(task)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Start Button
    
    private var startButton: some View {
        Button {
            Task { await startTranscription() }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Transcribir")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(activeModel != nil ? Color.blue : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(activeModel == nil || appState.isTranscribing)
    }
    
    // MARK: - Progress
    
    private var progressCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: appState.transcriptionProgress) {
                HStack {
                    Text(appState.transcriptionPhase.isEmpty ? progressPhaseText : appState.transcriptionPhase)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(appState.transcriptionProgress * 100))%")
                        .font(.subheadline.monospacedDigit())
                }
            }
            .progressViewStyle(.linear)
            .tint(.blue)
            
            if showLiveStats {
                HStack(spacing: 14) {
                    Label("\(tokensPerSecondLabel) tok/s", systemImage: "bolt.fill")
                    Label(speedFactorLabel, systemImage: "gauge.with.dots.needle.50percent")
                    Spacer()
                    Label("Restante: ~\(remainingLabel)", systemImage: "timer")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            
            if !appState.currentPartialText.isEmpty {
                Text(appState.currentPartialText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var progressPhaseText: String {
        if appState.transcriptionProgress < 0.1 { return "Preparando..." }
        if appState.transcriptionProgress < 0.95 { return "Transcribiendo..." }
        return "Finalizando..." }
    
    private var showLiveStats: Bool {
        appState.transcriptionElapsed >= 1 && appState.transcriptionProgress > 0.01
    }
    
    private var tokensPerSecondLabel: String {
        appState.tokensPerSecond > 0 ? String(format: "%.1f", appState.tokensPerSecond) : "—"
    }
    
    private var speedFactorLabel: String {
        appState.speedFactor > 0.01 ? String(format: "%.1f×", appState.speedFactor) : "—"
    }
    
    private var remainingLabel: String {
        let elapsed = appState.transcriptionElapsed
        let duration = appState.transcriptionAudioDuration
        let speed = appState.speedFactor
        guard duration > 0, speed > 0.01, elapsed > 0 else { return "—" }
        let processed = min(duration, elapsed * speed)
        let remaining = max(0, duration - processed) / speed
        return remaining > 0 ? ExportService.formatDuration(remaining) : "—"
    }
    
    // MARK: - Result
    
    private func resultCard(_ result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Resultado")
                    .font(.headline)
                Spacer()
                Button {
                    showingExport = true
                } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
            
            Text(result.text)
                .font(.body)
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            HStack(spacing: 16) {
                Label("\(result.segments.count) segmentos", systemImage: "list.number")
                Label(ExportService.formatDuration(result.duration), systemImage: "clock")
                Label(result.language, systemImage: "globe")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Logic

    private func importAudio() {
        Task {
            do {
                let url = try await DocumentPickerService.shared.present(forAudio: true)
                let tempURL = try Self.copyAudioToTemp(url)
                selectedAudioURL = tempURL
                audioFileName = url.deletingPathExtension().lastPathComponent
                transcriptionTitle = audioFileName
                transcriptionResult = nil
                
                Task {
                    audioDuration = (try? appState.audioProcessor.getAudioDuration(at: tempURL)) ?? 0
                }
            } catch {
                if (error as NSError).code != -1 { // Not cancelled
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private static func copyAudioToTemp(_ url: URL) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.removeItem(at: tempURL)
        try FileManager.default.copyItem(at: url, to: tempURL)
        return tempURL
    }

    private func refreshInbox() {
        inboxFiles = InboxStore.incomingAudioFiles()
    }

    /// Picks an inbox file: copy to temp so clearing the selection never
    /// deletes the original inbox item.
    private func useInboxFile(_ url: URL) {
        do {
            let tempURL = try Self.copyAudioToTemp(url)
            selectedAudioURL = tempURL
            audioFileName = url.deletingPathExtension().lastPathComponent
            transcriptionTitle = audioFileName
            transcriptionResult = nil
            Task {
                audioDuration = (try? appState.audioProcessor.getAudioDuration(at: tempURL)) ?? 0
            }
        } catch {
            errorMessage = "No se pudo copiar el archivo: \(error.localizedDescription)"
            showError = true
        }
    }

    private func inboxDate(_ url: URL) -> String {
        guard let date = url.fileModificationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func inboxSize(_ url: URL) -> String {
        let bytes = url.fileSizeBytes ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func clearSelection() {
        if let url = selectedAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        selectedAudioURL = nil
        audioDuration = 0
        audioFileName = ""
        transcriptionResult = nil
    }
    
    private func startTranscription() async {
        guard let audioURL = selectedAudioURL, let model = activeModel else { return }
        
        appState.isTranscribing = true
        appState.resetProgress()
        transcriptionResult = nil
        
        do {
            try await appState.transcriptionEngine.loadModel(at: model.fullPath?.path ?? "")
            appState.activeModelName = model.name
            
            let result = try await appState.transcriptionEngine.transcribe(
                audioAt: audioURL,
                language: selectedLanguage == "auto" ? nil : selectedLanguage,
                task: selectedTask,
                progressHandler: { progress in
                    appState.updateTranscriptionProgress(progress)
                }
            )
            
            transcriptionResult = result
            
            let transcription = makeTranscription(from: result)
            modelContext.insert(transcription)
            
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        
        appState.isTranscribing = false
    }
    
    private func makeTranscription(from result: TranscriptionResult) -> Transcription {
        Transcription(
            title: transcriptionTitle.isEmpty ? "Nota de voz" : transcriptionTitle,
            fullText: result.text,
            segments: result.segments,
            duration: result.duration,
            detectedLanguage: result.language,
            modelName: activeModel?.name ?? "Unknown",
            sourceFileName: audioFileName
        )
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
