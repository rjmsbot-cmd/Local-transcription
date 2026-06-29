import Foundation
import CoreML
import Accelerate

struct WhisperSegment {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct WhisperResult {
    let text: String
    let segments: [WhisperSegment]
}

class WhisperProcessor {
    private var model: MLModel?
    private let nFFT = 400
    private let hopLength = 160
    private let nMels = 80
    private let sampleRate: Double = 16000
    private let chunkSize = 30 * 16000

    func loadModel(path: String) async throws {
        let url = URL(fileURLWithPath: path)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try await MLModel(contentsOf: url, configuration: config)
    }

    func loadModelFromBundle(name: String) async throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw WhisperError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try await MLModel(contentsOf: url, configuration: config)
    }

    func transcribe(samples: [Float], language: String? = nil) async throws -> WhisperResult {
        guard let model = model else { throw WhisperError.modelNotLoaded }

        let melSpectrogram = computeMelSpectrogram(samples: samples)
        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: nMels), NSNumber(value: melSpectrogram.count / nMels)], dataType: .float32)
        for (i, val) in melSpectrogram.enumerated() { inputArray[i] = NSNumber(value: val) }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["mel_spectrogram": MLFeatureValue(multiArray: inputArray)])
        let output = try await model.prediction(from: provider)

        var text = ""
        if let outputArray = output.featureValue(for: "tokens")?.multiArrayValue {
            text = decodeTokens(outputArray)
        } else if let outputString = output.featureValue(for: "transcription")?.stringValue {
            text = outputString
        } else {
            for name in output.featureNames {
                if let s = output.featureValue(for: name)?.stringValue { text = s; break }
                if let a = output.featureValue(for: name)?.multiArrayValue { text = decodeTokens(a); break }
            }
        }

        let duration = Double(samples.count) / sampleRate
        let segments = createSegments(from: text, duration: duration)
        return WhisperResult(text: text, segments: segments)
    }

    private func computeMelSpectrogram(samples: [Float]) -> [Float] {
        let nSamples = samples.count
        let nFrames = (nSamples - nFFT) / hopLength + 1
        guard nFrames > 0 else { return [] }

        var melSpectrogram = [Float](repeating: 0, count: nMels * nFrames)
        var window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Float(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return melSpectrogram }

        defer { vDSP_destroy_fftsetup(fftSetup) }

        for frame in 0..<nFrames {
            let offset = frame * hopLength
            var windowedSamples = [Float](repeating: 0, count: nFFT)
            vDSP_vmul(samples + offset, 1, window, 1, &windowedSamples, 1, vDSP_Length(nFFT))

            var realp = [Float](repeating: 0, count: nFFT / 2)
            var imagp = [Float](repeating: 0, count: nFFT / 2)
            var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)

            windowedSamples.withUnsafeBufferPointer { ptr in
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
                }
            }

            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

            var magnitudes = [Float](repeating: 0, count: nFFT / 2 + 1)
            vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(nFFT / 2 + 1))

            for mel in 0..<nMels {
                let lowFreq = Float(mel) * Float(sampleRate / 2) / Float(nMels)
                let highFreq = Float(mel + 1) * Float(sampleRate / 2) / Float(nMels)
                let lowBin = Int(lowFreq * Float(nFFT) / Float(sampleRate))
                let highBin = min(Int(highFreq * Float(nFFT) / Float(sampleRate)), nFFT / 2)
                var sum: Float = 0
                if highBin > lowBin {
                    vDSP_sve(magnitudes + lowBin, 1, &sum, vDSP_Length(highBin - lowBin))
                }
                melSpectrogram[mel * nFrames + frame] = log(max(sum, 1e-10))
            }
        }
        return melSpectrogram
    }

    private func decodeTokens(_ array: MLMultiArray) -> String {
        let count = array.count
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for i in 0..<count {
            let v = array[i].intValue
            if v > 0 && v < 1000 { bytes.append(UInt8(min(v, 255))) }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func createSegments(from text: String, duration: TimeInterval) -> [WhisperSegment] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !sentences.isEmpty else {
            return [WhisperSegment(start: 0, end: duration, text: text)]
        }
        let segDur = duration / Double(sentences.count)
        return sentences.enumerated().map { i, s in
            WhisperSegment(start: Double(i) * segDur, end: Double(i + 1) * segDur, text: s.trimmingCharacters(in: .whitespaces))
        }
    }
}

enum WhisperError: Error {
    case modelNotFound
    case modelNotLoaded
}
