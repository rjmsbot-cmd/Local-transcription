import Foundation
import AVFoundation

/// Stateful recording service used by `RecordView`.
///
/// Exposes the full API surface `RecordView` expects:
/// - a shared singleton (`RecordingService.shared`) that is also an
///   `ObservableObject` so the view can observe it with `@StateObject`
/// - published recording state / duration / level meter
/// - async `startRecording()` and **synchronous** `stopRecording() throws -> URL`
/// - pause / resume / discard controls
@MainActor
final class RecordingService: ObservableObject {
    
    static let shared = RecordingService()
    
    enum RecordingState {
        case idle
        case recording
        case paused
    }
    
    // MARK: - Published state
    
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var currentDuration: TimeInterval = 0
    @Published private(set) var dBLevel: Float = 0
    
    // MARK: - Computed state
    
    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }
    
    // MARK: - Private state
    
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var meterTimer: Timer?
    
    private init() {}
    
    // MARK: - Permission
    
    func requestPermission() async -> Bool {
        // 🔴 Fix #2.9: Actually request microphone permission (not just check)
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            return granted
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
    
    func checkPermission() -> Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }
    
    // MARK: - Recording
    
    /// Start recording to a protected directory (F7 fix).
    /// If no URL is provided, create one in the protected recordings directory.
    func startRecording(to url: URL? = nil) async throws {
        guard await requestPermission() else {
            throw RecordingError.microphonePermissionDenied
        }
        
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        
        // F7 fix: use protected recordings directory
        let recordingURL: URL
        if let provided = url {
            recordingURL = provided
        } else {
            let protectedDir = try AppState.recordingsDirectory()
            recordingURL = protectedDir
                .appendingPathComponent("recording_\(UUID().uuidString).m4a")
        }
        
        let recorder = try AVAudioRecorder(
            url: recordingURL,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.recordingFailed(NSError(
                domain: "RecordingService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo iniciar el grabador de audio."]
            ))
        }
        
        self.recorder = recorder
        self.currentURL = recordingURL
        self.state = .recording
        self.currentDuration = 0
        self.dBLevel = 0
        startMeterTimer()
    }
    
    func pauseRecording() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        stopMeterTimer()
    }
    
    func resumeRecording() {
        guard state == .paused else { return }
        guard let recorder, recorder.record() else { return }
        state = .recording
        startMeterTimer()
    }
    
    func discardRecording() {
        stopMeterTimer()
        recorder?.stop()
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        resetState()
    }
    
    /// Synchronous stop: returns the recorded file URL.
    /// The caller is responsible for deleting it via `discardRecording`
    /// if it ends up unused.
    func stopRecording() throws -> URL {
        stopMeterTimer()
        recorder?.stop()
        guard let url = currentURL else {
            resetState()
            throw RecordingError.notRecording
        }
        currentURL = nil
        recorder = nil
        resetState()
        return url
    }
    
    // MARK: - Metering
    
    private func startMeterTimer() {
        stopMeterTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMeters()
            }
        }
        meterTimer = timer
    }
    
    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
    
    private func updateMeters() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        currentDuration = recorder.currentTime
        // averagePower is in dB (-160...0); normalize to a 0...1 meter
        let power = recorder.averagePower(forChannel: 0)
        dBLevel = max(0, min(1, (power + 60) / 60))
    }
    
    private func resetState() {
        recorder = nil
        currentURL = nil
        state = .idle
        currentDuration = 0
        dBLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

// MARK: - Errors

/// Renamed from AudioError to avoid conflict with AudioProcessor.AudioError (C7 warning)
enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case recordingFailed(Error)
    case notRecording
    
    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Permiso de micrófono denegado. Actívalo en Ajustes > Privacidad."
        case .recordingFailed(let err):
            return "Error de grabación: \(err.localizedDescription)"
        case .notRecording:
            return "No hay ninguna grabación activa."
        }
    }
}
