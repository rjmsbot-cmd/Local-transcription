import Foundation
import CryptoKit

// MARK: - Models

struct HFRepoInfo: Codable, Identifiable, Hashable {
    let id: String
    let modelId: String
    let author: String
    let tags: [String]
    let downloads: Int?
    let likes: Int?
    let `private`: Bool
    let sdkCapabilities: [String: [String]]?
    
    var isCoreML: Bool { tags.contains("coreml") || (sdkCapabilities?["coreml"] != nil) }
    var displayName: String { modelId }
    
    static func == (lhs: HFRepoInfo, rhs: HFRepoInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HFFileEntry: Codable {
    let path: String
    let size: Int64?
    let lfs: HFFileLFS?
    let type: String?
    
    var isDirectory: Bool { type == "directory" }
    var isFile: Bool { type == "file" || (!isDirectory && lfs != nil) }
}

struct HFFileLFS: Codable {
    let size: Int64?
    let sha256: String?
}

// MARK: - Service

@MainActor
final class HuggingFaceService {
    static let shared = HuggingFaceService()
    private let session: URLSession
    
    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpAdditionalHeaders = ["User-Agent": "WhisperLocal-iOS/1.0"]
        self.session = URLSession(configuration: cfg)
    }
    
    // MARK: - Search
    
    func searchModels(query: String, limit: Int = 20) async throws -> [HFRepoInfo] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://huggingface.co/api/models?search=\(encoded)&sort=downloads&direction=-1&limit=\(limit)&pipeline_tag=automatic-speech-recognition")!
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HFError.httpError(response as? HTTPURLResponse)
        }
        return try JSONDecoder().decode([HFRepoInfo].self, from: data)
    }
    
    func repoInfo(modelId: String) async throws -> HFRepoInfo {
        let encoded = modelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelId
        let url = URL(string: "https://huggingface.co/api/models/\(encoded)")!
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HFError.httpError(response as? HTTPURLResponse)
        }
        return try JSONDecoder().decode(HFRepoInfo.self, from: data)
    }
    
    // MARK: - Tree
    
    func listTree(repoId: String, path: String = "") async throws -> [HFFileEntry] {
        var comps = URLComponents(url: URL(string: "https://huggingface.co/api/models/\(repoId)/tree/main")!, resolvingAgainstBaseURL: false)!
        if !path.isEmpty { comps.queryItems = [URLQueryItem(name: "path", value: path)] }
        let (data, response) = try await session.data(for: URLRequest(url: comps.url!))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HFError.httpError(response as? HTTPURLResponse)
        }
        return try JSONDecoder().decode([HFFileEntry].self, from: data)
    }
    
    func collectAllFiles(repoId: String, dirPath: String) async throws -> [HFFileEntry] {
        let entries = try await listTree(repoId: repoId, path: dirPath)
        var files: [HFFileEntry] = []
        for entry in entries {
            if entry.isDirectory {
                try files.append(contentsOf: await collectAllFiles(repoId: repoId, dirPath: entry.path))
            } else if entry.isFile {
                files.append(entry)
            }
        }
        return files
    }
    
    // MARK: - Download
    
    func downloadFile(
        repoId: String,
        filePath: String,
        to destURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> String {
        let encodedRepo = repoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? repoId
        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath
        let url = URL(string: "https://huggingface.co/\(encodedRepo)/resolve/main/\(encodedPath)")!
        
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destURL.path()) {
            try? FileManager.default.removeItem(at: destURL)
        }
        
        let (tmpURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw HFError.httpError(response as? HTTPURLResponse)
        }
        
        let sha = try sha256OfFile(at: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: destURL)
        progress(1.0)
        return sha
    }
    
    func downloadDirectory(
        repoId: String,
        remoteDir: String,
        to localDir: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> [String: String] {
        let files = try await collectAllFiles(repoId: repoId, dirPath: remoteDir)
        guard !files.isEmpty else { return [:] }
        
        let totalSize = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var downloaded: Int64 = 0
        var shaMap: [String: String] = [:]
        
        for file in files {
            let relative = String(file.path.dropFirst(remoteDir.count + 1))
            let dest = localDir.appendingPathComponent(relative)
            
            let fileSha = try await downloadFile(repoId: repoId, filePath: file.path, to: dest, progress: { _ in })
            shaMap[relative] = fileSha
            downloaded += file.size ?? 0
            progress(Double(downloaded) / Double(max(totalSize, 1)))
        }
        
        return shaMap
    }
    
    // MARK: - Helpers
    
    private func sha256OfFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum HFError: LocalizedError {
    case httpError(HTTPURLResponse?)
    case downloadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .httpError(let resp):
            return "Error de Hugging Face (HTTP \(resp?.statusCode ?? 0))."
        case .downloadFailed(let msg):
            return "Descarga fallida: \(msg)"
        }
    }
}
