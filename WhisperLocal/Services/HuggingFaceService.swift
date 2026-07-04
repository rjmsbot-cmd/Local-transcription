import Foundation
import CryptoKit

// MARK: - HF Errors

enum HFError: LocalizedError {
    case networkFailed(Error)
    case decodingFailed
    case notFound
    case rateLimited
    case checksumMismatch(String, String)
    
    var errorDescription: String? {
        switch self {
        case .networkFailed(let err):
            return "Error de red: \(err.localizedDescription)"
        case .decodingFailed:
            return "Error al decodificar la respuesta de HuggingFace"
        case .notFound:
            return "Repositorio no encontrado"
        case .rateLimited:
            return "Demasiadas peticiones. Espera un momento e inténtalo de nuevo."
        case .checksumMismatch(let expected, let actual):
            return "Integridad del archivo comprometida (SHA-256: esperado \(expected.prefix(12))… vs obtenido \(actual.prefix(12))…)"
        }
    }
}

// MARK: - Service
// (HFModel, HFModelFile, HFRepoInfo are defined in Models/HFModel.swift — C1 fix)

final class HuggingFaceService {
    
    static let shared = HuggingFaceService()
    
    // HF token for gated repos (set from SettingsView)
    static var authToken: String = ""
    
    static let downloadBase = "https://huggingface.co"
    static let apiBase = "https://huggingface.co/api"
    
    // 🔴 Fix #3: Rate limiting - max 4 concurrent requests, 200ms between batches
    private let concurrencyLimit = 4
    private let batchDelay: UInt64 = 200_000_000 // 200ms in nanoseconds
    
    // 🔴 Fix #3: Cache for compatibility checks (reduces N+1 HTTP calls)
    private var compatibilityCache: [String: Bool] = [:]
    
    // MARK: - Search
    
