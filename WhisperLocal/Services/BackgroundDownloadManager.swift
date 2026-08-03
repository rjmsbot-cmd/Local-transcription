import Foundation
import BackgroundTasks

/// Background-capable downloader for model bundles.
///
/// Why this exists: downloads used `URLSession.shared` (foreground), so
/// closing the app mid-download killed the transfer and left a partial
/// model folder stuck in `.downloading` forever — the model then never
/// loads. This manager uses a **URLSession background session**, which iOS
/// runs at the system level: the download continues while the app is
/// suspended, backgrounded or even terminated. Pending batches are
/// persisted to UserDefaults and re-enqueued on next launch
/// (`resumePending()`), and a `BGProcessingTask` gives the app a slice of
/// background CPU to re-arm them.
///
/// A model download = one `PendingBatch` of per-file tasks. A batch only
/// completes when EVERY file has landed on disk, so a model is only marked
/// `.ready` (by `ModelManager.reconcileDownloads`) once its folder is
/// complete.
final class BackgroundDownloadManager: NSObject {

    static let shared = BackgroundDownloadManager()

    static let sessionIdentifier = "com.rjmsbot.WhisperLocal.modelDownloads"
    static let bgTaskIdentifier = "com.rjmsbot.WhisperLocal.modelDownload"

    private static let pendingKey = "BackgroundDownloadManager.pending"
    private static let completedKey = "BackgroundDownloadManager.completed"

    // MARK: - Persisted state

    struct PendingFile: Codable, Equatable {
        var path: String      // repo-relative path (e.g. AudioEncoder.mlmodelc/weights/x.bin)
        var size: Int64
        var downloaded: Bool  // moved to destination successfully
    }

    struct PendingBatch: Codable {
        var modelKey: String          // "repoId#variant"
        var repoId: String
        var variant: String
        var destinationDir: String    // absolute path of the local model folder root
        var files: [PendingFile]
        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

        var completedBytes: Int64 {
            files.reduce(0) { $0 + ($1.downloaded ? $1.size : 0) }
        }

        var isComplete: Bool {
            !files.isEmpty && files.allSatisfy(\.downloaded)
        }
    }

    // MARK: - Runtime state

    private let lock = NSLock()
    private var session: URLSession!
    /// taskIdentifier → (modelKey, repo-relative path, destination URL)
    private var taskMap: [Int: (String, String, URL)] = [:]
    /// Per-task received bytes for live progress reporting.
    private var receivedBytes: [Int: Int64] = [:]
    /// Awaiters for batches that are being enqueued while the app is alive.
    private var continuations: [String: CheckedContinuation<Int64, Error>] = [:]
    /// Live progress callbacks (MainActor).
    private var progressHandlers: [String: (Double, String) -> Void] = [:]

