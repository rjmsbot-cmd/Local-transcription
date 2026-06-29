import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transcription.createdAt, order: .reverse) private var transcriptions: [Transcription]
    @State private var searchText = ""
    @State private var showDeleteAll = false
    
    private var filtered: [Transcription] {
        if searchText.isEmpty { return transcriptions }
        return transcriptions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.fullText.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if transcriptions.isEmpty {
                    ContentUnavailableView {
                        Label("No Transcriptions Yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Your transcription history will appear here after you transcribe audio files.")
                    }
                } else {
                    List {
                        ForEach(filtered) { t in
                            NavigationLink(destination: TranscriptionDetailView(transcription: t)) {
                                TranscriptionRow(transcription: t)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    modelContext.delete(t)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search transcriptions...")
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !transcriptions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showDeleteAll = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .confirmationDialog("Delete All Transcriptions?", isPresented: $showDeleteAll) {
                Button("Delete All", role: .destructive) {
                    for t in transcriptions { modelContext.delete(t) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}

// MARK: - Row

struct TranscriptionRow: View {
    let transcription: Transcription
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(transcription.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(transcription.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            Text(transcription.fullText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            
            HStack(spacing: 10) {
                Label(ExportService.formatDuration(transcription.duration), systemImage: "clock")
                Label(transcription.detectedLanguage, systemImage: "globe")
                Label(transcription.modelName, systemImage: "cpu")
                Spacer()
                Text("\(transcription.wordCount) words")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct TranscriptionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let transcription: Transcription
    @State private var showingExport = false
    @State private var showTimestamps = true
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Metadata
                HStack(spacing: 8) {
                    MetaBadge(icon: "clock", text: ExportService.formatDuration(transcription.duration))
                    MetaBadge(icon: "globe", text: transcription.detectedLanguage)
                    MetaBadge(icon: "cpu", text: transcription.modelName)
                    MetaBadge(icon: "text.word.spacing", text: "\(transcription.wordCount) words")
                }
                
                // Full text
                VStack(alignment: .leading, spacing: 8) {
                    Text("Full Text")
                        .font(.headline)
                    Text(transcription.fullText)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                // Timestamps toggle
                if !transcription.segments.isEmpty {
                    Toggle("Show Timestamps", isOn: $showTimestamps)
                        .font(.headline)
                        .padding(.top, 8)
                    
                    if showTimestamps {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(transcription.segments.enumerated()), id: \.element.id) { index, seg in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(seg.startTimeFormatted)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.blue)
                                        .frame(width: 65, alignment: .trailing)
                                    
                                    Text(seg.text)
                                        .font(.subheadline)
                                        .textSelection(.enabled)
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                
                                if index < transcription.segments.count - 1 {
                                    Divider().padding(.leading, 85)
                                }
                            }
                        }
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding()
        }
        .navigationTitle(transcription.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingExport = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(transcription: transcription)
        }
    }
}

struct MetaBadge: View {
    let icon: String
    let text: String
    
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
