import Foundation
import AVFoundation

// MARK: - Recording State

enum RecordingState {
    case idle
    case recording(TimeInterval)
    case paused(TimeInterval)
    case finished(URL)
}

// MARK: - Recording Service

@MainActor
final class RecordingService: ObservableObject {
    static let shared = RecordingService()
    
    @Published var state: RecordingState = .idle
    @Published var meterLevel: Float = 0.0
    
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private var startTime: Date?
    private var accumulatedTime: TimeInterval = 0
    private var meterTimer: Timer?
    
    private init() {
        setupAudioSession()
    }
    
    // MARK: - Audio Session
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }
    
    // MARK: - Permission
    
    func requestPermission() async -> Bool {
        let granted = await AVAudioSession.sharedInstance().recordPermission == .granted
        return granted
    }
    
    // MARK: - Recording
    
    func startRecording() async throws {
        let granted = await AVAudioSession.sharedInstance().recordPermission
        guard granted == .granted else {
            throw RecordingError.micPermissionDenied
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Int(Date().timeIntervalSince1970)).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        
        // Clean up any previous recording
        try? FileManager.default.removeItem(at: url)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        recorder?.prepare()
        
        guard recorder?.record() == true else {
            throw RecordingError.recorderStartFailed
        }
        
        recordingURL = url
        startTime = Date()
        accumulatedTime = 0
        
        // Update state every 0.1s
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = self.accumulatedTime + (Date().timeIntervalSince(self.startTime ?? Date()))
            self.state = .recording(elapsed)
        }
        
        // Meter level for visual feedback
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recorder?.updateMeters()
            self.meterLevel = self.recorder?.averagePower(forChannel: 0) ?? 0
        }
        
        state = .recording(0)
    }
    
    func pauseRecording() {
        guard case .recording = state else { return }
        
        recorder?.pause()
        timer?.invalidate()
        timer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        
        if let start = startTime {
            accumulatedTime += Date().timeIntervalSince(start)
            startTime = nil
        }
        
        state = .paused(accumulatedTime)
    }
    
    func resumeRecording() {
        guard case .paused = state else { return }
        
        recorder?.record()
        startTime = Date()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = self.accumulatedTime + (Date().timeIntervalSince(self.startTime ?? Date()))
            self.state = .recording(elapsed)
        }
        
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recorder?.updateMeters()
            self.meterLevel = self.recorder?.averagePower(forChannel: 0) ?? 0
        }
    }
    
    func stopRecording() throws -> URL {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        
        guard let url = recordingURL else {
            throw RecordingError.noRecording
        }
        
        state = .finished(url)
        return url
    }
    
    func discardRecording() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        
        recordingURL = nil
        startTime = nil
        accumulatedTime = 0
        state = .idle
        meterLevel = 0
    }
    
    // MARK: - Helpers
    
    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }
    
    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }
    
    var currentDuration: TimeInterval {
        switch state {
        case .recording(let t): return t
        case .paused(let t): return t
        case .finished: return 0
        case .idle: return 0
        }
    }
    
    var dBLevel: Float {
        // Convert dB to 0..1 range (dB is negative, -60 is silence, 0 is max)
        let clamped = max(meterLevel, -60.0)
        return 1.0 - (clamped / 60.0)
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case micPermissionDenied
    case recorderStartFailed
    case noRecording
    
    var errorDescription: String? {
        switch self {
        case .micPermissionDenied: return "Se necesita permiso del micrófono para grabar."
        case .recorderStartFailed: return "No se pudo iniciar la grabación."
        case .noRecording: return "No hay ninguna grabación."
        }
    }
}
