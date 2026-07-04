import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import UIKit

struct TranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Query(filter: #Predicate<DownloadedModel> { $0.isDefault }) private var defaultModels: [DownloadedModel]
    @Query(sort: \DownloadedModel.downloadedAt, order: .reverse) private var allModels: [DownloadedModel]
    @ObservedObject var documentPickerService = DocumentPickerService.shared
    
    @State private var showingFilePicker = false
    @State private var showingExport = false
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
    @State private var showingImportedNotes = false
    
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
                    audioPickerCard
                    
                    if selectedAudioURL != nil {
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
            .navigationTitle("Whisper Local")
            .background(Color(.systemGroupedBackground))
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: audioContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .fileImporter(
                isPresented: $showingNotesPicker,
                allowedContentTypes: [.text, .utf8PlainText, .rtf],
                allowsMultipleSelection: false
            ) { result in
                handleNotesImport(result)
            }
            .sheet(isPresented: $showingImportedNotes) {
                NotesImportReviewView(
                    importedText: $importedNotesText,
                    onSave: { title in
                        saveImportedNotes(title: title)
                    }
                )
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
                    .fill(.blue.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue.gradient)
            }
            
            Text("On-Device Transcription")
                .font(.title3.weight(.semibold))
            
            Text("100% local processing using Apple Neural Engine.\nNo data leaves your iPhone.")
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
    
    // MARK: - Audio Picker
    
    private var audioPickerCard: some View {
        VStack(spacing: 12) {
            Button {
                showingFilePicker = true
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
                        Text(task.rawValue).tag(task.rawValue)
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
            let accessing = selectedAudioURL.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
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
        if appState.transcriptionProgress < 0.1 { return "Preparing..." }
        if appState.transcriptionProgress < 0.95 { return "Transcribing..." }
        return "Finalizing..."
    }
    
    // MARK: - Result
    
    private func resultCard(_ result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Result")
                    .font(.headline)
                Spacer()
                Button {
                    showingExport = true
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
    
    private var audioContentTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        for ext in AudioProcessor.supportedExtensions {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            // Copy to temp (security scoped bookmark won't persist)
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
                    appState.transcriptionProgress = progress.fraction
                    appState.currentPartialText = progress.phase
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
    
    // MARK: - Notes Import
    
    private func handleNotesImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = selectedAudioURL.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    if let text = String(data: data, encoding: .utf8) {
                        importedNotesText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        importedNotesText = String(data: data, encoding: .isoLatin1) ?? ""
                    }
                    showingImportedNotes = true
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
        showingImportedNotes = false
    }
}
