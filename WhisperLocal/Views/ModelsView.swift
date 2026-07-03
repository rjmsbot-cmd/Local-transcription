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
    @State private var downloadingName: String = ""

    @State private var showDeleteAlert = false
    @State private var modelToDelete: DownloadedModel?

    // Variant selection
    @State private var showVariantSheet = false
    @State private var selectedModel: HFModel?
    @State private var availableVariants: [ModelVariant] = []
    @State private var isLoadingVariants = false

    @State private var errorMessage: String?
    @State private var showError = false
    
    @State private var modelLoadState: ModelLoadState = .idle

    // Computed
    private var isModelLoaded: Bool {
        appState.transcriptionEngine.whisperProcessorLoaded
    }
    private var loadedModelName: String? {
        appState.transcriptionEngine.loadedModelPath.flatMap { path in
            downloadedModels.first(where: { $0.localPath == path })?.name
        } ?? appState.activeModelName
    }
    
    private var modelMemoryFormatted: String {
        appState.transcriptionEngine.modelMemoryFormatted
    }

    var body: some View {
        NavigationStack {
            List {
                // Model status section
                modelStatusSection
                
                // Downloading progress (if active)
                if downloadingModelId != nil {
                    downloadingProgressSection
                }

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
                    ContentUnavailableView("No models found", systemImage: "magnifyingglass", description: Text("Try searching for \"whisper-small\", \"whisper-large-v3\", or \"qwen-asr\""))
                }
            }
            .navigationTitle("Models")
            .searchable(text: $searchText, prompt: "Search models (e.g. whisper-small, qwen-asr)")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await search() } } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        Button { Task { await loadPopular() } } label: {
                            Label("Popular Whisper Models", systemImage: "flame")
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
    
    // MARK: - Model Status Section
    
    private var modelStatusSection: some View {
        Section("Model in Memory") {
            HStack(spacing: 12) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(isModelLoaded ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 44, height: 44)
                    Image(systemName: isModelLoaded ? "checkmark" : "circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(isModelLoaded ? "Model Loaded" : "No Model Loaded")
                        .font(.headline)
                        .foregroundStyle(isModelLoaded ? .green : .secondary)
                    
                    if let name = loadedModelName {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack(spacing: 8) {
                        Label(modelMemoryFormatted, systemImage: "memorychip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        if isModelLoaded {
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text("Neural Engine ready")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
                
                Spacer()
                
                if isModelLoaded {
                    Button {
                        unloadModel()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                            Text("Unload")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Downloading Progress Section
    
    private var downloadingProgressSection: some View {
        Section("Downloading") {
            HStack {
                ProgressView(value: downloadProgress)
                VStack(alignment: .leading) {
                    Text(downloadingName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
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
                    ContentUnavailableView("No variants found", systemImage: "exclamationmark.triangle", description: Text("This model doesn't have any downloadable model files."))
                } else {
                    VStack(spacing: 12) {
                        if shouldRecommendCoreML {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundStyle(.blue)
                                Text("Core ML recommended — uses Neural Engine for faster inference")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                        }
                        
                        List {
                            Section("Available Variants") {
                                ForEach(availableVariants) { variant in
                                    VariantRowView(variant: variant) {
                                        Task { await startDownload(variant: variant) }
                                        showVariantSheet = false
                                    }
                                }
                            } header: {
                                Text("\(selectedModel?.displayName ?? "Model") — \(availableVariants.count) variants")
                            } footer: {
                                Text("⚡ Core ML uses the Neural Engine for best performance. GGUF/ONNX run on CPU.")
                            }
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
                    modelRow(model)
                }
            }
        } header: {
            Text("Downloaded (\(downloadedModels.count))")
        }
    }
    
    private func modelRow(_ model: DownloadedModel) -> some View {
        let isCurrentlyLoaded = isModelLoaded && loadedModelName == model.name
        
        return HStack(spacing: 12) {
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
                
                if isCurrentlyLoaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Loaded in memory")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()
            
            // Action buttons
            Menu {
                // Set as default
                if !model.isDefault {
                    Button {
                        setDefault(model)
                    } label: {
                        Label("Set Default", systemImage: "checkmark.circle")
                    }
                } else {
                    Button {
                        // Already default
                    } label: {
                        Label("Default", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(true)
                }
                
                // Load model
                if !isCurrentlyLoaded {
                    Button {
                        Task { await setDefaultAndLoad(model) }
                    } label: {
                        Label("Load Model", systemImage: "arrow.up.right.circle")
                    }
                } else {
                    Button {
                        // Already loaded
                    } label: {
                        Label("Loaded", systemImage: "checkmark.seal.fill")
                    }
                    .disabled(true)
                }
                
                Divider()
                
                // Delete
                Button {
                    modelToDelete = model
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .foregroundStyle(.red)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(downloadingModelId != nil)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Search Results Section

    private var searchResultsSection: some View {
        Section {
            ForEach(searchResults) { model in
                searchResultRow(model)
            }
        } header: {
            Text("Available Models (\(searchResults.count))")
        }
    }
    
    private func searchResultRow(_ model: HFModel) -> some View {
        let isDownloading = downloadingModelId == model.id
        
        return HStack(spacing: 12) {
            Image(systemName: model.isWhisperCompatible ? "waveform.circle.fill" : "brain.head.profile")
                .font(.title2)
                .foregroundStyle(model.isWhisperCompatible ? .blue : .purple)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.modelId)
                        .lineLimit(1)
                    if model.isWhisperCompatible {
                        Text("•")
                        Text("Whisper")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .clipShape(Capsule())
                    } else {
                        Text("•")
                        Text("ASR")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                if model.likes > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                        Text("\(model.likes)")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isDownloading {
                VStack(spacing: 4) {
                    ProgressCircle(progress: downloadProgress)
                        .frame(width: 30, height: 30)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task {
                        selectedModel = model
                        await loadVariants(for: model)
                    }
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(downloadingModelId != nil)
            }
        }
        .padding(.vertical, 4)
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

    // Only show Core ML variants since WhisperProcessor only supports Core ML
    private var coreMLVariants: [ModelVariant] {
        availableVariants.filter { $0.format == .coreML }
    }
    
    // Auto-select first Core ML variant if available
    private var recommendedVariant: ModelVariant? {
        coreMLVariants.first
    }
    
    // Check if we should show a Core ML recommendation
    private var shouldRecommendCoreML: Bool {
        !coreMLVariants.isEmpty && availableVariants.count > coreMLVariants.count
    }
    
    private func IfNoCoreMLWarning() -> some View {
        Group {
            if !coreMLVariants.isEmpty {
                EmptyView()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("No Core ML models available")
                        .font(.headline)
                    Text("This model doesn't have Core ML variants. WhisperProcessor only supports Core ML (.mlmodelc) models. Try searching for a different model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    private func startDownload(variant: ModelVariant) async {
        guard let hfModel = selectedModel else { return }
        downloadingModelId = hfModel.id
        downloadProgress = 0
        downloadingName = hfModel.displayName

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
        downloadingName = ""
    }

    private func setDefault(_ model: DownloadedModel) {
        for m in downloadedModels { m.isDefault = false }
        model.isDefault = true
    }

    private func setDefaultAndLoad(_ model: DownloadedModel) async {
        setDefault(model)
        await loadModel(model)
    }

    private func loadModel(_ model: DownloadedModel) async {
        modelLoadState = .loading
        
        do {
            try await appState.transcriptionEngine.loadModel(at: model.localPath)
            appState.activeModelName = model.name
            modelLoadState = .loaded
        } catch {
            modelLoadState = .error
            errorMessage = "Failed to load model: \(error.localizedDescription)"
            showError = true
        }
    }

    private func unloadModel() {
        modelLoadState = .unloading
        appState.transcriptionEngine.unloadModel()
        appState.activeModelName = nil
        modelLoadState = .idle
    }

    private func deleteModel(_ model: DownloadedModel) {
        // If this model is loaded, unload it first
        if isModelLoaded, loadedModelName == model.name {
            unloadModel()
        }
        Task {
            try? await appState.modelManager.deleteModel(model)
            await MainActor.run { modelContext.delete(model) }
        }
    }
}


// MARK: - Variant Row View (extracted to avoid compiler type-check timeout)

struct VariantRowView: View {
    let variant: ModelVariant
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: variant.format.icon)
                    .font(.title2)
                    .foregroundStyle(variant.format == ModelFormat.coreML ? .blue : .orange)
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
                            .background(variant.format == ModelFormat.coreML ? .blue.opacity(0.15) : .orange.opacity(0.15))
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
}

// MARK: - Model Load State

enum ModelLoadState {
    case idle
    case loading
    case loaded
    case unloading
    case error
}

// MARK: - Progress Circle

struct ProgressCircle: View {
    let progress: Double
    
    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .foregroundStyle(.blue)
            .rotationEffect(.degrees(-90))
            .animation(.easeInOut, value: progress)
            .overlay {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 3)
            }
    }
}
