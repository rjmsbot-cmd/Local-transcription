import Foundation
import AVFoundation

/// Handles audio file conversion, duration detection, and chunking for long files.
/// All output is 16kHz mono Float32 PCM — the native format for Whisper models.
actor AudioProcessor {
    
    private let whisperSampleRate: Double = 16000
    private let chunkDuration: TimeInterval = 30.0 // Whisper's native window
    private let overlapDuration: TimeInterval = 2.0  // Overlap to avoid word cutoffs
    
    // MARK: - Duration
    
    func getAudioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
    
    // MARK: - Convert to Whisper PCM
    
    /// Converts any audio file to 16kHz mono Float32 PCM samples suitable for Whisper.
    func convertToWhisperPCM(at sourceURL: URL) throws -> (samples: [Float], sampleRate: Double) {
        let audioFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw AudioError.bufferAllocationFailed
        }
        try audioFile.read(into: buffer)
        
        // Already 16kHz mono Float32?
        if sourceFormat.sampleRate == whisperSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData {
            return (Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))), whisperSampleRate)
        }
        
        // Need conversion
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: whisperSampleRate,
                                                channels: 1,
                                                interleaved: false) else {
            throw AudioError.formatCreationFailed
        }
        
        let ratio = whisperSampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount),
              let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioError.conversionFailed
        }
        
        var error: NSError?
        var capturedBuffer: AVAudioPCMBuffer?
        
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if let input = buffer {
                outStatus.pointee = .haveData
                capturedBuffer = input
                return input
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if let error = error { throw error }
        
        guard let channelData = outputBuffer.floatChannelData else {
            throw AudioError.conversionFailed
        }
        
        let sampleCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: sampleCount))
        return (samples, whisperSampleRate)
    }
    
    // MARK: - Chunking for Long Audio
    
    /// Splits audio into chunks for processing files longer than ~30 minutes.
    /// Returns chunk URLs (16kHz mono WAV) and their time offsets.
    func splitIntoChunks(at sourceURL: URL, chunkSeconds: TimeInterval = 30.0) throws -> [(url: URL, offset: TimeInterval)] {
        let audioFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = audioFile.processingFormat
        let totalFrames = audioFile.length
        let totalDuration = Double(totalFrames) / sourceFormat.sampleRate
        
        guard totalDuration > chunkSeconds else {
            // Short audio, no chunking needed
            return [(sourceURL, 0)]
        }
        
        let chunkFrames = AVAudioFrameCount(chunkSeconds * sourceFormat.sampleRate)
        let overlapFrames = AVAudioFrameCount(overlapDuration * sourceFormat.sampleRate)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("whisper_chunks_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        var result: [(url: URL, offset: TimeInterval)] = []
        var currentFrame: AVAudioFramePosition = 0
        var chunkIndex = 0
        
        while currentFrame < totalFrames {
            let framesToRead = min(chunkFrames + overlapFrames, AVAudioFrameCount(totalFrames - currentFrame))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else { break }
            
            audioFile.framePosition = currentFrame
            try audioFile.read(into: buffer, frameCount: framesToRead)
            
            let chunkURL = tempDir.appendingPathComponent("chunk_\(String(format: "%04d", chunkIndex)).wav")
            let outputFile = try AVAudioFile(forWriting: chunkURL, settings: sourceFormat.settings)
            try outputFile.write(from: buffer)
            
            let offset = Double(currentFrame) / sourceFormat.sampleRate
            result.append((chunkURL, offset))
            
            currentFrame += AVAudioFramePosition(chunkFrames) // Advance by chunk size, overlap handled by reading extra
            chunkIndex += 1
        }
        
        return result
    }
    
    /// Cleans up temporary chunk files.
    func cleanupChunks(_ chunks: [(url: URL, offset: TimeInterval)]) {
        guard let first = chunks.first else { return }
        let tempDir = first.url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Supported Formats
    
    static let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus",
        "wma", "aiff", "aif", "caf", "amr", "3gp", "mp4", "m4b"
    ]
    
    static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

enum AudioError: LocalizedError {
    case bufferAllocationFailed
    case formatCreationFailed
    case conversionFailed
    case unsupportedFormat(String)
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "Failed to allocate audio buffer"
        case .formatCreationFailed: return "Failed to create audio format"
        case .conversionFailed: return "Audio conversion failed"
        case .unsupportedFormat(let ext): return "Unsupported audio format: .\(ext)"
        case .fileNotFound: return "Audio file not found"
        }
    }
}