    /// Completion handler supplied by the system when the app is relaunched
    /// in the background to deliver download events. Released from
    /// `urlSessionDidFinishEvents` once every event has been processed.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Init

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false          // start as soon as possible
        config.waitsForConnectivity = true      // auto-resume when network returns
        config.allowsCellularAccess = true
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 24 * 60 * 60 // 24h per file
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        registerBackgroundTask()
        // Re-arm whatever survived a previous run (or was killed mid-flight).
        resumePending()
    }

    /// Registers the BGProcessingTask that lets the system wake the app to
    /// re-queue unfinished downloads when it grants background time.
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            self.resumePending()
            self.scheduleBackgroundDownload()
            task.setTaskCompleted(success: true)
        }
    }

    /// Asks the system for a background slot to re-arm pending downloads.
    /// Called every time a new batch is enqueued; harmless if the system
    /// ignores it (the URLSession background session still works without
    /// it — this only helps re-queuing after a full termination).
    func scheduleBackgroundDownload() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Persistence

    private func loadBatches() -> [String: PendingBatch] {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingKey),
              let decoded = try? JSONDecoder().decode([String: PendingBatch].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveBatches(_ batches: [String: PendingBatch]) {
        if let data = try? JSONEncoder().encode(batches) {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        }
    }

    private func loadCompleted() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.completedKey) ?? []
    }

    private func saveCompleted(_ keys: [String]) {
        UserDefaults.standard.set(keys, forKey: Self.completedKey)
    }

    // MARK: - Public API

    /// Enqueues a model batch for background download and awaits its
    /// completion. Files already on disk with the expected size are
    /// skipped. Returns the total bytes once every file is in place.
    /// If the app dies mid-transfer, the batch is persisted and finished by
    /// the system; `ModelManager.reconcileDownloads` flips the model to
    /// `.ready` on next launch.
    @discardableResult
    func enqueueBatch(
        repoId: String,
        variant: String,
        destinationDir: URL,
        files: [HFModelFile],
        progress: ((Double, String) -> Void)? = nil
    ) async throws -> Int64 {
        let modelKey = "\(repoId)#\(variant)"
        var batch: PendingBatch

        lock.lock()
        var batches = loadBatches()
        if let existing = batches[modelKey] {
            batch = existing
        } else {
            batch = PendingBatch(
                modelKey: modelKey,
                repoId: repoId,
                variant: variant,
                destinationDir: destinationDir.path,
                files: files.map { PendingFile(path: $0.path, size: Int64($0.size ?? 0), downloaded: false) }
            )
        }

        // Fast path: everything already on disk with the right size.
        if markOnDiskFilesDownloaded(&batch) {
            batches.removeValue(forKey: modelKey)
            saveBatches(batches)
            lock.unlock()
            noteCompleted(modelKey, totalBytes: batch.totalBytes)
            return batch.totalBytes
        }

        batches[modelKey] = batch
        saveBatches(batches)
        if let progress {
            progressHandlers[modelKey] = progress
        }
        // The batch is (or will be) transferring in the background — ask
        // for a slot to re-arm it if the app is terminated meanwhile.
        scheduleBackgroundDownload()
        lock.unlock()

        // Create tasks for every file not yet on disk.
        for file in batch.files where !file.downloaded {
            createTask(for: file.path, in: batch)
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
            lock.lock()
            // Completed between the unlock above and here? The delegate can
            // deliver the last file's callback at any time (e.g. a task
            // restored from a previous session), so check both the batch
            // (still present) and the completion marker (batch already
            // removed by markFileDownloaded).
            let current = loadBatches()[modelKey]
            if current?.isComplete == true {
                lock.unlock()
                cont.resume(returning: current?.totalBytes ?? 0)
                return
            }
            if current == nil, loadCompleted().contains(modelKey) {
                lock.unlock()
                cont.resume(returning: batch.totalBytes)
                return
            }
            continuations[modelKey] = cont
            lock.unlock()
        }
    }

    /// Re-enqueues every persisted batch that hasn't finished. Called at
    /// launch and from the background task. Files already on disk are
    /// skipped; the rest get fresh URLSession tasks (the system also
    /// auto-restores any tasks that were mid-flight when the app died).
    func resumePending() {
        lock.lock()
        var batches = loadBatches()
        let keys = Array(batches.keys)
        lock.unlock()

        for key in keys {
            lock.lock()
            guard var batch = batches[key] else { lock.unlock(); continue }
            if markOnDiskFilesDownloaded(&batch) {
                batches.removeValue(forKey: key)
                saveBatches(batches)
                lock.unlock()
                noteCompleted(key, totalBytes: batch.totalBytes)
                continue
            }
            batches[key] = batch
            saveBatches(batches)
            let filesToQueue = batch.files.filter { !$0.downloaded }
            lock.unlock()

            for file in filesToQueue {
                createTask(for: file.path, in: batch)
            }
        }
        if !keys.isEmpty { scheduleBackgroundDownload() }
    }

    /// Returns and clears the set of batch keys that finished while the
    /// app was not running, so `ModelManager` can flip `.downloading`
    /// models to `.ready`.
    func consumeCompletedBatches() -> [String] {
        lock.lock()
        let done = loadCompleted()
        saveCompleted([])
        lock.unlock()
        return done
    }

    /// Live progress for a batch (MainActor), used by UI while the app is
    /// foregrounded.
    func progress(for modelKey: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let batch = loadBatches()[modelKey], batch.totalBytes > 0 else { return 0 }
        return min(1, Double(batch.completedBytes) / Double(batch.totalBytes))
    }

    // MARK: - Internals

    private func markOnDiskFilesDownloaded(_ batch: inout PendingBatch) -> Bool {
        var changed = false
        for i in batch.files.indices where !batch.files[i].downloaded {
            let url = URL(fileURLWithPath: batch.destinationDir).appendingPathComponent(batch.files[i].path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64, size == batch.files[i].size, size > 0 else { continue }
            batch.files[i].downloaded = true
            changed = true
        }
        return changed && batch.isComplete
    }

    private func createTask(for relativePath: String, in batch: PendingBatch) {
        let safeRepo = HuggingFaceService.shared.sanitizePathComponent(batch.repoId)
        let safeFile = HuggingFaceService.shared.sanitizePathComponent(relativePath)
        // Percent-encoded path via URLComponents: repo/folder names with
        // spaces or special chars ("Whisper Large…") must not produce an
        // invalid URL (URL(string:) would return nil and the task would be
        // silently dropped, hanging the batch in .downloading forever).
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.percentEncodedPath = "/\(safeRepo)/resolve/main/\(safeFile)"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        if !HuggingFaceService.authToken.isEmpty {
            request.setValue("Bearer \(HuggingFaceService.authToken)", forHTTPHeaderField: "Authorization")
        }
        let task = session.downloadTask(with: request)
        let destURL = URL(fileURLWithPath: batch.destinationDir).appendingPathComponent(relativePath)
        lock.lock()
        taskMap[task.taskIdentifier] = (batch.modelKey, relativePath, destURL)
        receivedBytes[task.taskIdentifier] = 0
        lock.unlock()
        task.resume()
    }

    /// Called when one file landed on disk. Advances the batch; when the
    /// last file lands, the batch is completed (continuation resumed +
    /// completion marker persisted) and a final 100% progress tick is
    /// emitted so the sheet shows completion even if nothing is awaiting.
    private func markFileDownloaded(_ modelKey: String, _ relativePath: String) {
        lock.lock()
        var batches = loadBatches()
        guard var batch = batches[modelKey],
              let idx = batch.files.firstIndex(where: { $0.path == relativePath }) else {
            lock.unlock()
            return
        }
        batch.files[idx].downloaded = true
        let isComplete = batch.isComplete
        let totalBytes = batch.totalBytes
        if isComplete {
            batches.removeValue(forKey: modelKey)
            saveBatches(batches)
        } else {
            batches[modelKey] = batch
            saveBatches(batches)
        }
        lock.unlock()

        if isComplete {
            if let handler = progressHandlers[modelKey] {
                DispatchQueue.main.async {
                    handler(1.0, "Descarga completada")
                }
            }
            noteCompleted(modelKey, totalBytes: totalBytes)
        } else {
            fireProgress(batch)
        }
    }

    private func noteCompleted(_ modelKey: String, totalBytes: Int64) {
        lock.lock()
        var done = loadCompleted()
        if !done.contains(modelKey) { done.append(modelKey) }
        saveCompleted(done)
        let cont = continuations.removeValue(forKey: modelKey)
        progressHandlers.removeValue(forKey: modelKey)
        lock.unlock()
        cont?.resume(returning: totalBytes)
        // Let UI (DownloadSheet) know even when nothing is awaiting.
        NotificationCenter.default.post(name: .modelBatchCompleted, object: modelKey)
    }

    /// Definitive failure (HTTP 4xx from HF, etc.): the batch is removed
    /// from the persisted state so `resumePending()` does not re-queue a
    /// batch that can never succeed on every launch. The UI shows the
    /// `.failed` state with a "Reintentar" button (which re-lists the
    /// files and re-enqueues only what is missing).
    private func failBatch(_ modelKey: String, _ error: Error) {
        lock.lock()
        var batches = loadBatches()
        batches.removeValue(forKey: modelKey)
        saveBatches(batches)
        let cont = continuations.removeValue(forKey: modelKey)
        progressHandlers.removeValue(forKey: modelKey)
        lock.unlock()
        cont?.resume(throwing: error)
    }

    private func fireProgress(_ batch: PendingBatch) {
        let total = batch.totalBytes
        guard total > 0 else { return }
        let fraction = min(1, Double(batch.completedBytes) / Double(total))
        let handler = progressHandlers[batch.modelKey]
        let modelKey = batch.modelKey
        DispatchQueue.main.async {
            handler?(fraction, "Descargando en segundo plano… \(Int(fraction * 100))%")
        }
    }

    /// Resolves the destination for a restored task (app relaunched while
    /// the system was still transferring): derives the repo-relative path
    /// from the request URL and looks it up in the pending batches.
    private func resolveTask(_ task: URLSessionDownloadTask) -> (String, String, URL)? {
        if let known = taskMap[task.taskIdentifier] {
            return known
        }
        guard let path = task.originalRequest?.url?.path,
              let range = path.range(of: "/resolve/main/") else { return nil }
        // URL paths arrive percent-encoded (spaces → %20); the persisted
        // PendingFile paths are raw, so decode before comparing or the
        // lookup misses and the completed file is never moved into place.
        let encoded = String(path[range.upperBound...])
        let relPath = encoded.removingPercentEncoding ?? encoded
        lock.lock()
        let batches = loadBatches()
        for batch in batches.values {
            if batch.files.contains(where: { $0.path == relPath }) {
                let dest = URL(fileURLWithPath: batch.destinationDir).appendingPathComponent(relPath)
                taskMap[task.taskIdentifier] = (batch.modelKey, relPath, dest)
                receivedBytes[task.taskIdentifier] = 0
                lock.unlock()
                return (batch.modelKey, relPath, dest)
            }
        }
        lock.unlock()
        return nil
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (modelKey, relativePath, destURL) = resolveTask(downloadTask) else { return }
        do {
            try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)
            lock.lock()
            taskMap.removeValue(forKey: downloadTask.taskIdentifier)
            receivedBytes.removeValue(forKey: downloadTask.taskIdentifier)
            lock.unlock()
            markFileDownloaded(modelKey, relativePath)
        } catch {
            // Leave the file pending; it will be retried on the next
            // resumePending() pass.
            print("[BackgroundDownloadManager] No se pudo mover \(relativePath): \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard let (modelKey, relativePath, _) = taskMap[task.taskIdentifier] else { return }
        let nsError = error as NSError

        // Definitive failures (the request reached HF and got a status
        // code): fail the batch so the UI shows a real error. Transient
        // network errors keep the batch pending — waitsForConnectivity
        // and resumePending() retry them.
        if nsError.code == NSURLErrorBadServerResponse {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            switch status {
            case 401, 403:
                failBatch(modelKey, HFError.authRequired)
            case 404:
                failBatch(modelKey, HFError.notFound)
            case 429:
                failBatch(modelKey, HFError.rateLimited)
            default:
                print("[BackgroundDownloadManager] HTTP \(status ?? -1) para \(relativePath)")
                failBatch(modelKey, HFError.networkFailed(nsError))
            }
            return
        }
        // Everything else (offline, timeout, cancelled): log and keep the
        // batch pending for the next resume pass.
        print("[BackgroundDownloadManager] Fallo transitorio \(relativePath): \(error.localizedDescription)")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (modelKey, relativePath, _) = resolveTask(downloadTask) else { return }
        lock.lock()
        receivedBytes[downloadTask.taskIdentifier] = totalBytesWritten
        guard var batch = loadBatches()[modelKey],
              let idx = batch.files.firstIndex(where: { $0.path == relativePath }) else {
            lock.unlock()
            return
        }
        let doneSoFar = batch.completedBytes - (batch.files[idx].downloaded ? batch.files[idx].size : 0) + min(totalBytesWritten, batch.files[idx].size)
        let total = batch.totalBytes
        lock.unlock()
        guard total > 0 else { return }
        let fraction = min(1, Double(max(0, doneSoFar)) / Double(total))
        let handler = progressHandlers[modelKey]
        DispatchQueue.main.async {
            handler?(fraction, "Descargando en segundo plano… \(Int(fraction * 100))%")
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        print("[BackgroundDownloadManager] Sesión inválida: \(error?.localizedDescription ?? "desconocido")")
    }

    /// All background events for this session have been delivered (the app
    /// was relaunched by the system to finish transfers): release the
    /// completion handler so iOS can suspend the app again cleanly.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async {
            handler?()
        }
    }
}

extension Notification.Name {
    static let modelBatchCompleted = Notification.Name("BackgroundDownloadManager.batchCompleted")
}
