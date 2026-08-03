import Foundation
import CryptoKit

// MARK: - HF Errors

enum HFError: LocalizedError {
    case networkFailed(Error)
    case decodingFailed(String)
    case notFound
    case rateLimited
    case checksumMismatch(String, String)
    case authRequired
    case incompatibleModel
    
    var errorDescription: String? {
        switch self {
        case .networkFailed(let err):
            return "Error de red: \(err.localizedDescription)"
        case .decodingFailed(let detail):
            return "Error al decodificar la respuesta de HuggingFace\(detail.isEmpty ? "" : ": \(detail)")"
        case .notFound:
            return "Repositorio no encontrado"
        case .rateLimited:
            return "Demasiadas peticiones. Espera un momento e inténtalo de nuevo."
        case .checksumMismatch(let expected, let actual):
            return "Integridad del archivo comprometida (SHA-256: esperado \(expected.prefix(12))… vs obtenido \(actual.prefix(12))…)"
        case .authRequired:
            return "Este repositorio requiere autenticación. Añade un token de Hugging Face en Ajustes."
        case .incompatibleModel:
            return "Este modelo usa una arquitectura que WhisperKit no puede cargar (Qwen3-ASR, Parakeet, Nemotron…). Descarga un modelo Whisper (AudioEncoder/TextDecoder/MelSpectrogram)."
        }
    }
    
    /// Turns a DecodingError into a human-readable description that names
    /// the exact field and JSON path, so a future decode failure is
    /// diagnosable from the on-screen message alone.
    static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            return "falta el campo '\(key.stringValue)' en '\(path(ctx))'"
        case .typeMismatch(let type, let ctx):
            return "tipo inesperado '\(type)' en '\(path(ctx))'"
        case .valueNotFound(let type, let ctx):
            return "valor nulo para '\(type)' en '\(path(ctx))'"
        case .dataCorrupted(let ctx):
            return "datos corruptos: \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
    
