import Foundation

/// Client for HuggingFace Hub API — search models, list files, download.
actor HuggingFaceService {
    private let baseURL = "https://huggingface.co/api"
    private let downloadBase = "https://huggingface.co"
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 7200 // 2h for large models
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
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
        return try JSONDecoder().decode([HFModel].self, from: data)
    }
    
    func getPopularWhisperModels() async throws -> [HFModel] {
        var components = URLComponents(string: "\(baseURL)/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: "whisper"),
            URLQueryItem(name: "filter", value: "automatic-speech-recognition"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "20")
        ]
        
        let (data, response) = try await session.data(from: components.url!)
        try validateResponse(response)
        return try JSONDecoder().decode([HFModel].self, from: data)
    }
    
    // MARK: - Model Files
    
    func listFiles(repoId: String) async throws -> [HFFileItem] {
        let url = URL(string: "\(baseURL)/models/\(repoId)/tree/main")!
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try JSONDecoder().decode([HFFileItem].self, from: data)
    }
    
    func findBestModelFile(repoId: String) async throws -> HFFileItem? {
        let files = try await listFiles(repoId: repoId)
        
        // Prefer: Core ML > GGUF > ONNX > .bin > .pt
        let modelFiles = files.filter { $0.isModelFile && !$0.isDirectory }
        
        return modelFiles.first(where: { $0.isCoreML }) ??
               modelFiles.first(where: { $0.isGGUF }) ??
               modelFiles.first(where: { $0.path.hasSuffix(".onnx") }) ??
               modelFiles.first(where: { $0.path.hasSuffix(".bin") }) ??
               modelFiles.first(where: { $0.path.hasSuffix(".pt") }) ??
               modelFiles.first
    }
    
    // MARK: - Download
    
    func downloadFile(
        repoId: String,
        fileName: String,
        progressHandler: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {
        let modelsDir = try modelsDirectory()
        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
        let destination = modelsDir.appendingPathComponent(safeName)
        
        // Already downloaded?
        if FileManager.default.fileExists(atPath: destination.path) {
            await progressHandler(1.0)
            return destination
        }
        
        let downloadURL = URL(string: "\(downloadBase)/\(repoId)/resolve/main/\(fileName)")!
        
        let (data, response) = try await session.data(from: downloadURL)
        try validateResponse(response)
        
        await progressHandler(0.9)
        try data.write(to: destination)
        await progressHandler(1.0)
        
        return destination
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
                    
                    if FileManager.default.fileExists(atPath: destination.path) {
                        continuation.yield(1.0)
                        continuation.finish()
                        return
                    }
                    
                    let downloadURL = URL(string: "\(self.downloadBase)/\(repoId)/resolve/main/\(fileName)")!
                    let (bytes, response) = try await self.session.bytes(from: downloadURL)
                    try self.validateResponse(response)
                    
                    let expectedBytes = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? 0
                    
                    var receivedBytes: Int64 = 0
                    var accumulator = Data()
                    let chunkSize = 1024 * 1024 // Write every 1MB
                    
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
                            }
                        }
                    }
                    
                    // Write remaining
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
        default: throw HFError.invalidResponse(statusCode: http.statusCode)
        }
    }
}

enum HFError: LocalizedError {
    case invalidResponse(statusCode: Int)
    case notFound
    case rateLimited
    case noCompatibleFile
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse(let code): return "HuggingFace returned HTTP \(code)"
        case .notFound: return "Model or file not found on HuggingFace"
        case .rateLimited: return "Rate limited by HuggingFace. Try again in a minute."
        case .noCompatibleFile: return "No compatible model file found in this repository"
        }
    }
}
