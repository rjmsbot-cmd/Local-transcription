import Foundation

/// Client for HuggingFace Hub API — search models, list files, download.
actor HuggingFaceService {
    private let baseURL = "https://huggingface.co/api"
    private let downloadBase = "https://huggingface.co"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = true
        // Allow cellular downloads
        config.allowsCellularAccess = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - URL Sanitization (Security)

    private static func sanitizePathComponent(_ input: String) -> String {
        let sanitized = input
            .replacingOccurrences(of: "//", with: "/")
            .replacingOccurrences(of: "../", with: "")
            .replacingOccurrences(of: "..\\", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\ \t\n\r"))
        guard CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
            .isSuperset(of: CharacterSet(charactersIn: sanitized)) else {
            return sanitized.components(
                separatedBy: CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "._-"))
            ).joined(separator: "_")
        }
        return sanitized
    }

    // MARK: - Search

    func searchModels(query: String, limit: Int = 30) async throws -> [HFModel] {
        var components = URLComponents(string: "\(baseURL)/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "automatic-speech-recognition"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        let (data, response) = try await session.data(from: components.url!)
        try validateResponse(response)
        let all = try JSONDecoder().decode([HFModel].self, from: data)
        // Don't filter - show all ASR models including non-Whisper ones
        return all
    }

    func getPopularWhisperModels() async throws -> [HFModel] {
        var components = URLComponents(string: "\(baseURL)/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: "whisper"),
            URLQueryItem(name: "filter", value: "automatic-speech-recognition"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "30")
        ]

        let (data, response) = try await session.data(from: components.url!)
        try validateResponse(response)
        let all = try JSONDecoder().decode([HFModel].self, from: data)
        return all.filter { $0.isWhisperCompatible }
    }

    // MARK: - Model Files

    func listFiles(repoId: String) async throws -> [HFFileItem] {
        let url = URL(string: "\(baseURL)/models/\(repoId)/tree/main")!
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try JSONDecoder().decode([HFFileItem].self, from: data)
    }

    func listModelVariants(repoId: String) async throws -> [ModelVariant] {
        let files = try await listFiles(repoId: repoId)
        let modelFiles = files.filter { $0.isModelFile && !$0.isDirectory }

        var variants: [ModelVariant] = []
        for file in modelFiles {
            let variant = ModelVariant(from: file)
            variants.append(variant)
        }

        // Sort: Core ML first, then by size
        return variants.sorted { a, b in
            if a.format == .coreML && b.format != .coreML { return true }
            if a.format != .coreML && b.format == .coreML { return false }
            return (a.fileSize ?? 0) < (b.fileSize ?? 0)
        }
    }

    func findBestModelFile(repoId: String) async throws -> HFFileItem? {
        let files = try await listFiles(repoId: repoId)
        let modelFiles = files.filter { $0.isModelFile && !$0.isDirectory }

        return modelFiles.first(where: { $0.isCoreML }) ??
               modelFiles.first(where: { $0.isGGUF }) ??
               modelFiles.first(where: { $0.path.hasSuffix(".onnx") }) ??
               modelFiles.first(where: { $0.path.hasSuffix(".bin") }) ??
               modelFiles.first(where: { $0.path.hasSuffix(".pt") }) ??
               modelFiles.first
    }

    // MARK: - Download (Streaming - no memory issues)

    func downloadFile(
        repoId: String,
        fileName: String,
        progressHandler: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {
        // Delegate to streaming download
        let stream = downloadFileWithProgress(repoId: repoId, fileName: fileName)
        
        for try await progress in stream {
            await progressHandler(progress)
        }
        
        // Return the destination path
        let modelsDir = try modelsDirectory()
        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
        return modelsDir.appendingPathComponent(safeName)
    }

    func downloadFileWithProgress(
        repoId: String,
        fileName: String
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let modelsDir = try self.modelsDirectory()
                    let safeName = fileName.replacingOccurrences(of: "/", with: "_")
                    let destination = modelsDir.appendingPathComponent(safeName)

                    // Skip if already downloaded
                    if FileManager.default.fileExists(atPath: destination.path) {
                        continuation.yield(1.0)
                        continuation.finish()
                        return
                    }

                    let downloadURL = URL(string: "\(self.downloadBase)/\(repoId)/resolve/main/\(fileName)")!
                    
                    // Use bytes stream for memory-efficient download
                    let (bytes, response) = try await self.session.bytes(from: downloadURL)
                    try self.validateResponse(response)

                    let expectedBytes = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? 0

                    var receivedBytes: Int64 = 0
                    var accumulator = Data()
                    let chunkSize = 1024 * 512 // 512KB chunks

                    for try await byte in bytes {
                        accumulator.append(byte)
                        receivedBytes += 1

                        if accumulator.count >= chunkSize {
                            if FileManager.default.fileExists(atPath: destination.path) {
                                let handle = try FileHandle(forWritingTo: destination)
                                handle.seekToEndOfFile()
                                handle.write(accumulator)
                                handle.closeFile()
                            } else {
                                try accumulator.write(to: destination)
                            }
                            accumulator.removeAll()

                            if expectedBytes > 0 {
                                let progress = Double(receivedBytes) / Double(expectedBytes)
                                continuation.yield(min(progress, 0.99))
                            } else {
                                // No content-length, just report periodic progress
                                if receivedBytes % (1024 * 1024 * 10) == 0 {
                                    continuation.yield(0.5)
                                }
                            }
                        }
                    }

                    // Write remaining data
                    if !accumulator.isEmpty {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            let handle = try FileHandle(forWritingTo: destination)
                            handle.seekToEndOfFile()
                            handle.write(accumulator)
                            handle.closeFile()
                        } else {
                            try accumulator.write(to: destination)
                        }
                    }

                    continuation.yield(1.0)
                    continuation.finish()
                } catch {
                    // Clean up partial download on error
                    let modelsDir = try? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("WhisperModels", isDirectory: true)
                    let safeName = fileName.replacingOccurrences(of: "/", with: "_")
                    let destination = modelsDir?.appendingPathComponent(safeName)
                    if let dest = destination, FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.removeItem(at: dest)
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Delete

    func deleteDownloadedFile(fileName: String) throws {
        let modelsDir = try modelsDirectory()
        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
        let fileURL = modelsDir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Helpers

    private func modelsDirectory() throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HFError.invalidResponse(statusCode: -1)
        }
        switch http.statusCode {
        case 200: return
        case 404: throw HFError.notFound
        case 429: throw HFError.rateLimited
        case 401, 403: throw HFError.accessDenied
        default: throw HFError.invalidResponse(statusCode: http.statusCode)
        }
    }
}

