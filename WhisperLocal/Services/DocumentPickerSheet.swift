import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentPickerSheet: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [
                UTType.item,
                UTType.text,
                UTType.plainText,
                UTType.rtf
            ],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void
        
        // 🔴 Fix #2.4: Track security-scoped resource access
        private var accessedURL: URL?
        
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        
        func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
            // 🔴 Fix #2.4: Properly manage security-scoped resource lifecycle
            if url.startAccessingSecurityScopedResource() {
                accessedURL = url
                defer {
                    url.stopAccessingSecurityScopedResource()
                }
                onPick(url)
            }
        }
        
        func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
