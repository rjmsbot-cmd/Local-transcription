import Foundation
import AVFoundation
import Accelerate

enum AudioError: Error {
    case fileNotFound
    case formatCreationFailed
    case conversionFailed
}

struct AudioChunk {
    let index: Int
    let fileURL: URL
    let startTime: TimeInterval
    let duration: TimeInterval
}

class AudioProcessor {
    static let supportedExtensions = ["mp3", "wav", "m4a", "aac", "flac", "ogg", "wma", "aiff", "opus"]
    private let whisperSampleRate: Double = 16000

    func loadAudio(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let fileURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioError.fileNotFound
        }
        let audioFile = try AVAudioFile(forReading: fileURL)
        let sourceFormat = audioFile.processingFormat
        let frameCount = AVAudioFramePosition(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw AudioError.conversionFailed
        }
        try audioFile.read(into: buffer)

        if sourceFormat.sampleRate == whisperSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData {
            return (Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))), whisperSampleRate)
        }

        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(frameCount) * whisperSampleRate / sourceFormat.sampleRate) + 1024),
              let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioError.formatCreationFailed
        }

        var error: NSError?

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error { throw error }

        guard let channelData = outputBuffer.floatChannelData else {
            throw AudioError.conversionFailed
        }
        let count = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        return (samples, whisperSampleRate)
    }

    func getAudioDuration(at url: URL) throws -> TimeInterval {
        let audioFile = try AVAudioFile(forReading: url.standardizedFileURL)
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    func splitIntoChunks(at url: URL, chunkDuration: TimeInterval = 30.0, overlap: TimeInterval = 2.0) throws -> [AudioChunk] {
        let audioFile = try AVAudioFile(forReading: url.standardizedFileURL)
        let totalDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        guard totalDuration > chunkDuration else {
            return [AudioChunk(index: 0, fileURL: url.standardizedFileURL, startTime: 0, duration: totalDuration)]
        }

        var chunks: [AudioChunk] = []
        let step = chunkDuration - overlap
        var currentTime: TimeInterval = 0
        var index = 0

        while currentTime < totalDuration {
            let remaining = totalDuration - currentTime
            let duration = min(chunkDuration, remaining)
            if duration < 1.0 { break }

            let chunkURL = try extractChunk(from: audioFile, startTime: currentTime, duration: duration, index: index)
            chunks.append(AudioChunk(index: index, fileURL: chunkURL, startTime: currentTime, duration: duration))

            if currentTime + duration >= totalDuration { break }
            currentTime += step
            index += 1
        }
        return chunks
    }

    private func extractChunk(from audioFile: AVAudioFile, startTime: TimeInterval, duration: TimeInterval, index: Int) throws -> URL {
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let startFrame = AVAudioFramePosition(startTime * sampleRate)
        let frameCount = AVAudioFrameCount(duration * sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioError.conversionFailed
        }
        audioFile.framePosition = startFrame
        try audioFile.read(into: buffer, frameCount: frameCount)

        let tempDir = FileManager.default.temporaryDirectory
        let chunkURL = tempDir.appendingPathComponent("chunk_\(index)_\(UUID().uuidString).wav")
        guard let outputFile = try? AVAudioFile(forWriting: chunkURL, settings: format.settings) else {
            throw AudioError.conversionFailed
        }
        try outputFile.write(from: buffer)
        return chunkURL
    }

    func cleanupChunks(_ chunks: [AudioChunk]) {
        for chunk in chunks {
            if chunk.startTime > 0 {
                try? FileManager.default.removeItem(at: chunk.fileURL)
            }
        }
    }
}