// MARK: - Model Variant (for quantization selection)

struct ModelVariant: Identifiable, Hashable {
    let id = UUID()
    let fileName: String
    let format: ModelFormat
    let quantization: String
    let fileSize: Int64?
    let fileSizeFormatted: String

    init(from file: HFFileItem) {
        self.fileName = file.path
        self.fileSize = file.size ?? file.lfs?.size
        self.fileSizeFormatted = ByteCountFormatter.string(fromByteCount: self.fileSize ?? 0, countStyle: .file)

        // Detect format
        if file.isCoreML {
            self.format = .coreML
        } else if file.isGGUF {
            self.format = .gguf
        } else if file.path.hasSuffix(".onnx") {
            self.format = .onnx
        } else if file.path.hasSuffix(".bin") || file.path.hasSuffix(".pt") {
            self.format = .pytorch
        } else {
            self.format = .other
        }

        // Detect quantization from filename
        let lower = file.path.lowercased()
        if lower.contains("q4_0") { self.quantization = "Q4_0 (smallest, fastest)" }
        else if lower.contains("q4_1") { self.quantization = "Q4_1" }
        else if lower.contains("q4_k_m") { self.quantization = "Q4_K_M (recommended)" }
        else if lower.contains("q4_k_s") { self.quantization = "Q4_K_S" }
        else if lower.contains("q5_0") { self.quantization = "Q5_0" }
        else if lower.contains("q5_1") { self.quantization = "Q5_1" }
        else if lower.contains("q5_k_m") { self.quantization = "Q5_K_M" }
        else if lower.contains("q5_k_s") { self.quantization = "Q5_K_S" }
        else if lower.contains("q6_k") { self.quantization = "Q6_K (high quality)" }
        else if lower.contains("q8_0") { self.quantization = "Q8_0 (best quantized)" }
        else if lower.contains("float16") || lower.contains("fp16") { self.quantization = "Float16" }
        else if lower.contains("float32") || lower.contains("fp32") { self.quantization = "Float32 (full precision)" }
        else if lower.contains("int8") { self.quantization = "Int8" }
        else if lower.contains("int4") { self.quantization = "Int4" }
        else if lower.contains("4bit") { self.quantization = "4-bit" }
        else if lower.contains("8bit") { self.quantization = "8-bit" }
        else if lower.contains("16bit") { self.quantization = "16-bit" }
        else if file.isCoreML { self.quantization = "Core ML (Neural Engine)" }
        else if file.isGGUF { self.quantization = "GGUF" }
        else { self.quantization = "Default" }
    }
}

enum ModelFormat: String, Hashable {
    case coreML = "Core ML"
    case gguf = "GGUF"
    case onnx = "ONNX"
    case pytorch = "PyTorch"
    case other = "Other"

    var icon: String {
        switch self {
        case .coreML: return "cpu"
        case .gguf: return "cube"
        case .onnx: return "square.grid.3x3"
        case .pytorch: return "flame"
        case .other: return "doc"
        }
    }

    var badge: String {
        switch self {
        case .coreML: return "⚡ Neural Engine"
        case .gguf: return "📦 GGUF"
        case .onnx: return "🔧 ONNX"
        case .pytorch: return "🔥 PyTorch"
        case .other: return "📄"
        }
    }
}

enum HFError: LocalizedError {
    case invalidResponse(statusCode: Int)
    case notFound
    case rateLimited
    case accessDenied
    case noCompatibleFile

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let code): return "HuggingFace returned HTTP \(code)"
        case .notFound: return "Model or file not found on HuggingFace"
        case .rateLimited: return "Rate limited by HuggingFace. Try again in a minute."
        case .accessDenied: return "Access denied. The model may require authentication."
        case .noCompatibleFile: return "No compatible model file found in this repository"
        }
    }
}
