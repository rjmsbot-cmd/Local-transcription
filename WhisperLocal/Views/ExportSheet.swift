import SwiftUI

struct ExportSheet: View {
    let transcription: Transcription
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormat: ExportService.ExportFormat = .txt
    @State private var exportedURL: URL?
    @State private var showShare = false
    @State private var exportError: String?
    @State private var showError = false
    
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    
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
                
                // Format Grid
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ExportService.ExportFormat.allCases) { format in
                        FormatTile(format: format, isSelected: selectedFormat == format) {
                            withAnimation(.snappy) { selectedFormat = format }
                        }
                    }
                }
                .padding(.horizontal)
                
                // Description
                Text(selectedFormat.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                
                Spacer()
                
                // Export Button
                Button { exportAndShare() } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export as \(selectedFormat.fileExtension.uppercased())")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
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
        do {
            exportedURL = try ExportService.exportToFile(transcription, format: selectedFormat)
            showShare = true
        } catch {
            exportError = error.localizedDescription
            showError = true
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
