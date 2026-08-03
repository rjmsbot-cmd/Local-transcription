import Foundation
import SwiftUI
import SwiftData

/// Single-sheet driver for ModelsView.
///
/// SwiftUI only honors ONE `.sheet` modifier per view — stacking two
/// `isPresented:` sheets on the same view silently kills the first one.
/// That was why tapping a search result appeared to do nothing (the
/// variant picker sheet never presented). A single `.sheet(item:)` driven
/// by this enum makes both flows work.
enum ModelSheet: Identifiable {
    case variantPicker(HFRepoInfo)
    case download(HFRepoInfo, String)
    
    var id: String {
        switch self {
        case .variantPicker(let repo): return "variants-\(repo.id)"
        case .download(let repo, let variant): return "download-\(repo.id)-\(variant)"
        }
    }
}

/// Alert shown when tapping a search result that cannot be installed
/// (non-Whisper architecture or gated repo). Explains WHY instead of
/// opening an empty variant picker.
struct ModelBlockAlert: Identifiable {
    let id = UUID()
    let repo: HFRepoInfo
    let status: ModelSearchStatus
}

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @State private var manager: ModelManager?
    @State private var searchQuery = ""
    @State private var coremlOnly = true // F5: filter toggle for CoreML-compatible models
    @State private var activeSheet: ModelSheet?
    @State private var blocking: ModelBlockAlert?
    @State private var diskSpace: String = ""
    @State private var searchTask: Task<Void, Never>?

    /// Featured recommendation: Whisper Large V3 Turbo QUANTIZED (954 MB),
    /// installed directly from the canonical WhisperKit repo with one tap.
    /// Ronda 11: the full-precision fp16 variant (3.2 GB) made iPhones sit
    /// on "cargando" for minutes (memory/ANE pressure, device heats up and
    /// the load never completes). The 954 MB quantization is ~6× faster than
    /// large-v3, loads in seconds and is nearly identical in quality — the
    /// fp16 stays available in the variant picker for anyone who wants it.
    private var featuredTurbo: HFRepoInfo {
        HFModel(
            id: "argmaxinc/whisperkit-coreml",
            modelId: "argmaxinc/whisperkit-coreml",
            author: "argmaxinc",
            pipelineTag: "automatic-speech-recognition",
            tags: ["coreml", "whisper"],
            downloads: nil,
            likes: nil,
            lastModified: nil
        )
    }

    private var isFeaturedInstalled: Bool {
        manager?.downloadedModels.contains {
            $0.name == featuredTurbo.modelId && $0.variant == "openai_whisper-large-v3_turbo_954MB"
        } ?? false
    }

    /// While searching, the featured card is hidden by the results branch.
    /// If the query clearly targets the turbo model (the repo name itself
    /// does NOT contain "large/turbo/v3", so plain HF search misses it),
    /// surface the direct-install card at the top of the results.
    private var shouldSuggestFeatured: Bool {
        guard !isFeaturedInstalled else { return false }
        let q = searchQuery.lowercased()
        return ["whisper", "turbo", "large", "v3", "coreml", "argmax", "rápido", "rapido"].contains { q.contains($0) }
    }

    /// Routes a tap on a search result: installable candidates open the
    /// variant picker; blocked ones explain themselves instead of showing
    /// an empty picker after a slow full-tree listing.
    private func openResult(_ result: ModelSearchResult) {
        switch result.status {
        case .incompatible, .authRequired:
            blocking = ModelBlockAlert(repo: result.model, status: result.status)
        case .compatible, .likelyCompatible, .unknown:
            activeSheet = .variantPicker(result.model)
        }
    }
    
    var body: some View {
        Group {
            if manager == nil {
                ProgressView("Cargando...")
                    .onAppear { manager = ModelManager(modelContext: modelContext) }
            } else {
                contentView
            }
        }
        .navigationTitle("Modelos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .variantPicker(let repo):
                VariantSelectorSheet(
                    repo: repo,
                    manager: manager!,
                    modelContext: modelContext,
                    onVariantSelected: { variantPath in
                        activeSheet = .download(repo, variantPath)
                    },
                    onCancel: {
                        activeSheet = nil
                    }
                )
            case .download(let repo, let variant):
                DownloadSheet(
                    repo: repo,
                    variant: variant,
                    manager: manager!,
                    modelContext: modelContext,
                    isPresented: Binding(
                        get: { activeSheet != nil },
                        set: { if !$0 { activeSheet = nil } }
                    )
                )
            }
        }
        .alert(item: $blocking) { alert in
            switch alert.status {
            case .incompatible:
                return Alert(
                    title: Text("Modelo no compatible"),
                    message: Text("«\(alert.repo.displayName)» no se puede cargar con WhisperKit: usa otra arquitectura (Qwen3-ASR, Parakeet, Nemotron…).\n\nSolo funcionan los modelos Whisper con AudioEncoder, TextDecoder y MelSpectrogram en CoreML."),
                    dismissButton: .default(Text("Entendido"))
                )
            case .authRequired:
                return Alert(
                    title: Text("Requiere autenticación"),
                    message: Text("«\(alert.repo.displayName)» es un repositorio con acceso restringido.\n\nAñade un token de Hugging Face en Ajustes para poder descargarlo."),
                    dismissButton: .default(Text("Entendido"))
                )
            default:
                return Alert(
                    title: Text("No disponible"),
                    message: Text("Este repositorio no puede instalarse en la app."),
                    dismissButton: .default(Text("Entendido"))
                )
            }
        }
    }
    
    private var contentView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Buscar modelos...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { performSearch() }
                    .onChange(of: searchQuery) { _, newValue in
                        searchTask?.cancel()
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            manager?.resetSearch()
                            Task { await manager?.loadRecommendations() }
                        } else {
                            // Debounce: wait for a typing pause before
                            // hitting the Hub (600 ms).
                            searchTask = Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                guard !Task.isCancelled else { return }
                                await manager?.searchModels(query: trimmed, coreMLOnly: coremlOnly)
                            }
                        }
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchTask?.cancel()
                        searchQuery = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
            
            // F5: WhisperKit-only search toggle. OFF widens the query to
            // all ASR repos (classified and ranked last when incompatible).
            HStack {
                Toggle(isOn: $coremlOnly) {
                    Text("Solo WhisperKit (CoreML)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .toggleStyle(.switch)
                .onChange(of: coremlOnly) { _, _ in
                    guard manager?.hasSearched == true,
                          !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    searchTask?.cancel()
                    searchTask = Task { await manager?.searchModels(query: searchQuery, coreMLOnly: coremlOnly) }
                }
                Spacer()
                if !coremlOnly {
                    Text("Incluye otras arquitecturas (se marcan como no compatibles)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .padding(.top, 8)
            
            HStack {
                Image(systemName: "internaldrive").foregroundColor(.secondary)
                Text("Espacio: \(diskSpace)").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 4)
            
            if manager!.isLoading {
                ProgressView(manager!.hasSearched ? "Buscando y verificando compatibilidad…" : "Cargando recomendados…")
                    .frame(height: 100)
            } else if let error = manager!.errorMessage {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(height: 100)
            } else {
                List {
                    if !manager!.downloadedModels.isEmpty {
                        Section {
                            ForEach(manager!.downloadedModels) { model in
                                ModelRow(model: model, manager: manager!)
                            }
                            .onDelete { indices in
                                for index in indices {
                                    try? manager!.removeModel(manager!.downloadedModels[index], context: modelContext)
                                }
                            }
                        } header: {
                            Text("Descargados (\(manager!.downloadedModels.count))").font(.headline)
                        } footer: {
                            Text("▶ Carga el modelo en memoria (RAM) para poder transcribir. ⏏ Lo libera de la memoria; los archivos descargados se conservan en el iPhone.")
                        }
                    }
                    if manager!.hasSearched {
                        let results = manager!.availableModels
                        if !results.isEmpty {
                            Section {
                                if shouldSuggestFeatured {
                                    FeaturedModelRow(
                                        isInstalled: isFeaturedInstalled,
                                        onInstall: {
                                            activeSheet = .download(featuredTurbo, "openai_whisper-large-v3_turbo_954MB")
                                        }
                                    )
                                }
                                ForEach(results) { result in
                                    SearchResultRow(
                                        repo: result.model,
                                        status: result.status,
                                        onDownload: { openResult(result) }
                                    )
                                }
                            } header: {
                                Text("Resultados (\(results.count))").font(.headline)
                            } footer: {
                                if shouldSuggestFeatured {
                                    Text("La búsqueda no encuentra el repo por nombre (no contiene “large/turbo/v3”), así que Whisper Large V3 Turbo aparece aquí con instalación directa.")
                                }
                            }
                        } else if manager!.downloadedModels.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "Sin resultados",
                                    systemImage: "magnifyingglass",
                                    description: Text("Prueba con otro término de búsqueda.")
                                )
                                .padding(.vertical, 20)
                            }
                        }
                    } else {
                        Section {
                            FeaturedModelRow(
                                isInstalled: isFeaturedInstalled,
                                onInstall: {
                                    activeSheet = .download(featuredTurbo, "openai_whisper-large-v3_turbo_954MB")
                                }
                            )
                        } header: {
                            Text("Destacado · Instalación directa")
                        } footer: {
                            Text("Whisper Large V3 Turbo cuantizada (954 MB): la calidad de large-v3 con ≈6× más velocidad, carga en segundos y sin calentar el móvil. La versión de precisión completa (3,2 GB) está en el selector de variantes si la quieres probar.")
                        }
                        if !manager!.recommendedModels.isEmpty {
                            Section("Recomendados (\(manager!.recommendedModels.count))") {
                                ForEach(manager!.recommendedModels) { result in
                                    SearchResultRow(
                                        repo: result.model,
                                        status: result.status,
                                        onDownload: { openResult(result) }
                                    )
                                }
                            }
                        } else if manager!.downloadedModels.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "Sin modelos",
                                    systemImage: "brain",
                                    description: Text("Busca un modelo de Whisper en Hugging Face.")
                                )
                                .padding(.vertical, 20)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { diskSpace = manager?.diskSpaceAvailable ?? "..." }
    }
    
    private func performSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { await manager?.searchModels(query: searchQuery, coreMLOnly: coremlOnly) }
    }
    
    private func refresh() {
        manager?.loadLocalModels(context: modelContext)
        manager?.updateDiskSpace()
        diskSpace = manager?.diskSpaceAvailable ?? "..."
        if !(manager?.hasSearched ?? false) {
            Task { await manager?.loadRecommendations() }
        }
    }
}

struct ModelRow: View {
    let model: DownloadedModel
    @ObservedObject var manager: ModelManager
    @Environment(\.modelContext) private var modelContext
    @State private var showDelete = false
    @State private var loadErrorMessage: String?
    @State private var showLoadError = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName).font(.headline)
                HStack(spacing: 4) {
                    TagLabel(title: "Variante", value: model.variant)
                    TagLabel(title: "Formato", value: model.format)
                }
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(model.status.rawValue.capitalized).font(.caption2)
                    Text(formatBytes(model.sizeBytes)).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            if model.status == .downloading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Descargando en 2º plano…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if model.status == .failed {
                Button {
                    Task {
                        do {
                            try await manager.retryDownload(model, context: modelContext)
                        } catch {
                            loadErrorMessage = error.localizedDescription
                            showLoadError = true
                        }
                    }
                } label: {
                    Label("Reintentar", systemImage: "arrow.clockwise.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            } else if model.status == .ready {
                if model.isWhisperKitCompatibleFolder {
                    HStack(spacing: 8) {
                        if isModelLoaded {
                            Text("En memoria")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                            Button {
                                appState.transcriptionEngine.unloadModel()
                            } label: {
                                Image(systemName: "eject.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.orange)
                            }
                            .accessibilityLabel("Descargar de memoria")
                        } else if isLoadingThisModel {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(appState.transcriptionEngine.loadPhase ?? "Cargando…")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .accessibilityLabel("Cargando en memoria")
                        } else {
                            Button {
                                Task {
                                    guard let path = model.fullPath?.path else { return }
                                    do {
                                        try await appState.transcriptionEngine.loadModel(at: path)
                                    } catch {
                                        loadErrorMessage = error.localizedDescription
                                        showLoadError = true
                                    }
                                }
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.green)
                            }
                            .accessibilityLabel("Cargar en memoria")
                            .disabled(appState.transcriptionEngine.isLoadingModel)
                        }
                    }
                    .onReceive(appState.transcriptionEngine.objectWillChange) { _ in
                        // Re-render when the model memory state changes.
                    }
                    .alert("No se pudo cargar el modelo", isPresented: $showLoadError) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(loadErrorMessage ?? "Error desconocido")
                    }
                } else {
                    // Leftover from before the Round 6 filter (e.g. a Qwen
                    // model): WhisperKit can never load this folder, so
                    // offer delete + explanation instead of a broken play.
                    Text("No compatible con WhisperKit")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(6)
                }
            }
            Button { showDelete = true } label: { Image(systemName: "trash").foregroundColor(.red) }
        }
        .padding(.vertical, 4)
        .alert("Eliminar", isPresented: $showDelete) {
            Button("Eliminar", role: .destructive) {
                try? manager.removeModel(model, context: modelContext)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("¿Eliminar \(model.displayName)?") }
    }
    
    @EnvironmentObject private var appState: AppState

    /// True when this model folder is the one currently loaded in memory.
    private var isModelLoaded: Bool {
        appState.transcriptionEngine.isModelLoaded(at: model.fullPath?.path)
    }

    /// True while THIS model folder is the one being loaded (spinner on row).
    private var isLoadingThisModel: Bool {
        guard let path = model.fullPath?.path else { return false }
        return appState.transcriptionEngine.isLoadingModel
            && appState.transcriptionEngine.loadingModelPath == path
    }

    private var statusColor: Color {
        switch model.status {
        case .ready: return .green
        case .downloading: return .blue
        case .verifying: return .orange
        case .failed: return .red
        }
    }
    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromByteCount: b)
    }
}

