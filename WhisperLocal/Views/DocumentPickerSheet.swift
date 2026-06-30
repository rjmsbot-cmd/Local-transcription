import SwiftUI
import UIKit

/// A sheet wrapper that presents UIDocumentPickerViewController for audio files.
/// Uses DocumentPickerService singleton so state changes propagate to observers.
struct DocumentPickerSheet: UIViewControllerRepresentable {
    var onURLSelected: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: audioContentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self, onURLSelected: onURLSelected)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerSheet
        let onURLSelected: (URL) -> Void
        
        init(_ parent: DocumentPickerSheet, onURLSelected: @escaping (URL) -> Void) {
            self.parent = parent
            self.onURLSelected = onURLSelected
        }
        
        func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // Start secure access for security-scoped resources (Files app, iCloud, etc.)
            if url.startAccessingSecurityScopedResource() {
                // Store in the shared service so observers react
                DocumentPickerService.shared.selectedURL = url
            }
            onURLSelected(url)
        }
        
        func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
            // No-op; the sheet will dismiss
        }
    }
}
