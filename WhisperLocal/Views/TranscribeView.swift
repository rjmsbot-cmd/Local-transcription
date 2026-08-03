import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Single-sheet driver for TranscribeView (see ModelsView for why stacking
/// two `.sheet` modifiers on one view breaks).
enum TranscribeSheet: Identifiable {
    case notesReview
    case export(Transcription)
    
    var id: String {
        switch self {
        case .notesReview: return "notes-review"
        case .export: return "export"
        }
    }
}

/// Real-time transcription monitor.
///
/// Transcribing is now started from the Record tab (recordings, voice memos,
/// imported files), so this tab has been repurposed as a LIVE MONITOR:
/// `AppState` is shared, therefore any transcription running anywhere in the
/// app shows up here in real time — streaming text, tokens/s, speed ×, window
/// and ETA. The old "pick audio → transcribe" flow is kept below as a
/// fallback while nothing is running.
struct TranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Query(filter: #Predicate<DownloadedModel> { $0.isDefault }) private var defaultModels: [DownloadedModel]
    @Query(sort: \DownloadedModel.downloadedAt, order: .reverse) private var allModels: [DownloadedModel]

    @State private var selectedAudioURL: URL?
    @State private var audioDuration: TimeInterval = 0
    @State private var audioFileName = ""
    @State private var transcriptionTitle = ""
    @State private var selectedLanguage = "auto"
    @State private var selectedTask: TranscriptionTask = .transcribe
    @State private var transcriptionResult: TranscriptionResult?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showingNotesPicker = false
    @State private var importedNotesText: String = ""
    // Single-sheet driver: SwiftUI only honors ONE .sheet per view, so the
    // old pair of .sheet(isPresented:) modifiers silently killed the notes
    // review sheet (the first one attached).
    @State private var activeSheet: TranscribeSheet?
    
    private let languages = [
        ("auto", "Auto-detect"),
        ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("ar", "Arabic"), ("hi", "Hindi"), ("ru", "Russian"),
        ("nl", "Dutch"), ("sv", "Swedish"), ("pl", "Polish"),
        ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese")
    ]
    
    private var activeModel: DownloadedModel? {
        defaultModels.first ?? allModels.first
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    
                    // Real-time monitor — the primary content of this tab.
                    // While a transcription runs (from any tab) it shows live
                    // text, progress and model stats; when idle it explains
                    // what will appear here instead of hiding.
                    liveMonitorCard
                    
                    if appState.isTranscribing {
                        // The monitor above is already showing everything live.
                    } else if let result = transcriptionResult {
                        resultCard(result)
                    } else {
                        audioPickerCard
                        
                        if selectedAudioURL != nil {
                            settingsCard
                            startButton
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Monitor")
            .background(Color(.systemGroupedBackground))
            .onReceive(appState.transcriptionEngine.objectWillChange) { _ in
                // Re-render when the model memory state changes (load/unload).
            }
            .fileImporter(
                isPresented: $showingNotesPicker,
                allowedContentTypes: [.text, .utf8PlainText, .rtf],
                allowsMultipleSelection: false
            ) { result in
                handleNotesImport(result)
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .notesReview:
                    NotesImportReviewView(
                        importedText: $importedNotesText,
                        onSave: { title in
                            saveImportedNotes(title: title)
                        }
                    )
                case .export(let transcription):
                    ExportSheet(transcription: transcription)
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
                    .fill(.blue.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue.gradient)
            }
            
            Text("Monitor de transcripción")
                .font(.title3.weight(.semibold))
            
            Text("Todo lo que se transcriba en la app aparece aquí en tiempo real, con el rendimiento del modelo.")
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

                // Live memory state — updates via onReceive above.
                HStack(spacing: 5) {
                    Image(systemName: engineLoaded ? "memorychip.fill" : "memorychip")
                        .font(.caption2)
                    Text(engineStatusText)
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(engineStatusColor.opacity(0.15))
                .clipShape(Capsule())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("No model loaded")
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
    
    // MARK: - Live Monitor
    
    private var liveMonitorCard: some View {
        VStack(spacing: 14) {
            // Monitor header
            HStack(spacing: 8) {
                Image(systemName: appState.isTranscribing ? "waveform.and.mic" : "waveform")
                    .foregroundStyle(.blue)
                Text(appState.isTranscribing ? "Monitor en tiempo real" : "Monitor")
                    .font(.headline)
                Spacer()
                if appState.isTranscribing {
                    if appState.transcriptionEngine.isLoadingModel {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                } else {
                    Circle()
                        .fill(.gray)
                        .frame(width: 8, height: 8)
                }
            }
            
            // Live text — auto-scrolls as tokens arrive
            ScrollViewReader { proxy in
                ScrollView {
                    Text(liveTextContent)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("liveText")
                }
                .frame(maxHeight: 240)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onChange(of: appState.currentPartialText) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("liveText", anchor: .bottom)
                    }
                }
            }
            
            if appState.isTranscribing {
                // Progress bar
                ProgressView(value: appState.transcriptionProgress) {
                    HStack {
                        Text(appState.transcriptionPhase.isEmpty ? "Transcribiendo…" : appState.transcriptionPhase)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(appState.transcriptionProgress * 100))%")
                            .font(.subheadline.monospacedDigit())
                    }
                }
                .progressViewStyle(.linear)
                .tint(.blue)
            }
            
            // Performance stats
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                monitorStat("Tokens/s", tokensLabel, icon: "bolt.fill")
                monitorStat("Velocidad", speedLabel, icon: "gauge.with.dots.needle.50percent")
                monitorStat("Ventana", windowLabel, icon: "rectangle.split.2x1")
                monitorStat("Tiempo", elapsedLabel, icon: "clock")
                monitorStat("Audio", audioStatLabel, icon: "music.note")
                monitorStat("Restante", etaLabel, icon: "timer")
            }
            
            // Model in use
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .font(.caption2)
                Text(appState.activeModelName ?? activeModel?.name ?? "—")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.blue.opacity(0.1))
            .clipShape(Capsule())
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    /// Placeholder text shown inside the live-text box: the idle hint when
    /// nothing is running, the model's partial transcript while decoding.
    private var liveTextContent: String {
        if appState.isTranscribing {
            return appState.currentPartialText.isEmpty
                ? "Esperando texto del modelo…"
                : appState.currentPartialText
        }
        return "Sin transcripción en curso.\n\nCuando lances una transcripción (desde Grabar, un audio importado o una nota de voz), el texto y el rendimiento del modelo aparecerán aquí en tiempo real."
    }
    
    private func monitorStat(_ title: String, _ value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    // MARK: - Live stats labels

    /// Tokens/s: "0.0" as soon as transcription starts (before the first
    /// window is decoded WhisperKit reports 0 — that's not an error, so we
    /// say so instead of hiding the value behind a "—").
    private var tokensLabel: String {
        guard appState.isTranscribing else { return "—" }
        return appState.tokensPerSecond > 0
            ? String(format: "%.1f", appState.tokensPerSecond)
            : "0.0"
    }

    /// Speed × realtime. "…" until WhisperKit reports a realtime factor.
    private var speedLabel: String {
        guard appState.isTranscribing else { return "—" }
        return appState.speedFactor > 0.01
            ? String(format: "%.1f×", appState.speedFactor)
            : "…"
    }

    /// Current window (1-based). Was wrongly gated on tokensPerSecond>0,
    /// which left it on "—" the whole time until decoding started; now it
    /// follows the real window index.
    private var windowLabel: String {
        guard appState.isTranscribing else { return "—" }
        return appState.currentWindowIndex > 0
            ? "\(appState.currentWindowIndex + 1)"
            : "1"
    }

    private var elapsedLabel: String {
        guard appState.isTranscribing else { return "—" }
        return appState.transcriptionElapsed >= 1
            ? ExportService.formatDuration(appState.transcriptionElapsed)
            : "0s"
    }

    /// Audio duration — "—" when idle instead of "0:00".
    private var audioStatLabel: String {
        guard appState.isTranscribing else { return "—" }
        return ExportService.formatDuration(appState.transcriptionAudioDuration)
    }

    /// ETA: remaining audio ÷ current realtime speed. "…" until speed is
    /// known (the model is warming up / decoding the first window).
    private var etaLabel: String {
        guard appState.isTranscribing else { return "—" }
        let elapsed = appState.transcriptionElapsed
        let duration = appState.transcriptionAudioDuration
        let speed = appState.speedFactor
        guard duration > 0, speed > 0.01 else { return "…" }
        let processed = min(duration, elapsed * speed)
        let remaining = max(0, duration - processed) / speed
        return remaining > 0 ? ExportService.formatDuration(remaining) : "…"
    }
    
    // MARK: - Audio Picker
    
    private var audioPickerCard: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    do {
                        // DocumentPickerService returns a sandbox copy of the
                        // picked file (asCopy: true) — no security-scoped access.
                        let url = try await DocumentPickerService.shared.present(forAudio: true)
                        let tempURL = try Self.copyAudioToTemp(url)
                        selectedAudioURL = tempURL
                        audioFileName = url.deletingPathExtension().lastPathComponent
                        transcriptionTitle = audioFileName
                        transcriptionResult = nil

                        Task {
                            do {
                                audioDuration = try appState.audioProcessor.getAudioDuration(at: tempURL)
                            } catch {
                                audioDuration = 0
                            }
                        }
                    } catch {
                        if (error as NSError).code != -1 { // Not cancelled
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "doc.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Select Audio File")
                            .font(.headline)
                        Text("MP3, WAV, M4A, FLAC, OGG, OPUS, AAC...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            
            // Voice Memos: the fastest path is Share → Whisper Local from the
            // Voice Memos app itself (the note lands in the Record tab). With
            // iCloud sync enabled, the picker can also browse iCloud Drive →
            // Notas de Voz directly.
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Notas de Voz: usa Compartir → Whisper Local desde la app Notas de Voz, o elige el audio en iCloud Drive → Notas de Voz desde este selector.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            
            // Notes import button
            Button {
                showingNotesPicker = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "note.text.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Importar archivo de texto")
                            .font(.headline)
                        Text(".txt, .rtf, .md...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            
            if selectedAudioURL != nil {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.title3)
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
                        clearAudio()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    // MARK: - Settings
    
    private var settingsCard: some View {
        VStack(spacing: 10) {
            TextField("Transcription title", text: $transcriptionTitle)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Text("Language")
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
                Text("Task")
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
            // The audio was already copied to a temp file when it was picked,
            // so no security-scoped access is needed here.
            Task { await startTranscription() }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Start Transcription")
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
    
    // MARK: - Result
    
    private func resultCard(_ result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Result")
                    .font(.headline)
                Spacer()
                Button {
                    if let result = transcriptionResult {
                        activeSheet = .export(makeTranscription(from: result))
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
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
                Label("\(result.segments.count) segments", systemImage: "list.number")
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

    private var engineLoaded: Bool {
        appState.transcriptionEngine.whisperProcessorLoaded
    }

    private var engineStatusText: String {
        if appState.transcriptionEngine.isLoadingModel {
            return appState.transcriptionEngine.loadPhase ?? "Cargando…"
        }
        return engineLoaded ? "En memoria" : "No cargado en memoria"
    }

    private var engineStatusColor: Color {
        if appState.transcriptionEngine.isLoadingModel { return .blue }
        return engineLoaded ? .green : .orange
    }

    /// Copies a picked file (already a sandbox copy from the picker) into a
    /// fresh temp location so the original stays untouched.
    private static func copyAudioToTemp(_ url: URL) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.removeItem(at: tempURL)
        try FileManager.default.copyItem(at: url, to: tempURL)
        return tempURL
    }

    private func handleNotesImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    if let text = String(data: data, encoding: .utf8) {
                        importedNotesText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        importedNotesText = String(data: data, encoding: .isoLatin1) ?? ""
                    }
                    activeSheet = .notesReview
                } catch {
                    errorMessage = "No se pudo leer el archivo: \(error.localizedDescription)"
                    showError = true
                }
            }
        case .failure(let error):
            errorMessage = "Error al importar: \(error.localizedDescription)"
            showError = true
        }
    }
    
    private func saveImportedNotes(title: String) {
        let transcription = Transcription(
            title: title,
            fullText: importedNotesText,
            segments: [],
            duration: 0,
            detectedLanguage: "importado",
            modelName: "Importado desde Notas",
            sourceFileName: "Notes"
        )
        modelContext.insert(transcription)
        try? modelContext.save()
        importedNotesText = ""
        activeSheet = nil
    }

    private func clearAudio() {
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
            // Load model if needed
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
            
            // Save to history
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
            title: transcriptionTitle.isEmpty ? "Untitled" : transcriptionTitle,
            fullText: result.text,
            segments: result.segments,
            duration: result.duration,
            detectedLanguage: result.language,
            modelName: activeModel?.name ?? "Unknown",
            sourceFileName: audioFileName
        )
    }

}
