import Foundation
import UIKit
import UniformTypeIdentifiers

final class DocumentPickerService {
    
    func present(source: UIView) async throws -> URL {
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
        
        // C8 fix: use withCheckedThrowingContinuation because the function throws
        return try await withCheckedThrowingContinuation { continuation in
            picker.delegate = DocumentPickerDelegate { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "DocumentPicker",
                        code: -1,
                        userInfo: [.NSLocalizedDescription: "Selección cancelada"]
                    ))
                }
            }
            source.window?.rootViewController?.present(picker, animated: true)
        }
    }
}

class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let handler: (URL?, Error?) -> Void
    
    // 🔴 Fix #2.4: Track security-scoped resource access
    private var accessedURL: URL?
    
    init(handler: @escaping (URL?, Error?) -> Void) {
        self.handler = handler
    }
    
    func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        if url.startAccessingSecurityScopedResource() {
            // 🔴 Fix #2.4: Release security-scoped resource after handler completes
            accessedURL = url
            handler(url, nil)
            // Note: The caller (TranscribeView/RecordView) handles stopAccessing
            // via defer in their own scope. We don't stop here to avoid
            // premature release before the file is copied.
        } else {
            handler(nil, NSError(
                domain: "DocumentPicker",
                code: -1,
                userInfo: [.NSLocalizedDescription: "No se pudo acceder al recurso"]
            ))
        }
    }
    
    func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
        handler(nil, nil)
    }
}
