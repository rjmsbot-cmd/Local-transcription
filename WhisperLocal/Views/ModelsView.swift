import Foundation
import SwiftUI
import SwiftData

struct ModelsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @State private var manager: ModelManager?
    @State private var searchQuery = ""
    @State private var selectedModel: HFRepoInfo?
    @State private var showDownloadSheet = false
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
                    if !manager!.availableModels.isEmpty {
                        Section("Resultados (\(manager!.availableModels.count))") {
                            ForEach(manager!.availableModels) { repo in
                                SearchResultRow(repo: repo) {
                                    selectedModel = repo
                                    showDownloadSheet = true
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
                        try await appState.transcriptionEngine.loadModel(at: path)
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
        let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromBytes: b)
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

struct DownloadSheet: View {
    let repo: HFRepoInfo
    @ObservedObject var manager: ModelManager
    let modelContext: ModelContext
    @Binding var isPresented: Bool
    @State private var error: String?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Descargando \(repo.displayName)").font(.headline)
            if let e = error { Text(e).foregroundColor(.red).multilineTextAlignment(.center) }
            else { ProgressView().tint(.blue) }
            Button(isPresented ? "Cancelar" : "Cerrar") { isPresented = false }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear { Task { do { _ = try await manager.downloadModel(repo, variant: "openai_whisper-base", context: modelContext); isPresented = false } catch { self.error = error.localizedDescription } } }
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
