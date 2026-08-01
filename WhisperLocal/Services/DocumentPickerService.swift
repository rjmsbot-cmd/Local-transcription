import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class DocumentPickerService: ObservableObject {
    
    static let shared = DocumentPickerService()
    
    // UIDocumentPickerViewController.delegate is weak: keep a strong ref
    // so the delegate isn't deallocated before the picker finishes.
    private var activeDelegate: DocumentPickerDelegate?
    
    func present(source: UIView, forAudio: Bool = false) async throws -> URL {
        let contentTypes: [UTType] = forAudio
            ? [
                UTType(filenameExtension: "caf") ?? .audio,
                UTType(filenameExtension: "m4a") ?? .audio,
                .mp3, .wav, .aiff, .aifc, .audio
            ]
            : [
                UTType.item,
                UTType.text,
                UTType.plainText,
                UTType.rtf
            ]
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        
        // C8 fix: use withCheckedThrowingContinuation because the function throws
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DocumentPickerDelegate { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "DocumentPicker",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Selección cancelada"]
                    ))
                }
            }
            picker.delegate = delegate
            activeDelegate = delegate
            source.window?.rootViewController?.present(picker, animated: true)
        }
    }
}

class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let handler: (URL?, Error?) -> Void
    
    init(handler: @escaping (URL?, Error?) -> Void) {
        self.handler = handler
    }
    
    func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        if url.startAccessingSecurityScopedResource() {
            // Fix: Release security-scoped resource after handler completes
            // but only after the caller has had a chance to copy the file.
            // We don't stop here to avoid premature release before the file is copied.
            handler(url, nil)
        } else {
            handler(nil, NSError(
                domain: "DocumentPicker",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo acceder al recurso"]
            ))
        }
    }
    
    func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
        handler(nil, nil)
    }
}
