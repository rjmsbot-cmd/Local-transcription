import Foundation

enum DiskSpaceError: LocalizedError {
    case insufficientSpace(required: Int64, available: Int64)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let required, let available):
            return String(localized: "Espacio insuficiente. Se necesitan \(formatBytes(required)) pero solo hay \(formatBytes(available)) disponibles.")
        case .unknown:
            return String(localized: "No se pudo verificar el espacio en disco.")
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct DiskSpace {
    static let requiredForModelDownload: Int64 = 500 * 1024 * 1024 // 500 MB
    
    static func available() -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSpace = attrs[.systemFreeSize] as? Int64 {
                return freeSpace
            }
        } catch {
            // Fallback
        }
        return Int64.max
    }
    
    static func availableFormatted() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: available())
    }
    
    static func validate(required: Int64 = requiredForModelDownload) throws {
        let avail = available()
        if avail < required {
            throw DiskSpaceError.insufficientSpace(required: required, available: avail)
        }
    }
    
    /// Convenience: check and throw if insufficient disk space (C5 fix)
    static func ensureSpace(for required: Int64 = requiredForModelDownload) throws {
        try validate(required: required)
    }
}
