import SwiftUI
import AVFoundation

struct RecordView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Query(sort: \DownloadedModel.downloadedAt, order: .reverse) private var allModels: [DownloadedModel]
    @Query(filter: #Predicate<DownloadedModel> { $0.isDefault }) private var defaultModels: [DownloadedModel]
    
    @StateObject private var recorder = RecordingService.shared
    @State private var showingVoiceMemos = false
    @State private var showingFilePicker = false
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
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .fileImporter(
                isPresented: $showingVoiceMemos,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                handleVoiceMemoImport(result)
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
                // Voice Memos
                Button {
                    showingVoiceMemos = true
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
                    showingFilePicker = true
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
        }
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
                    Text(progressPhaseText)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(appState.transcriptionProgress * 100))%")
                        .font(.subheadline.monospacedDigit())
                }
            }
            .progressViewStyle(.linear)
            .tint(.blue)
            
            if !appState.currentPartialText.isEmpty {
                Text(appState.currentPartialText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio_\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)
            
            selectedAudioURL = tempURL
            audioFileName = url.deletingPathExtension().lastPathComponent
            transcriptionTitle = audioFileName
            transcriptionResult = nil
            
            Task {
                audioDuration = (try? appState.audioProcessor.getAudioDuration(at: tempURL)) ?? 0
            }
            
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func handleVoiceMemoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicememo_\(UUID().uuidString).m4a")
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)
            
            selectedAudioURL = tempURL
            audioFileName = "Nota de voz"
            transcriptionTitle = "Nota de voz"
            transcriptionResult = nil
            
            Task {
                audioDuration = (try? appState.audioProcessor.getAudioDuration(at: tempURL)) ?? 0
            }
            
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
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
            try await appState.transcriptionEngine.loadModel(at: model.localPath)
            appState.activeModelName = model.name
            
            let result = try await appState.transcriptionEngine.transcribe(
                audioAt: audioURL,
                language: selectedLanguage == "auto" ? nil : selectedLanguage,
                task: selectedTask,
                progressHandler: { progress in
                    appState.transcriptionProgress = progress.fraction
                    appState.currentPartialText = progress.phase
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
