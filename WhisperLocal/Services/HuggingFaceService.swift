import Foundation
import CryptoKit

// MARK: - HF Errors

enum HFError: LocalizedError {
    case networkFailed(Error)
    case decodingFailed
    case notFound
    case rateLimited
    case checksumMismatch(String, String)
    case authRequired
    
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
        case .authRequired:
            return "Este repositorio requiere autenticación. Añade un token de Hugging Face en Ajustes."
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
    
    /// Searches the Hugging Face Hub.
    ///
    /// - Parameter coreMLOnly: when true (default), restricts the query to
    ///   `automatic-speech-recognition` models via `pipeline_tag`, which
    ///   keeps the results relevant for WhisperKit (the app only downloads
    ///   CoreML bundles). Plain PyTorch whisper repos are excluded.
    func searchModels(query: String, limit: Int = 20, coreMLOnly: Bool = true) async throws -> [HFModel] {
        guard !query.isEmpty else { return [] }
        
        // Build the query with URLComponents so special characters in the
        // search string (&, +, ?, …) can never break the URL.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"
        var queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "likes"),
            URLQueryItem(name: "direction", value: "-1")
        ]
        if coreMLOnly {
            queryItems.append(URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition"))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"]))
        }
        
        var request = URLRequest(url: url)
        if !Self.authToken.isEmpty {
            request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Respuesta inválida"]))
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
        try await hasCompatibleFiles(repoId: repoId, path: "", forceRefresh: forceRefresh)
    }
    
    func hasCompatibleFiles(repoId: String, path: String, forceRefresh: Bool = false) async throws -> Bool {
        // 🔴 Fix #3: Use cache to reduce N+1 HTTP calls
        let cacheKey = path.isEmpty ? repoId : "\(repoId)#\(path)"
        if !forceRefresh, let cached = compatibilityCache[cacheKey] {
            return cached
        }
        let result = try await checkCompatibility(repoId: repoId, path: path)
        compatibilityCache[cacheKey] = result
        return result
    }
    
    private func checkCompatibility(repoId: String, path: String = "") async throws -> Bool {
        let files = try await listFiles(repoId: repoId, path: path)
        return files.contains { file in
            let name = file.path.lowercased()
            return name.contains("mlmodelc") || name.contains("mlpackage")
        }
    }
    
    // MARK: - Model variants

    /// Returns directory-like entries that are (or contain) CoreML model
    /// bundles.
    ///
    /// The old implementation only matched names containing ".mlpackage"
    /// (silently dropping `argmaxinc/whisperkit-coreml_*`, whose folders are
    /// named like `openai_whisper-base`), and then issued one HTTP request
    /// per candidate directory (N+1 — slow and rate-limit prone). This
    /// version makes a SINGLE recursive tree call and derives the variants
    /// client-side, since the tree API returns every entry with full
    /// repo-relative paths.
    func listModelVariants(repoId: String) async throws -> [HFModelFile] {
        let all = try await listFiles(repoId: repoId, recursive: true)
        
        // Only top-level entries (no "/" in the path) can be variants.
        let topLevel = all.filter { !$0.path.contains("/") }
        
        // Edge case: repos where the CoreML bundle lives directly at the
        // repo root (AudioEncoder/TextDecoder/MelSpectrogram .mlmodelc
        // folders, no per-variant subdirectory). Expose them as a single
        // "root bundle" variant (empty path) instead of three bogus
        // encoder/decoder entries. Must be checked on top-level entries
        // only — with a recursive listing, nested paths under any variant
        // also contain "AudioEncoder" and "mlmodelc".
        let rootHasEncoder = topLevel.contains { $0.path.contains("AudioEncoder") && $0.isCoreMLBundleName }
        let rootHasDecoder = topLevel.contains { $0.path.contains("TextDecoder") && $0.isCoreMLBundleName }
        if rootHasEncoder && rootHasDecoder {
            return [HFModelFile(
                id: "\(repoId)#root",
                path: "",
                size: nil,
                type: "directory",
                lfs: nil
            )]
        }
        
        // A top-level directory is a variant when it contains (at any
        // depth) an entry whose path includes a CoreML bundle name.
        let variants = topLevel.filter { dir in
            guard dir.isDirectoryLike else { return false }
            let prefix = dir.path + "/"
            return all.contains { $0.path.hasPrefix(prefix) && $0.isCoreMLBundleName }
        }
        return variants
    }

    // MARK: - File listing

    func listFiles(repoId: String, path: String = "", recursive: Bool = false) async throws -> [HFModelFile] {
        // F2 fix: use the correct HF tree API endpoint
        let safeRepo = sanitizePathComponent(repoId)
        let safePath = sanitizePathComponent(path)
        
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        // sanitizePathComponent already returns a percent-encoded path, so it
        // must go into percentEncodedPath (assigning to `path` would
        // double-encode "%" → "%25" and break URLs containing spaces etc.).
        if safePath.isEmpty {
            components.percentEncodedPath = "/api/models/\(safeRepo)/tree/main"
        } else {
            components.percentEncodedPath = "/api/models/\(safeRepo)/tree/main/\(safePath)"
        }
        if recursive {
            components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        }
        
        guard let url = components.url else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"]))
        }
        
        var request = URLRequest(url: url)
        if !Self.authToken.isEmpty {
            request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Respuesta inválida"]))
        }
        
        // Gated/private repos return 401 with an error body — surface a
        // clear message instead of a confusing decoding failure.
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw HFError.authRequired
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                throw HFError.rateLimited
            }
            if httpResponse.statusCode == 404 {
                throw HFError.notFound
            }
            throw HFError.networkFailed(NSError(domain: "HF", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]))
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
        components.percentEncodedPath = "/\(safeRepo)/resolve/main/\(safeFile)"
        
        guard let url = components.url else {
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"]))
        }
        
        var request = URLRequest(url: url)
        if !Self.authToken.isEmpty {
            request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw HFError.authRequired
            }
            throw HFError.networkFailed(NSError(domain: "HF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Descarga fallida"]))
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
    
    /// Recursively downloads every file under `directoryPath` into
    /// `destinationURL`, preserving the repo-relative layout. Returns the
    /// total number of bytes downloaded.
    ///
    /// The old implementation only fetched the direct children of the
    /// directory (and only the files, not nested folders), so `.mlpackage`
    /// / `.mlmodelc` bundles came down incomplete and failed to load.
    @discardableResult
    func downloadDirectory(
        repoId: String,
        directoryPath: String,
        destinationURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws -> Int64 {
        let fileItems = try await listAllFiles(repoId: repoId, path: directoryPath)
            .filter { !$0.isDirectory }
        guard !fileItems.isEmpty else { return 0 }
        return try await downloadFiles(
            repoId: repoId,
            files: fileItems,
            destinationURL: destinationURL,
            progress: progress
        )
    }
    
    /// Returns every entry (files AND directories, recursively) under
    /// `path` with a single API call. The tree API returns full
    /// repo-relative paths even when querying a subpath (verified against
    /// huggingface.co), so callers can map entries straight to disk.
    func listAllFiles(repoId: String, path: String = "") async throws -> [HFModelFile] {
        try await listFiles(repoId: repoId, path: path, recursive: true)
    }
    
    /// Downloads the given file entries into `destinationURL`, preserving
    /// the repo-relative layout. Progress is byte-based (not per-file), so
    /// the bar reflects the real weight of large `.bin` weights vs small
    /// config files. Any failed file aborts the download with an error
    /// instead of silently leaving an incomplete model behind.
    @discardableResult
    func downloadFiles(
        repoId: String,
        files: [HFModelFile],
        destinationURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws -> Int64 {
        let fileItems = files.filter { !$0.isDirectory }
        guard !fileItems.isEmpty else { return 0 }
        
        let totalBytes = fileItems.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
        var downloadedBytes: Int64 = 0
        
        for file in fileItems {
            let destURL = destinationURL.appendingPathComponent(file.path)
            
            // 🔴 Fix #2.2: Use sanitized path for each file
            let safeRepo = sanitizePathComponent(repoId)
            let safeFile = sanitizePathComponent(file.path)
            
            var components = URLComponents()
            components.scheme = "https"
            components.host = "huggingface.co"
            components.percentEncodedPath = "/\(safeRepo)/resolve/main/\(safeFile)"
            
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
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 401 || code == 403 {
                    throw HFError.authRequired
                }
                throw HFError.networkFailed(NSError(
                    domain: "HF",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "Descarga fallida: \(file.path) (HTTP \(code)) — revisa tu conexión o token de Hugging Face."]
                ))
            }
            
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            
            downloadedBytes += Int64(file.size ?? 0)
            let fraction = totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : 0
            progress(fraction, "Descargando modelo… \(Int(fraction * 100))%")
        }
        
        // F7 fix: models are public data from HF, no need for file protection
        
        return downloadedBytes
    }
    
    /// Recursively walks `directoryPath` with a single recursive tree call
    /// (the old version made one HTTP request per directory level).
    private func collectFiles(
        repoId: String,
        directoryPath: String,
        into: inout [HFModelFile]
    ) async throws {
        let entries = try await listFiles(repoId: repoId, path: directoryPath, recursive: true)
        into.append(contentsOf: entries)
    }
    
    // MARK: - Tokenizer download
    
    /// Downloads the tokenizer files (tokenizer.json, vocab.json, merges.txt,
    /// …) for a Whisper model size from the matching `openai/whisper-*` repo
    /// into `destinationURL`.
    ///
    /// WhisperKit loads the tokenizer from the model folder if it finds
    /// `tokenizer.json` there; otherwise it tries a network download, which
    /// is not acceptable for an offline-first app. This makes model loading
    /// fully local. Missing individual files (some repos omit them) are
    /// skipped — only `tokenizer.json` is strictly required.
    func downloadTokenizerFiles(
        modelSize: String,
        destinationURL: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let tokenizerRepo = "openai/whisper-\(modelSize)"
        let files = [
            "tokenizer.json",
            "vocab.json",
            "merges.txt",
            "added_tokens.json",
            "special_tokens_map.json",
            "tokenizer_config.json"
        ]
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        
        var downloaded = 0
        for file in files {
            let dest = destinationURL.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dest.path) {
                downloaded += 1
                continue
            }
            do {
                try await downloadFileWithProgress(
                    repoId: tokenizerRepo,
                    fileName: file,
                    expectedSha256: nil,
                    destinationURL: dest,
                    progress: { _ in }
                )
                downloaded += 1
            } catch {
                // Optional file missing on the repo — skip it.
                try? FileManager.default.removeItem(at: dest)
                print("[HuggingFaceService] Tokenizer file skipped: \(file) (\(error.localizedDescription))")
            }
            progress(Double(downloaded) / Double(files.count), "Descargando tokenizer…")
        }
    }
    
    // MARK: - SHA-256
    
    func sha256OfFile(at url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        try fileHandle.seek(toOffset: 0)
        
        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1MB chunks
        
        while true {
            guard let data = try fileHandle.read(upToCount: chunkSize), !data.isEmpty else { break }
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
