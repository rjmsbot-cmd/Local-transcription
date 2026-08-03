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
                } else if filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(transcription.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            
            Text(transcription.fullText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            
            // Wrap-friendly chips: long model names / dates never overflow,
            // they wrap onto the next line and truncate gracefully.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                rowChip(icon: "calendar", text: transcription.createdAt.formatted(date: .abbreviated, time: .shortened))
                rowChip(icon: "clock", text: ExportService.formatDuration(transcription.duration))
                rowChip(icon: "globe", text: transcription.detectedLanguage)
                rowChip(icon: "cpu", text: transcription.modelName)
                rowChip(icon: "text.word.spacing", text: "\(transcription.wordCount) words")
                if !transcription.segments.isEmpty {
                    rowChip(icon: "list.number", text: "\(transcription.segments.count) segments")
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func rowChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
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
                // Metadata — adaptive grid so long model names wrap instead
                // of getting clipped by a fixed HStack of badges.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    MetaBadge(icon: "clock", text: ExportService.formatDuration(transcription.duration))
                    MetaBadge(icon: "globe", text: transcription.detectedLanguage)
                    MetaBadge(icon: "cpu", text: transcription.modelName)
                    MetaBadge(icon: "text.word.spacing", text: "\(transcription.wordCount) words")
                    if !transcription.segments.isEmpty {
                        MetaBadge(icon: "list.number", text: "\(transcription.segments.count) segments")
                    }
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
                            ForEach(Array(transcription.segments.enumerated()), id: \.offset) { index, seg in
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
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
