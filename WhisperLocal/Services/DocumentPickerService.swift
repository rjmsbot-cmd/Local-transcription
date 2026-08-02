import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class DocumentPickerService: ObservableObject {

    static let shared = DocumentPickerService()

    // UIDocumentPickerViewController.delegate is weak: keep a strong ref
    // so the delegate isn't deallocated before the picker finishes.
    private var activeDelegate: DocumentPickerDelegate?

    /// Presents the system document picker and returns the picked file.
    ///
    /// The picker is created with `asCopy: true`, so the returned URL is a
    /// **copy inside this app's sandbox** — no security-scoped access is
    /// needed (or possible) on it.
    ///
    /// - Parameter forAudio: audio content types (m4a/caf/mp3/wav/…) instead
    ///   of text types.
    /// - Throws: an NSError with code -1 when the user cancels, or a real
    ///   error if the picker cannot be presented.
    func present(forAudio: Bool = false) async throws -> URL {
        let contentTypes: [UTType] = forAudio
            ? [
                UTType(filenameExtension: "caf") ?? .audio,   // Voice Memos (.caf)
                UTType(filenameExtension: "m4a") ?? .audio,   // Voice Memos (.m4a)
                .mp3, .wav, .aiff, .mpeg4Audio, .audio
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

            guard let presenter = Self.topViewController() else {
                continuation.resume(throwing: NSError(
                    domain: "DocumentPicker",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No se pudo presentar el selector de archivos"]
                ))
                return
            }
            presenter.present(picker, animated: true)
        }
    }

    /// Top-most presented view controller across all scenes, so the picker
    /// always presents even when another sheet is already on screen.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first
        else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let handler: (URL?, Error?) -> Void

    init(handler: @escaping (URL?, Error?) -> Void) {
        self.handler = handler
    }

    func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            handler(nil, NSError(
                domain: "DocumentPicker",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No se seleccionó ningún archivo"]
            ))
            return
        }
        // The picker was created with asCopy: true, so `url` is already a
        // copy inside this app's sandbox. Calling
        // startAccessingSecurityScopedResource() on it returns false (it is
        // not a security-scoped URL) — gating on that used to make the file
        // button always fail with "No se pudo acceder al recurso" right
        // after picking a file. Just hand the copy over.
        handler(url, nil)
    }

    func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
        handler(nil, nil)
    }
}
