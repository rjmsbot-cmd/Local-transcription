// Disk space utilities for download validation

import Foundation

enum DiskSpaceError: LocalizedError {
    case insufficientSpace(required: ByteCount, available: ByteCount)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let required, let available):
            return String(localized: "Espacio insuficiente. Se necesitan \(formatBytes(required)) pero solo hay \(formatBytes(available)) disponibles.")
        case .unknown:
            return String(localized: "No se pudo verificar el espacio en disco.")
        }
    }
    
    private func formatBytes(_ bytes: ByteCount) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromBytes: bytes.int64)
    }
}

enum DiskSpace {
    static func availableBytes() throws -> Int64 {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw DiskSpaceError.unknown
        }
        let attrs = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return attrs.volumeAvailableCapacityForImportantUsage ?? 0
    }
    
    static func ensureSpace(for requiredBytes: Int64, safetyMargin: Double = 0.15) throws -> Int64 {
        let available = try availableBytes()
        let needed = Int64(Double(requiredBytes) * (1 + safetyMargin))
        guard available >= needed else {
            throw DiskSpaceError.insufficientSpace(required: requiredBytes, available: available)
        }
        return available
    }
    
    static func availableFormatted() -> String {
        do {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromBytes: try availableBytes())
        } catch {
            return "Desconocido"
        }
    }
}
