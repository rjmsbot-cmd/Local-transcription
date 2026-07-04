import Foundation
import SwiftUI
import SwiftData

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @State private var manager: ModelManager?
    @State private var searchQuery = ""
    @State private var coremlOnly = true // F5: filter toggle for CoreML-compatible models
    @State private var selectedModel: HFRepoInfo?
    @State private var showDownloadSheet = false
    @State private var showVariantSelector = false
    @State private var diskSpace: String = ""
    
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
        .sheet(isPresented: $showVariantSelector) {
            if let repo = selectedModel {
                VariantSelectorSheet(
                    repo: repo,
                    manager: manager!,
                    modelContext: modelContext,
                    onVariantSelected: { variant in
                        showVariantSelector = false
                        showDownloadSheet = true
                    },
                    onCancel: {
                        showVariantSelector = false
                    }
                )
            }
        }
        .sheet(isPresented: $showDownloadSheet) {
            if let repo = selectedModel {
                DownloadSheet(repo: repo, manager: manager!, modelContext: modelContext, isPresented: $showDownloadSheet)
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
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
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
                ProgressView("Buscando...").frame(height: 100)
            } else if let error = manager!.errorMessage {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(height: 100)
            } else if manager!.availableModels.isEmpty && manager!.downloadedModels.isEmpty {
                ContentUnavailableView("Sin modelos", systemImage: "brain",
                    description: Text("Busca un modelo de Whisper en Hugging Face."))
            } else {
                List {
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
                    let filtered = coremlOnly ? manager!.availableModels.filter({ $0.isCoreML }) : manager!.availableModels
                    if !filtered.isEmpty {
                        Section("Resultados (\(filtered.count))") {
                            ForEach(filtered) { repo in
                                SearchResultRow(repo: repo) {
                                    selectedModel = repo
                                    showVariantSelector = true
                                }
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
        Task { await manager?.searchModels(query: searchQuery) }
    }
    
    private func refresh() {
        manager?.loadLocalModels(context: modelContext)
        manager?.updateDiskSpace()
        diskSpace = manager?.diskSpaceAvailable ?? "..."
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
                                isSelected: selectedVariant == variant.displayName,
                                onTap: { selectedVariant = variant.displayName }
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    
                    // Bottom action bar
                    VStack(spacing: 12) {
                        if let selected = selectedVariant {
                            Text("Seleccionado: \(selected)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Descargar \(selected)") {
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
            .navigationTitle("Cuantización: \(repo.displayName)")
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
            let files = try await HuggingFaceService.shared.listModelVariants(repoId: repo.modelId)
            // Filter to only .mlpackage directories (the actual model variants)
            let mlpackageVariants = files.filter { $0.isDirectory && $0.path.lowercased().contains("mlpackage") }
            await MainActor.run {
                self.variants = mlpackageVariants.isEmpty ? files : mlpackageVariants
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
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
                    Text(variant.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    if let size = variant.size {
                        Text(formatBytes(Int64(size)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
    
    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromByteCount: b)
    }
}

struct DownloadSheet: View {
    // F4 fix: derive variant from repo modelId instead of hardcoded "openai_whisper-base"
    private static func deriveVariant(from repo: HFRepoInfo) -> String {
        // Convert "author/model-name" → "author_model-name" (matches .mlpackage convention)
        repo.modelId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
    }
    
    let repo: HFRepoInfo
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
                    try await manager.downloadModel(
                        repo,
                        variant: Self.deriveVariant(from: repo),
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