import Foundation

/// Files delivered by the Share Extension (Notas de Voz → Compartir →
/// Whisper Local) land in the app's Documents/Inbox directory. This store
/// lists and removes them so the Record tab can offer them for transcription.
enum InboxStore {

    /// Audio extensions accepted from the share extension / picker.
    static let audioExtensions: Set<String> = [
        "m4a", "caf", "mp3", "wav", "aiff", "aif", "aac",
        "flac", "ogg", "opus", "mp4", "m4b"
    ]

    /// Documents/Inbox — the system drops "Open In" files here and the
    /// Share Extension writes received audio here too.
    static var inboxDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Audio files in the Inbox, newest first.
    static func incomingAudioFiles() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: inboxDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { ($0.fileModificationDate ?? .distantPast) > ($1.fileModificationDate ?? .distantPast) }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension URL {
    var fileModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    var fileSizeBytes: Int64? {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}
