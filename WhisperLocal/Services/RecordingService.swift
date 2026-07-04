import Foundation
import AVFoundation

final class RecordingService {
    
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
        
        let recorder = AVAudioRecorder(
            url: recordingURL,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        
        recorder.isMeteringEnabled = true
        try recorder.record()
    }
    
    func stopRecording() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false)
    }
}

// MARK: - Errors

/// Renamed from AudioError to avoid conflict with AudioProcessor.AudioError (C7 warning)
enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case recordingFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Permiso de micrófono denegado. Actívalo en Ajustes > Privacidad."
        case .recordingFailed(let err):
            return "Error de grabación: \(err.localizedDescription)"
        }
    }
}