struct SearchResultRow: View {
    let repo: HFRepoInfo
    let status: ModelSearchStatus
    let onDownload: () -> Void

    var body: some View {
        Button(action: onDownload) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.displayName).font(.headline)
                    HStack(spacing: 8) {
                        if let d = repo.downloads { Label("\(d)", systemImage: "arrow.down.circle").font(.caption) }
                        if let l = repo.likes { Label("\(l)", systemImage: "heart").font(.caption) }
                        if repo.isCoreML { TagLabel(title: "CoreML", value: "✓") }
                    }
                    statusBadge
                }
                Spacer()
                Image(systemName: status.isBlocked ? "xmark.circle" : "arrow.down.circle")
                    .foregroundColor(status.isBlocked ? .red : .blue)
            }
            .padding(.vertical, 4)
            .opacity(status.isBlocked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var statusBadge: some View {
        switch status {
        case .compatible:
            Label("Descargable", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .clipShape(Capsule())
        case .likelyCompatible:
            Label("Compatible (por verificar)", systemImage: "questionmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.gray.opacity(0.16))
                .clipShape(Capsule())
        case .unknown:
            Label("Sin señal CoreML", systemImage: "questionmark.circle")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.gray.opacity(0.12))
                .clipShape(Capsule())
        case .incompatible:
            Label("No compatible", systemImage: "xmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.red.opacity(0.15))
                .clipShape(Capsule())
        case .authRequired:
            Label("Requiere token", systemImage: "lock.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.orange.opacity(0.18))
                .clipShape(Capsule())
        }
    }
}

/// Single-tap install card for the featured turbo model (954 MB quantized
/// since Ronda 11 — the fp16 full-precision variant kept iPhones stuck on
/// "cargando" and overheating).
struct FeaturedModelRow: View {
    let isInstalled: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green.gradient)
            VStack(alignment: .leading, spacing: 5) {
                Text("Whisper Large V3 Turbo")
                    .font(.headline)
                Text("⚡ Rápido · Precisión completa (fp16) · 3,2 GB")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.16))
                    .clipShape(Capsule())
                Text("argmaxinc/whisperkit-coreml")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isInstalled {
                Label("Descargado", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Instalar", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .padding(.vertical, 6)
    }
}

struct VariantSelectorSheet: View {
    let repo: HFRepoInfo
    let manager: ModelManager
    let modelContext: ModelContext
    let onVariantSelected: (String) -> Void
    let onCancel: () -> Void
    
    @State private var variants: [HFModelFile] = []
    @State private var selectedVariant: String?
    @State private var isLoading = true
    @State private var error: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Cargando variantes...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = error {
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(e))
                } else if variants.isEmpty {
                    ContentUnavailableView(
                        "Sin modelos compatibles",
                        systemImage: "brain",
                        description: Text("Este repositorio no contiene un modelo que WhisperKit pueda cargar.\n\nSolo son compatibles los modelos Whisper (se esperan AudioEncoder, TextDecoder y MelSpectrogram). Los modelos Qwen3-ASR, Parakeet y Nemotron usan otra arquitectura y no funcionan en esta app.")
                    )
                } else {
                    List {
                        ForEach(variants) { variant in
                            VariantRow(
                                variant: variant,
                                isSelected: selectedVariant == variant.path,
                                onTap: { selectedVariant = variant.path }
                            )
                        }
                        Section {
                            Text("Precisión completa (fp16) es la variante sin sufijo de tamaño. Las etiquetadas “Cuantizado” (o con sufijo de MB) ocupan menos memoria con una pérdida mínima de precisión. Las marcadas ⚡ Rápido (turbo) transcriben ≈6× más rápido con calidad casi idéntica.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                    
                    // Bottom action bar
                    VStack(spacing: 12) {
                        if let selected = selectedVariant {
                            Text("Seleccionado: \(displayName(for: selected))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Descargar \(displayName(for: selected))") {
                                onVariantSelected(selected)
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Selecciona una variante para continuar")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Descargar") { }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                                .disabled(true)
                        }
                    }
                    .padding()
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Variantes de \(repo.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { onCancel() }
                }
            }
            .task {
                await loadVariants()
            }
        }
    }
    
    private func loadVariants() async {
        do {
            // The service now returns any directory that is (or contains)
            // a CoreML bundle, so `argmaxinc/whisperkit-coreml_*` repos
            // (folders named like `openai_whisper-base`) show up too.
            // For Qwen multi-component models, it returns quant dirs (f32/)
            // or empty (root bundle with all components).
            let files = try await HuggingFaceService.shared.listModelVariants(repoId: repo.modelId)
            await MainActor.run {
                self.variants = files.sorted { $0.variantSortRank < $1.variantSortRank }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    private func displayName(for path: String) -> String {
        variants.first { $0.path == path }?.variantDisplayName ?? path
    }
}

struct VariantRow: View {
    let variant: HFModelFile
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(variant.variantDisplayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    subtitle
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
    }
    
    /// Subtitle with family, model size and quantization badge.
    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 6) {
            if !variant.variantFamily.isEmpty {
                Text(variant.variantFamily)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
            if !variant.variantModelSize.isEmpty {
                Text(variant.variantModelSize)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if variant.isTurboVariant {
                Text("⚡ Rápido")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.18))
                    .clipShape(Capsule())
            }
            if variant.precision == .fullPrecision {
                Text("Precisión completa (fp16)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            } else if variant.precision == .quantized {
                Text("Cuantizado")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18))
                    .clipShape(Capsule())
            }
            if let q = variant.variantSizeSuffix {
                Text(q)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
            }
            if variant.path.isEmpty {
                Text("Bundle en la raíz — se descargan solo los archivos del modelo")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct DownloadSheet: View {
    let repo: HFRepoInfo
    let variant: String
    @ObservedObject var manager: ModelManager
    let modelContext: ModelContext
    @Binding var isPresented: Bool
    @State private var error: String?
    // Download progress bar fix: track real progress (0.0–1.0)
    @State private var downloadProgress: Double = 0
    @State private var downloadPhase: String = "Preparando..."
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Descargando \(repo.displayName)").font(.headline)
            
            // Progress phase label
            Text(downloadPhase)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            if let e = error {
                Text(e)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .font(.caption)
            } else {
                // Deterministic progress bar with percentage
                VStack(spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .tint(.blue)
                        .frame(width: 200)
                    Text(String(format: "%.0f%%", downloadProgress * 100))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text("Puedes cerrar la app: la descarga continúa en segundo plano y el modelo quedará listo.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button("Cerrar (continúa en 2º plano)") { isPresented = false }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            Task {
                do {
                    downloadPhase = "Descargando..."
                    downloadProgress = 0
                    _ = try await manager.downloadModel(
                        repo,
                        variant: variant,
                        context: modelContext,
                        progress: { fraction, phase in
                            downloadProgress = fraction
                            downloadPhase = phase
                        }
                    )
                    isPresented = false
                } catch {
                    self.error = error.localizedDescription
                    downloadPhase = "Error"
                }
            }
        }
    }
}

struct TagLabel: View {
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 2) {
            Text(title + ":").font(.caption2).foregroundColor(.secondary)
            Text(value).font(.caption2)
        }
        .padding(4).background(Color.secondary.opacity(0.1)).cornerRadius(4)
    }
}