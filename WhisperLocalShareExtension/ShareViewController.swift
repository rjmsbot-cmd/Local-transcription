import UIKit
import UniformTypeIdentifiers

/// Share Extension: receives audio files shared from the iPhone's own
/// Voice Memos app (Compartir → Whisper Local) or from Files, and saves
/// them into the containing app's Documents/Inbox directory. The main app
/// picks them up in the "Notas de voz recibidas" section of the Record tab.
final class ShareViewController: UIViewController {

    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    private let lock = NSLock()
    private var savedCount = 0
    private var failedCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        processIncomingItems()
    }

    // MARK: - UI

    private func setupUI() {
        let icon = UIImageView(image: UIImage(systemName: "waveform.circle.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = "Whisper Local"
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textAlignment = .center

        statusLabel.text = "Guardando audio…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, spinner, statusLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let cancelButton = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.leftBarButtonItem = cancelButton

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
        spinner.startAnimating()
    }

    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Processing

    private func processIncomingItems() {
        guard let extensionContext = extensionContext else {
            finish(message: "No se pudo guardar el audio.")
            return
        }
        let items = extensionContext.inputItems as? [NSExtensionItem] ?? []
        var providers: [NSItemProvider] = []
        for item in items {
            providers.append(contentsOf: item.attachments ?? [])
        }
        guard !providers.isEmpty else {
            finish(message: "No se encontró ningún audio.")
            return
        }

        let group = DispatchGroup()
        var handled = false

        for provider in providers where isSupported(provider) {
            handled = true
            group.enter()
            loadAudioURL(from: provider) { [weak self] url in
                defer { group.leave() }
                guard let self else { return }
                if let url, self.saveToInbox(url) {
                    self.lock.lock(); self.savedCount += 1; self.lock.unlock()
                } else {
                    self.lock.lock(); self.failedCount += 1; self.lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimating()
            if self.savedCount > 0 && self.failedCount == 0 {
                let suffix = self.savedCount == 1 ? "Nota guardada." : "\(self.savedCount) notas guardadas."
                self.finish(message: "✓ \(suffix)\nAbre Whisper Local para transcribirla(s).", delay: 1.4)
            } else if self.savedCount > 0 {
                self.finish(message: "Guardadas \(self.savedCount), \(self.failedCount) con error.", delay: 1.4)
            } else if handled {
                self.finish(message: "No se pudo guardar el audio.", delay: 1.4)
            } else {
                self.finish(message: "No se encontró ningún audio compatible.", delay: 1.4)
            }
        }
    }

    private func isSupported(_ provider: NSItemProvider) -> Bool {
        let audio = UTType.audio.identifier
        let mpeg4 = UTType.mpeg4Audio.identifier
        let coreAudio = "com.apple.coreaudio-format" // .caf (Voice Memos)
        return provider.hasItemConformingToTypeIdentifier(audio)
            || provider.hasItemConformingToTypeIdentifier(mpeg4)
            || provider.hasItemConformingToTypeIdentifier(coreAudio)
            || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    private func loadAudioURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            // Voice Memos shares a file URL (public.file-url).
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    completion(url)
                } else if let data = item as? Data {
                    completion(self.writeTemporaryData(data))
                } else {
                    completion(nil)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { item, _ in
                if let data = item as? Data {
                    completion(self.writeTemporaryData(data))
                } else if let url = item as? URL {
                    completion(url)
                } else {
                    completion(nil)
                }
            }
        } else {
            completion(nil)
        }
    }

    /// Some providers deliver raw Data instead of a URL; materialize it in
    /// the extension's temp dir so the Inbox copy below works uniformly.
    private func writeTemporaryData(_ data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared_\(UUID().uuidString).m4a")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Saving

    /// Writes the received audio into the containing app's Documents/Inbox.
    /// Extensions resolve `.documentDirectory` to the containing app's
    /// Documents directory, and Inbox is the designated place for files
    /// coming from outside — the main app reads it via InboxStore.
    private func saveToInbox(_ sourceURL: URL) -> Bool {
        let ext = sourceURL.pathExtension.lowercased()
        guard !ext.isEmpty, Self.audioExtensions.contains(ext) else {
            return false
        }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        do {
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
            let name = "NotaVoz_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
            let destination = inbox.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: sourceURL, to: destination)
            return true
        } catch {
            print("[ShareExtension] saveToInbox error: \(error.localizedDescription)")
            return false
        }
    }

    private static let audioExtensions: Set<String> = [
        "m4a", "caf", "mp3", "wav", "aiff", "aif", "aac",
        "flac", "ogg", "opus", "mp4", "m4b"
    ]

    // MARK: - Finish

    private func finish(message: String, delay: TimeInterval = 0) {
        statusLabel.text = message
        spinner.stopAnimating()
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
