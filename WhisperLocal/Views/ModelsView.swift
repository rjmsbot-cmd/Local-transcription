import SwiftUI
import SwiftData

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @Query(sort: \DownloadedModel.downloadedAt, order: .reverse) private var downloadedModels: [DownloadedModel]

    @State private var searchText = ""
    @State private var searchResults: [HFModel] = []
    @State private var isSearching = false

    @State private var downloadingModelId: String?
    @State private var downloadProgress: Double = 0

    @State private var showDeleteAlert = false
    @State private var modelToDelete: DownloadedModel?

    // Variant selection
    @State private var showVariantSheet = false
    @State private var selectedModel: HFModel?
    @State private var availableVariants: [ModelVariant] = []
    @State private var isLoadingVariants = false

    @State private var errorMessage: String?
    @State private var showError = false

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
                    ContentUnavailableView("No Whisper models found", systemImage: "magnifyingglass", description: Text("Try searching for \"whisper-small\" or \"whisper-large-v3\""))
                }
            }
            .navigationTitle("Models")
            .searchable(text: $searchText, prompt: "Search Whisper models (e.g. whisper-small)")
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
            .sheet(isPresented: $showVariantSheet) {
                variantPickerSheet
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

    // MARK: - Variant Picker Sheet

    private var variantPickerSheet: some View {
        NavigationStack {
            Group {
                if isLoadingVariants {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading available variants...")
                            .foregroundStyle(.secondary)
                    }
                } else if availableVariants.isEmpty {
                    ContentUnavailableView("No variants found", systemImage: "exclamationmark.triangle", description: Text("This model doesn't have downloadable files."))
                } else {
                    List {
                        Section {
                            ForEach(availableVariants) { variant in
                                Button {
                                    Task { await startDownload(variant: variant) }
                                    showVariantSheet = false
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: variant.format.icon)
                                            .font(.title2)
                                            .foregroundStyle(variant.format == .coreML ? .blue : .orange)
                                            .frame(width: 36)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(variant.quantization)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Text(variant.fileName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            HStack(spacing: 8) {
                                                Text(variant.format.badge)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(variant.format == .coreML ? .blue.opacity(0.15) : .orange.opacity(0.15))
                                                    .clipShape(Capsule())
                                                Text(variant.fileSizeFormatted)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        Image(systemName: "icloud.and.arrow.down")
                                            .foregroundStyle(.blue)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        } header: {
                            Text("\(selectedModel?.displayName ?? "Model") — \(availableVariants.count) variants")
                        } footer: {
                            Text("⚡ Core ML uses the Neural Engine for best performance on iPhone 15 Pro. GGUF/ONNX run on CPU.")
                        }
                    }
                }
            }
            .navigationTitle("Select Variant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showVariantSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
                            .foregroundStyle(model.isDefault ? .blue : .gray.opacity(0.3))
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
                        .foregroundStyle(.gray)
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
                            selectedModel = model
                            Task { await loadVariants(for: model) }
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
            Text("Whisper Models (\(searchResults.count))")
        }
    }

    // MARK: - Actions

    private func search() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
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

    private func loadVariants(for model: HFModel) async {
        isLoadingVariants = true
        showVariantSheet = true
        defer { isLoadingVariants = false }

        do {
            availableVariants = try await appState.modelManager.listVariants(repoId: model.modelId)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            showVariantSheet = false
        }
    }

    private func startDownload(variant: ModelVariant) async {
        guard let hfModel = selectedModel else { return }
        downloadingModelId = hfModel.id
        downloadProgress = 0

        do {
            let (model, stream) = try await appState.modelManager.downloadModelWithProgress(hfModel, variant: variant)

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
