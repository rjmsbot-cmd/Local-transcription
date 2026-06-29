import SwiftUI
import SwiftData

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Query(sort: \DownloadedModel.downloadedAt, order: .reverse) private var downloadedModels: [DownloadedModel]
    
    @State private var searchText = ""
    @State private var searchResults: [HFModel] = []
    @State private var isSearching = false
    @State private var searchError: String?
    
    @State private var downloadingModelId: String?
    @State private var downloadProgress: Double = 0
    
    @State private var showDeleteAlert = false
    @State private var modelToDelete: DownloadedModel?
    @State private var errorMessage: String?
    @State private var showError = false
    
    private let recommendedTags = ["whisper-tiny", "whisper-small", "whisper-base", "whisper-large-v3"]
    
    var body: some View {
        NavigationStack {
            List {
                downloadedSection
                
                if isSearching {
                    HStack {
                        Spacer()
                        ProgressView("Searching HuggingFace...")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                
                if !searchResults.isEmpty {
                    searchResultsSection
                }
                
                if searchResults.isEmpty && !isSearching && !searchText.isEmpty {
                    ContentUnavailableView("No results", systemImage: "magnifyingglass", description: Text("Try a different search term"))
                }
            }
            .navigationTitle("Models")
            .searchable(text: $searchText, prompt: "Search HuggingFace (e.g. whisper-small)")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await search() } } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        Button { Task { await loadPopular() } } label: {
                            Label("Popular Models", systemImage: "flame")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Delete Model", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let m = modelToDelete { deleteModel(m) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the downloaded model file from your device.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .task {
                if searchResults.isEmpty { await loadPopular() }
            }
        }
    }
    
    // MARK: - Downloaded Section
    
    private var downloadedSection: some View {
        Section {
            if downloadedModels.isEmpty {
                ContentUnavailableView {
                    Label("No Models Downloaded", systemImage: "arrow.down.circle.dashed")
                } description: {
                    Text("Search and download a Whisper model to start transcribing.\n\nRecommended: whisper-small (good balance of speed and quality)")
                }
            } else {
                ForEach(downloadedModels) { model in
                    HStack(spacing: 12) {
                        Image(systemName: model.isDefault ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.isDefault ? .blue : .tertiary)
                            .font(.title3)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name)
                                .font(.headline)
                            HStack(spacing: 6) {
                                Text(model.repoId)
                                    .lineLimit(1)
                                Text("•")
                                Text(model.fileSizeFormatted)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if downloadingModelId == model.id.uuidString {
                            ProgressView(value: downloadProgress)
                                .frame(width: 60)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { setDefault(model) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            modelToDelete = model
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Downloaded (\(downloadedModels.count))")
        }
    }
    
    // MARK: - Search Results
    
    private var searchResultsSection: some View {
        Section {
            ForEach(searchResults) { model in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(model.modelId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            if let author = model.author {
                                Text("@\(author)")
                            }
                            Label(model.downloads.abbreviated, systemImage: "arrow.down")
                            Label(model.likes.abbreviated, systemImage: "heart")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    
                    Spacer()
                    
                    if downloadingModelId == model.id {
                        ProgressView(value: downloadProgress)
                            .frame(width: 50)
                    } else if downloadedModels.contains(where: { $0.repoId == model.modelId }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await downloadModel(model) }
                        } label: {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .disabled(downloadingModelId != nil)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Available (\(searchResults.count))")
        }
    }
    
    // MARK: - Actions
    
    private func search() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        
        do {
            searchResults = try await appState.modelManager.searchModels(query: searchText)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func loadPopular() async {
        isSearching = true
        defer { isSearching = false }
        
        do {
            searchResults = try await appState.modelManager.getPopularModels()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func downloadModel(_ hfModel: HFModel) async {
        downloadingModelId = hfModel.id
        downloadProgress = 0
        
        do {
            let (model, stream) = try await appState.modelManager.downloadModelWithProgress(hfModel)
            
            for try await progress in stream {
                downloadProgress = progress
            }
            
            if downloadedModels.isEmpty {
                model.isDefault = true
            }
            modelContext.insert(model)
            searchResults.removeAll { $0.id == hfModel.id }
            
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        
        downloadingModelId = nil
        downloadProgress = 0
    }
    
    private func setDefault(_ model: DownloadedModel) {
        for m in downloadedModels { m.isDefault = false }
        model.isDefault = true
    }
    
    private func deleteModel(_ model: DownloadedModel) {
        try? appState.modelManager.deleteModel(model)
        modelContext.delete(model)
    }
}

// MARK: - Int Extension

private extension Int {
    var abbreviated: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", Double(self) / 1_000) }
        return "\(self)"
    }
}
