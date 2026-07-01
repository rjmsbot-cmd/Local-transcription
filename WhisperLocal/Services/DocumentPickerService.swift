import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Singleton service that manages document picker state and selected URLs.
/// Observed by TranscribeView via @ObservedObject so UI updates reactively.
@MainActor
final class DocumentPickerService: ObservableObject {
    static let shared = DocumentPickerService()
    
    @Published var selectedURL: URL?
    @Published var isPickerPresented = false
    @Published var lastError: String?
    
    private init() {}
    
    /// Present the document picker from the given window scene.
    func present(from scene: UIScene, completion: @escaping (URL?) -> Void) {
        guard let windowScene = scene as? UIWindowScene else { return }
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: audioContentTypes)
        picker.delegate = DocumentPickerDelegateHandler { url in
            self.selectedURL = url
            self.isPickerPresented = false
            completion(url)
        }
        
        if let rootVC = windowScene.windows.first?.rootViewController {
            let presentingVC = (rootVC.presentedViewController != nil) ? rootVC.presentedViewController! : rootVC
            presentingVC.present(picker, animated: true)
            isPickerPresented = true
        }
    }
    
    func reset() {
        selectedURL = nil
        lastError = nil
        isPickerPresented = false
    }
}

// MARK: - Delegate Handler (closure-based, avoids retain cycles)

private class DocumentPickerDelegateHandler: NSObject, UIDocumentPickerDelegate {
    private let handler: (URL?) -> Void
    
    init(handler: @escaping (URL?) -> Void) {
        self.handler = handler
    }
    
    func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            handler(nil)
            return
        }
        
        // Start secure access to ensure the file remains accessible
        _ = url.startAccessingSecurityScopedResource()
        handler(url)
    }
    
    func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
        handler(nil)
    }
}

// MARK: - Audio Content Types

let audioContentTypes: [UTType] = [
    .mp3, .wav, UTType(filenameExtension: "m4a")!, UTType(filenameExtension: "aac")!, UTType(filenameExtension: "flac")!, .audio
]