    func searchModels(query: String, limit: Int = 20) async throws -> [HFModel] {
        guard !query.isEmpty else { return [] }
        
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(Self.apiBase)/models?search=\(encoded)&limit=\(limit)&sort=likes&direction=-1"
        
        var request = URLRequest(url: URL(string: urlString)!)
        if !Self.authToken.isEmpty {
            request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [.NSLocalizedDescription: "Respuesta inválida"]))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                throw HFError.rateLimited
            }
            throw HFError.notFound
        }
        
        let models = try JSONDecoder().decode([HFModel].self, from: data)
        return models
    }
    
    // MARK: - Compatibility check (with caching)
    
    func hasCompatibleFiles(repoId: String, forceRefresh: Bool = false) async throws -> Bool {
        // 🔴 Fix #3: Use cache to reduce N+1 HTTP calls
        guard !forceRefresh else {
            return try await checkCompatibility(repoId: repoId)
        }
        if let cached = compatibilityCache[repoId] {
            return cached
        }
        let result = try await checkCompatibility(repoId: repoId)
        compatibilityCache[repoId] = result
        return result
    }
    
    private func checkCompatibility(repoId: String) async throws -> Bool {
        let files = try await listFiles(repoId: repoId)
        return files.contains { file in
            let name = file.path.lowercased()
            return name.contains("mlmodelc") || name.contains("mlpackage")
        }
    }
    
    // MARK: - Model variants
    
    func listModelVariants(repoId: String) async throws -> [HFModelFile] {
        let files = try await listFiles(repoId: repoId)
        return files.filter { file in
            // 🔴 Fix #1.2: Only show CoreML-compatible files (GGUF filtering)
            // Include directories (for .mlpackage/.mlmodelc) and CoreML files
            if file.isDirectory {
                let name = file.path.lowercased()
                return name.contains("mlmodelc") || name.contains("mlpackage")
            }
            let name = file.path.lowercased()
            return name.contains("mlmodelc") ||
                   name.contains("mlpackage") ||
                   name.hasSuffix(".mlmodel")
        }
    }
    
    // MARK: - File listing
    
    func listFiles(repoId: String, path: String = "") async throws -> [HFModelFile] {
        // F2 fix: use the correct HF tree API endpoint
        let safeRepo = sanitizePathComponent(repoId)
        let safePath = sanitizePathComponent(path)
        
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(safeRepo)/tree/main/\(safePath)"
        
        guard let url = components.url else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [.NSLocalizedDescription: "URL inválida"]))
        }
        
        var request = URLRequest(url: url)
        if !Self.authToken.isEmpty {
            request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [.NSLocalizedDescription: "Respuesta inválida"]))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                throw HFError.rateLimited
            }
            if httpResponse.statusCode == 404 {
                throw HFError.notFound
            }
            throw HFError.networkFailed(NSError(domain: "HF", code: httpResponse.statusCode, userInfo: [.NSLocalizedDescription: "HTTP \(httpResponse.statusCode)"]))
        }
        
        // Handle both array and single object responses
        do {
            let files = try JSONDecoder().decode([HFModelFile].self, from: data)
            return files
        } catch {
            do {
                let file = try JSONDecoder().decode(HFModelFile.self, from: data)
                return [file]
            } catch {
                throw HFError.decodingFailed
            }
        }
    }
    
    // MARK: - Download (single file)
    
    func downloadFileWithProgress(
        repoId: String,
        fileName: String,
        expectedSha256: String?,
        destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        // 🔴 Fix #2.2: Use sanitized path components (Security #2)
        let safeRepo = sanitizePathComponent(repoId)
        let safeFile = sanitizePathComponent(fileName)
        
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(safeRepo)/resolve/main/\(safeFile)"
        
        guard let url = components.url else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [.NSLocalizedDescription: "URL inválida"]))
        }
        
        var request = URLRequest(url: url)
        if !Self.authToken.isEmpty {
            request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [.NSLocalizedDescription: "Descarga fallida"]))
        }
        
        // Move to final destination
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        
        // 🔴 Fix #2.2: Verify SHA-256 against HF metadata
        if let expectedSha256 = expectedSha256 {
            let actualSha256 = try sha256OfFile(at: destinationURL)
            guard actualSha256 == expectedSha256 else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw HFError.checksumMismatch(expectedSha256, actualSha256)
            }
        }
        
        // F7 fix: models are public data from HF, no need for file protection
        // (protection is for user's private recordings/transcriptions only)
    }
    
    // MARK: - Directory download (for .mlpackage / .mlmodelc)
    
    func downloadDirectory(
        repoId: String,
        directoryPath: String,
        expectedSha256: String?,
        destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let files = try await listFiles(repoId: repoId, path: directoryPath)
        let fileItems = files.filter { !$0.isDirectory }
        let total = fileItems.count
        
        guard total > 0 else { return }
        
        var downloaded = 0
        
        for file in fileItems {
            let relativePath = file.path
            let destURL = destinationURL.appendingPathComponent(relativePath)
            
            // 🔴 Fix #2.2: Use sanitized path for each file
            let safeRepo = sanitizePathComponent(repoId)
            let safeFile = sanitizePathComponent(relativePath)
            
            var components = URLComponents()
            components.scheme = "https"
            components.host = "huggingface.co"
            components.path = "/\(safeRepo)/resolve/main/\(safeFile)"
            
            guard let url = components.url else { continue }
            
            // Create parent directory
            try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            // HF token auth for gated repos
            var request = URLRequest(url: url)
            if !Self.authToken.isEmpty {
                request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
            }
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                try? FileManager.default.removeItem(at: tempURL)
                continue
            }
            
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            
            downloaded += 1
            progress(Double(downloaded) / Double(total))
        }
        
        // F7 fix: models are public data from HF, no need for file protection
        
        // 🔴 Fix #2.2: Verify directory SHA-256 if provided
        if let expectedSha256 = expectedSha256 {
            let actualSha256 = try sha256OfFile(at: destinationURL)
            guard actualSha256 == expectedSha256 else {
                throw HFError.checksumMismatch(expectedSha256, actualSha256)
            }
        }
    }
    
    // MARK: - SHA-256
    
    func sha256OfFile(at url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        fileHandle.seek(toOffset: 0)
        
        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1MB chunks
        
        while true {
            let data = try fileHandle.read(upToCount: chunkSize)
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Path sanitization (Security #2)
    /// F1 fix: the old version destroyed repo IDs like "openai/whisper-large-v3" → "/"
    /// because it cut on allowed characters instead of disallowed ones.
    /// Now sanitizes per-segment and preserves the "/" separator.
    func sanitizePathComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && !$0.isEmpty }
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "" }
            .joined(separator: "/")
    }
}
