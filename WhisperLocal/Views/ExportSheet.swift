import SwiftUI

struct ExportSheet: View {
    let transcription: Transcription
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormat: ExportService.ExportFormat = .txt
    @State private var exportedURL: URL?
    @State private var showShare = false
    @State private var exportError: String?
    @State private var showError = false
    @State private var isExporting = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.blue.gradient)
                    Text("Export Transcription")
                        .font(.title3.weight(.semibold))
                    Text("\"\(transcription.title)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 20)
                
                // Format grid.
                //
                // FIX (cuelgue con .md): the old LazyVGrid + withAnimation(.snappy)
                // combo could hang the sheet's layout pass on iOS 17 when a tile
                // was tapped first (selecting .txt first "warmed up" the state,
                // which is why .md only failed on the first tap). Plain non-lazy
                // Grid + plain state assignment removes both ingredients.
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        FormatTile(format: .txt, isSelected: selectedFormat == .txt) { selectedFormat = .txt }
                        FormatTile(format: .srt, isSelected: selectedFormat == .srt) { selectedFormat = .srt }
                        FormatTile(format: .vtt, isSelected: selectedFormat == .vtt) { selectedFormat = .vtt }
                    }
                    GridRow {
                        FormatTile(format: .json, isSelected: selectedFormat == .json) { selectedFormat = .json }
                        FormatTile(format: .csv, isSelected: selectedFormat == .csv) { selectedFormat = .csv }
                        FormatTile(format: .md, isSelected: selectedFormat == .md) { selectedFormat = .md }
                    }
                }
                .padding(.horizontal)
                
                // Description
                Text(selectedFormat.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity)
                
                Spacer()
                
                // Export Button
                Button {
                    exportAndShare()
                } label: {
                    HStack(spacing: 8) {
                        if isExporting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text(isExporting ? "Generando…" : "Export as \(selectedFormat.fileExtension.uppercased())")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isExporting ? Color.gray : Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isExporting)
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = exportedURL {
                    ShareSheet(items: [url])
                }
            }
            .alert("Export Failed", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "Unknown error")
            }
        }
    }
    
    private func exportAndShare() {
        guard !isExporting else { return }
        isExporting = true
        // Snapshot the SwiftData model on the main thread (models aren't
        // Sendable), then build the file off-main so very large transcripts
        // can't jank the sheet while the share sheet is presented.
        let snapshot = ExportService.ExportSnapshot(transcription: transcription, format: selectedFormat)
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ExportService.exportToFile(snapshot)
                }.value
                exportedURL = url
                isExporting = false
                showShare = true
            } catch {
                isExporting = false
                exportError = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - Format Tile

struct FormatTile: View {
    let format: ExportService.ExportFormat
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: format.icon)
                    .font(.title2)
                Text(".\(format.fileExtension)")
                    .font(.caption2.weight(.bold).monospaced())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