    /// Decodes with a diagnostic wrapper so every HF decode failure reports
    /// the offending field instead of a generic message.
    static func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw HFError.decodingFailed("\(context): \(describe(error))")
        } catch {
            throw HFError.decodingFailed("\(context): \(error.localizedDescription)")
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
    
    // Exact artifact names WhisperKit 0.9.4's loadModels() requires
    // (WhisperKit.swift:332-354): if any is missing it throws
    // WhisperError.modelsUnavailable. TextDecoderContextPrefill is optional.
    static let whisperKitComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    // Known non-Whisper CoreML architectures (Qwen3-ASR/FluidAudio, NVIDIA
    // Parakeet, Nemotron, SpeakerKit, ...). WhisperKit 0.9.4 only loads the
    // Whisper family, so repos matching these keywords are excluded even
    // when their filenames look compatible (e.g. parakeetkit-pro ships
    // AudioEncoder/TextDecoder/MelSpectrogram but would crash at inference).
    static let incompatibleArchitectureKeywords = [
        "parakeet", "nemotron", "qwen", "speaker", "diar",
        "cohere", "omni", "breeze", "sortformer", "canary"
    ]
    
    // MARK: - Search
    
    /// Searches the Hugging Face Hub.
    ///
    /// - Parameter coreMLOnly: when true (default), restricts the query to
    ///   `automatic-speech-recognition` models via `pipeline_tag`, which
    ///   keeps the results relevant for WhisperKit (the app only downloads
    ///   CoreML bundles). Plain PyTorch whisper repos are excluded.
    /// - Parameter sort: optional server-side sort field ("downloads", "likes", "trendingScore", "modified").
    /// - Parameter direction: "-1" for descending (default), "1" for ascending.
    func searchModels(query: String, limit: Int = 20, coreMLOnly: Bool = true, sort: String = "downloads", direction: String = "-1") async throws -> [HFModel] {
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
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "direction", value: direction)
        ]
        if coreMLOnly {
            queryItems.append(URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition"))
            queryItems.append(URLQueryItem(name: "filter", value: "coreml"))
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
        
        let models = try HFError.decodeOrThrow([HFModel].self, from: data, context: "búsqueda")
        return models
    }
    
    /// Fetches a curated list of recommended repos: the most-downloaded
    /// CoreML-tagged automatic-speech-recognition models on the Hub.
    /// Used as the initial content of the Models tab ("Recomendados")
    /// so the screen is never empty before the user searches.
    func fetchRecommendedModels(limit: Int = 20) async throws -> [HFModel] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition"),
            URLQueryItem(name: "filter", value: "coreml")
        ]
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
            if httpResponse.statusCode == 429 { throw HFError.rateLimited }
            throw HFError.notFound
        }
        return try HFError.decodeOrThrow([HFModel].self, from: data, context: "recomendados")
    }
    
    // MARK: - Search result classification (signal per repo)

    /// Cache of the last classification per repo id, with TTL, so repeated
    /// searches never re-probe the same repos.
    private var searchStatusCache: [String: (status: ModelSearchStatus, date: Date)] = [:]
    private let searchStatusCacheTTL: TimeInterval = 600 // 10 minutes

    /// True when a top-level entry uses the canonical WhisperKit folder
    /// naming (`openai_whisper-base`, `distil-whisper_distil-large-v3`…).
    /// This is the strongest cheap signal that a repo has installable
    /// WhisperKit variants.
    static func isWhisperNamedDir(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("openai_whisper")
            || lower.hasPrefix("distil_whisper")
            || lower.hasPrefix("distil-whisper")
            || lower.contains("whisperkit")
    }

    /// Classifies a batch of search results with a cheap top-level tree
    /// probe per repo (bounded concurrency + cache), then sorts them by
    /// usability: installable first, known-bad last. Each probe is one
    /// lightweight non-recursive tree call, so a 20-hit search costs at
    /// most 20 small requests instead of one full recursive listing per
    /// repo.
    func classifySearchResults(_ models: [HFModel]) async -> [ModelSearchResult] {
        guard !models.isEmpty else { return [] }
        var results = models.map { ModelSearchResult(model: $0, status: .unknown) }

        let semaphore = DispatchSemaphore(value: concurrencyLimit)
        await withTaskGroup(of: (Int, ModelSearchStatus).self) { group in
            for (index, model) in models.enumerated() {
                group.addTask {
                    semaphore.wait()
                    defer { semaphore.signal() }
                    let status = await self.classifyModel(model)
                    return (index, status)
                }
            }
            for await (index, status) in group {
                results[index].status = status
            }
        }

        // Installable first; within the same status, most-downloaded first.
        return results.sorted {
            let a = ModelSearchStatus.rank($0.status)
            let b = ModelSearchStatus.rank($1.status)
            if a != b { return a < b }
            return ($0.model.downloads ?? 0) > ($1.model.downloads ?? 0)
        }
    }

    /// Classifies one repo using: (1) known non-Whisper architecture
    /// keywords — free, no network; (2) a top-level tree probe — one cheap
    /// call; (3) CoreML tag / ASR pipeline heuristics when the probe is
    /// inconclusive. 401/403 from the probe marks the repo as gated.
    private func classifyModel(_ model: HFModel) async -> ModelSearchStatus {
        let repoId = model.modelId
        if let cached = searchStatusCache[repoId],
           Date().timeIntervalSince(cached.date) < searchStatusCacheTTL {
            return cached.status
        }

        // (1) Known non-Whisper architectures — reject without any request.
        let lowerRepo = repoId.lowercased()
        if Self.incompatibleArchitectureKeywords.contains(where: { lowerRepo.contains($0) }) {
            cache(repoId, .incompatible)
            return .incompatible
        }

        // (2) Top-level probe.
        do {
            let top = try await listFiles(repoId: repoId, recursive: false)
            let hasWhisperNaming = top.contains { Self.isWhisperNamedDir($0.path) }
            let isRootBundle = Self.whisperKitComponents.allSatisfy { component in
                top.contains { $0.path.contains(component) && $0.isCoreMLBundleName }
            }
            if hasWhisperNaming || isRootBundle {
                cache(repoId, .compatible)
                return .compatible
            }
        } catch HFError.authRequired {
            cache(repoId, .authRequired)
            return .authRequired
        } catch {
            // Network/decoding failure: the probe is inconclusive, fall
            // through to the tag heuristics so the repo is still listed
            // (the variant picker will retry the real check on tap).
        }

        // (2b) Whisper repos that ship raw weights only (safetensors/ONNX)
        // — OpenAI's official whisper repos are the common case. WhisperKit
        // needs CoreML bundles (.mlmodelc), so these are dead ends: mark
        // them blocked so the tap explains instead of opening an empty
        // variant picker (Ronda 12). Real CoreML bundles always live in a
        // repo whose name advertises it (whisperkit / coreml / mlmodel…).
        if lowerRepo.contains("whisper")
            && !lowerRepo.contains("coreml")
            && !lowerRepo.contains("core-ml")
            && !lowerRepo.contains("whisperkit")
            && !lowerRepo.contains("mlmodel") {
            cache(repoId, .safetensorsOnly)
            return .safetensorsOnly
        }

        // (3) Tag heuristics.
        let tags = model.tags?.map { $0.lowercased() } ?? []
        let hasCoreMLTag = tags.contains { $0.contains("coreml") || $0.contains("core-ml") }
        let isASR = (model.pipelineTag ?? "").lowercased().contains("speech-recognition")
        let status: ModelSearchStatus = (hasCoreMLTag && isASR) ? .likelyCompatible : (hasCoreMLTag ? .likelyCompatible : .unknown)
        cache(repoId, status)
        return status
    }

    private func cache(_ repoId: String, _ status: ModelSearchStatus) {
        searchStatusCache[repoId] = (status, Date())
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
        // Fast fail on known non-Whisper architectures: they may ship
        // WhisperKit-looking filenames but are not loadable (Qwen3-ASR,
        // Parakeet, Nemotron...).
        let lowerRepo = repoId.lowercased()
        if Self.incompatibleArchitectureKeywords.contains(where: { lowerRepo.contains($0) }) {
            return false
        }
        // Real check: the recursive tree must contain the exact artifacts
        // WhisperKit's loadModels() requires (MelSpectrogram, AudioEncoder
        // and TextDecoder as .mlmodelc/.mlpackage bundles). The old code
        // only listed the top level and matched ANY mlmodelc/mlpackage
        // name, so it flagged Qwen repos as compatible.
        let files = try await listFiles(repoId: repoId, path: path, recursive: true)
        let prefix = path.isEmpty ? "" : path + "/"
        return Self.whisperKitComponents.allSatisfy { component in
            files.contains { file in
                file.path.hasPrefix(prefix) &&
                file.path.contains(component) &&
                file.isCoreMLBundleName
            }
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
    ///
    /// WhisperKit 0.9.4 can ONLY load Whisper-family models. A variant is
    /// only offered when its subtree contains the exact artifacts
    /// `loadModels()` requires — `MelSpectrogram`, `AudioEncoder` and
    /// `TextDecoder` as .mlmodelc/.mlpackage bundles. Repos with a
    /// different architecture (Qwen3-ASR, Parakeet, Nemotron, ...) are
    /// excluded by keyword even when their filenames look similar, because
    /// loading them fails (or crashes at inference) no matter how they are
    /// downloaded.
    func listModelVariants(repoId: String) async throws -> [HFModelFile] {
        // Architecture denylist: known non-Whisper families that WhisperKit
        // cannot load under any circumstances.
        let lowerRepo = repoId.lowercased()
        guard !Self.incompatibleArchitectureKeywords.contains(where: { lowerRepo.contains($0) }) else {
            return []
        }

        let all = try await listFiles(repoId: repoId, recursive: true)

        // Only top-level entries (no "/" in the path) can be variants.
        let topLevel = all.filter { !$0.path.contains("/") }

        // True when the subtree under `prefix` contains all three artifacts.
        func hasWhisperKitComponents(under prefix: String) -> Bool {
            Self.whisperKitComponents.allSatisfy { component in
                all.contains { entry in
                    entry.path.hasPrefix(prefix) &&
                    entry.path.contains(component) &&
                    entry.isCoreMLBundleName
                }
            }
        }

        // Edge case: repos where the CoreML bundle lives directly at the
        // repo root (AudioEncoder/TextDecoder/MelSpectrogram .mlmodelc
        // folders, no per-variant subdirectory). Expose them as a single
        // "root bundle" variant (empty path). Must be checked on top-level
        // entries only — with a recursive listing, nested paths under any
        // variant also contain "AudioEncoder" and "mlmodelc".
        let rootHasAll = Self.whisperKitComponents.allSatisfy { component in
            topLevel.contains { $0.path.contains(component) && $0.isCoreMLBundleName }
        }
        if rootHasAll {
            return [HFModelFile(path: "", size: nil, type: "directory", lfs: nil)]
        }

        // Standard WhisperKit style: each top-level dir whose subtree
        // contains ALL three artifacts is a variant. Repos that only match
        // partially (e.g. Qwen's encoder/decoder_part1/decoder_part2/
        // embedding) yield no variants instead of a broken download.
        let variants = topLevel.filter { dir in
            guard dir.isDirectoryLike else { return false }
            let dirLower = dir.path.lowercased()
            guard !Self.incompatibleArchitectureKeywords.contains(where: { dirLower.contains($0) }) else { return false }
            return hasWhisperKitComponents(under: dir.path + "/")
        }
        return variants.sorted { $0.variantSortRank < $1.variantSortRank }
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
            let files = try HFError.decodeOrThrow([HFModelFile].self, from: data, context: "listado de archivos")
            return files
        } catch {
            do {
                let file = try HFError.decodeOrThrow(HFModelFile.self, from: data, context: "listado de archivos")
                return [file]
            } catch {
                throw error
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

    /// Maps a variant folder name (e.g. `openai_whisper-base`,
    /// `whisper-large-v3-turbo`, `Whisper-Large-v3-Turbo-CoreML`) to the
    /// matching `openai/whisper-*` repo suffix used for the tokenizer
    /// files.
    static func tokenizerSize(from variant: String) -> String? {
        let lower = variant.lowercased()
        if lower.contains("large-v3-turbo") { return "large-v3-turbo" }
        if lower.contains("large-v3") { return "large-v3" }
        if lower.contains("large-v2") { return "large-v2" }
        if lower.contains("large") { return "large" }
        if lower.contains("medium") { return "medium" }
        if lower.contains("small") { return "small" }
        if lower.contains("base") { return "base" }
        if lower.contains("tiny") { return "tiny" }
        return nil
    }

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
