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

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @State private var manager: ModelManager?
    @State private var searchQuery = ""
    @State private var coremlOnly = true // F5: filter toggle for CoreML-compatible models
    @State private var activeSheet: ModelSheet?
    @State private var diskSpace: String = ""
    @State private var searchTask: Task<Void, Never>?
    
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
    }
    
    private var contentView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Buscar modelos...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { performSearch() }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchTask?.cancel()
                        manager?.resetSearch()
                        Task { await manager?.loadRecommendations() }
                    } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
            
            // F5: CoreML compatibility filter toggle
            HStack {
                Toggle(isOn: $coremlOnly) {
                    Text("Solo CoreML")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .toggleStyle(.switch)
                Spacer()
                if !coremlOnly {
                    Text("Mostrando todos los modelos")
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
                ProgressView(manager!.hasSearched ? "Buscando…" : "Cargando recomendados…")
                    .frame(height: 100)
            } else if let error = manager!.errorMessage {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(height: 100)
            } else {
                List {
                    if !manager!.downloadedModels.isEmpty {
                        Section("Descargados (\(manager!.downloadedModels.count))") {
                            ForEach(manager!.downloadedModels) { model in
                                ModelRow(model: model, manager: manager!)
                            }
                            .onDelete { indices in
                                for index in indices {
                                    try? manager!.removeModel(manager!.downloadedModels[index], context: modelContext)
                                }
                            }
                        }
                    }
                    if manager!.hasSearched {
                        let filtered = coremlOnly ? manager!.availableModels.filter({ $0.isCoreML }) : manager!.availableModels
                        if !filtered.isEmpty {
                            Section("Resultados (\(filtered.count))") {
                                ForEach(filtered) { repo in
                                    SearchResultRow(repo: repo) {
                                        activeSheet = .variantPicker(repo)
                                    }
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
                    } else if !manager!.recommendedModels.isEmpty {
                        Section("Recomendados (\(manager!.recommendedModels.count))") {
                            ForEach(manager!.recommendedModels) { repo in
                                SearchResultRow(repo: repo) {
                                    activeSheet = .variantPicker(repo)
                                }
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
            if model.status == .ready {
                Button {
                    Task {
                        guard let path = model.fullPath else { return }
                        try await appState.transcriptionEngine.loadModel(at: path.path)
                    }
                } label: { Image(systemName: "play.fill").foregroundColor(.green) }
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
                }
                Spacer()
                Image(systemName: "arrow.down.circle").foregroundColor(.blue)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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
                        "Sin variantes CoreML",
                        systemImage: "brain",
                        description: Text("Este repositorio no tiene modelos .mlpackage/.mlmodelc compatibles con iOS.")
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
                            Text("Los sufijos de tamaño (p. ej. 547 MB) son variantes cuantizadas: ocupan menos memoria con una pérdida mínima de precisión.")
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
            if let q = variant.variantSizeSuffix {
                Text(q)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
            }
            // Qwen multi-component indicator
            if variant.isQwenMultiComponent == true {
                Text("Multi-componente")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
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
            }
            
            Button(isPresented ? "Cancelar" : "Cerrar") { isPresented = false }
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