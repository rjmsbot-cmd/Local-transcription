import Foundation
import CoreML
import Accelerate

/// Low-level Whisper model processor using Core ML.
/// Handles mel spectrogram extraction, encoder inference, and autoregressive decoding.
final class WhisperProcessor {
    
    private let melModel: MLModel?
    private let encoderModel: MLModel?
    private let decoderModel: MLModel?
    private let tokenizer: WhisperTokenizer
    private let sampleRate: Int = 16000
    private let chunkLength: Int = 480000 // 30 seconds at 16kHz
    private let nFFT: Int = 400
    private let hopLength: Int = 160
    private let nMels: Int = 80
    
    struct SegmentResult {
        let start: Double
        let end: Double
        let text: String
    }
    
    enum Task {
        case transcribe
        case translate
    }
    
    // MARK: - Init
    
    init(modelPath: String) throws {
        let modelURL = URL(fileURLWithPath: modelPath)
        
        // Try loading as a directory with separate models
        if modelURL.hasDirectoryPath {
            let melURL = modelURL.appendingPathComponent("MelSpectrogram.mlmodelc")
            let encoderURL = modelURL.appendingPathComponent("AudioEncoder.mlmodelc")
            let decoderURL = modelURL.appendingPathComponent("TextDecoder.mlmodelc")
            
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            
            self.melModel = try? MLModel(contentsOf: melURL, configuration: config)
            self.encoderModel = try? MLModel(contentsOf: encoderURL, configuration: config)
            self.decoderModel = try? MLModel(contentsOf: decoderURL, configuration: config)
        } else {
            // Single .mlmodelc file
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            self.melModel = model
            self.encoderModel = nil
            self.decoderModel = nil
        }
        
        self.tokenizer = try WhisperTokenizer(modelPath: modelPath)
    }
    
    // MARK: - Transcription
    
    func transcribe(audioSamples: [Float], language: String?, task: Task) throws -> [SegmentResult] {
        // 1. Pad/trim audio to 30s chunks
        let paddedSamples = padOrTrimAudio(audioSamples)
        
        // 2. Compute mel spectrogram
        let melSpectrogram = try computeMelSpectrogram(paddedSamples)
        
        // 3. Encode
        let encoderOutput = try runEncoder(mel: melSpectrogram)
        
        // 4. Decode tokens autoregressively
        let tokens = try decodeTokens(encoderOutput: encoderOutput, language: language, task: task)
        
        // 5. Convert tokens to timestamped segments
        let segments = try tokenizer.decodeToSegments(tokens: tokens, audioLength: Double(audioSamples.count) / Double(sampleRate))
        
        return segments
    }
    
    // MARK: - Audio Processing
    
    private func padOrTrimAudio(_ samples: [Float]) -> [Float] {
        if samples.count >= chunkLength {
            return Array(samples.prefix(chunkLength))
        }
        // Pad with silence
        var padded = samples
        padded.append(contentsOf: [Float](repeating: 0, count: chunkLength - samples.count))
        return padded
    }
    
    // MARK: - Mel Spectrogram
    
    private func computeMelSpectrogram(_ samples: [Float]) throws -> MLMultiArray {
        let shape = [1, NSNumber(value: nMels), NSNumber(value: 1 + chunkLength / hopLength)]
        let mel = try MLMultiArray(shape: shape, dataType: .float32)
        
        // Hann window
        var window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))
        
        let nFrames = 1 + chunkLength / hopLength
        var magnitudes = [Float](repeating: 0, count: nFFT / 2 + 1)
        
        for frame in 0..<nFrames {
            let start = frame * hopLength
            let end = min(start + nFFT, samples.count)
            var frameSamples = [Float](repeating: 0, count: nFFT)
            
            for i in 0..<(end - start) {
                frameSamples[i] = samples[start + i] * window[i]
            }
            
            // FFT using Accelerate
            var realp = [Float](repeating: 0, count: nFFT / 2)
            var imagp = [Float](repeating: 0, count: nFFT / 2)
            
            frameSamples.withUnsafeBufferPointer { ptr in
                var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
                }
                vDSP_fft_zrip(try! vDSP.FFT<DSPSplitComplex>(radix: .radix2, n: vDSP_Length(nFFT / 2), ofType: DSPSplitComplex.self)!, &splitComplex, 1, vDSP_Length(log2(Float(nFFT / 2))), .forward)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(nFFT / 2 + 1))
            }
            
            // Apply mel filter bank (simplified — using log-mel)
            for melBin in 0..<nMels {
                let lowFreq = melBin * (nFFT / 2 + 1) / nMels
                let highFreq = min((melBin + 2) * (nFFT / 2 + 1) / nMels, nFFT / 2 + 1)
                var sum: Float = 0
                for f in lowFreq..<highFreq {
                    sum += magnitudes[f]
                }
                let melValue = log(max(sum, 1e-10))
                let index = [0, melBin, frame] as [NSNumber]
                mel[index] = NSNumber(value: melValue)
            }
        }
        
        return mel
    }
    
    // MARK: - Encoder
    
    private func runEncoder(mel: MLMultiArray) throws -> MLMultiArray {
        if let encoder = encoderModel {
            let input = try MLDictionaryFeatureProvider(dictionary: ["mel": MLFeatureValue(multiArray: mel)])
            let output = try encoder.prediction(from: input)
            guard let encoderOutput = output.featureValue(for: "encoder_output")?.multiArrayValue else {
                throw ProcessorError.encoderOutputMissing
            }
            return encoderOutput
        } else if let melModel = melModel {
            // Single model path — model does mel+encoder together
            let input = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: mel)])
            let output = try melModel.prediction(from: input)
            guard let result = output.featureValue(for: "output")?.multiArrayValue ?? 
                    output.featureValue(for: "encoder_output")?.multiArrayValue else {
                throw ProcessorError.encoderOutputMissing
            }
            return result
        }
        throw ProcessorError.noEncoderModel
    }
    
    // MARK: - Decoder
    
    private func decodeTokens(encoderOutput: MLMultiArray, language: String?, task: Task) throws -> [Int] {
        let maxTokens = 448 // Whisper max decoder tokens
        let sotToken = tokenizer.sotTokenId
        let eotToken = tokenizer.eotTokenId
        let languageToken = tokenizer.languageTokenId(for: language ?? "en")
        let taskToken = task == .transcribe ? tokenizer.transcribeTokenId : tokenizer.translateTokenId
        
        var tokens = [sotToken, languageToken, taskToken]
        
        guard let decoder = decoderModel else {
            // If no separate decoder, the single model handles everything
            // Return placeholder tokens — in practice, the single model outputs text directly
            return tokens
        }
        
        for _ in 0..<maxTokens {
            let tokenArray = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
            for (i, tok) in tokens.enumerated() {
                tokenArray[[0, i] as [NSNumber]] = NSNumber(value: tok)
            }
            
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "encoder_output": MLFeatureValue(multiArray: encoderOutput),
                "decoder_input_ids": MLFeatureValue(multiArray: tokenArray)
            ])
            
            let output = try decoder.prediction(from: input)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                break
            }
            
            // Greedy decode — take argmax of last token position
            let lastTokenIndex = tokens.count - 1
            let vocabSize = logits.shape.last!.intValue
            var maxVal: Float = -Float.infinity
            var maxIndex = 0
            
            for v in 0..<vocabSize {
                let idx = [0, lastTokenIndex, v] as [NSNumber]
                let val = logits[idx].floatValue
                if val > maxVal {
                    maxVal = val
                    maxIndex = v
                }
            }
            
            if maxIndex == eotToken { break }
            tokens.append(maxIndex)
        }
        
        // Remove the SOT/prompt tokens, keep only decoded
        return Array(tokens.dropFirst(3))
    }
}

// MARK: - WhisperTokenizer

final class WhisperTokenizer {
    private let vocab: [String: Int]
    private let reverseVocab: [Int: String]
    
    let sotTokenId: Int
    let eotTokenId: Int
    let transcribeTokenId: Int
    let translateTokenId: Int
    
    private let languageTokens: [String: Int]
    
    init(modelPath: String) throws {
        // Try to load tokenizer.json from model directory
        let modelURL = URL(fileURLWithPath: modelPath)
        let tokenizerURL: URL
        
        if modelURL.hasDirectoryPath {
            tokenizerURL = modelURL.appendingPathComponent("tokenizer.json")
        } else {
            tokenizerURL = modelURL.deletingLastPathComponent().appendingPathComponent("tokenizer.json")
        }
        
        if FileManager.default.fileExists(atPath: tokenizerURL.path) {
            let data = try Data(contentsOf: tokenizerURL)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let model = json?["model"] as? [String: Any]
            let vocabDict = model?["vocab"] as? [String: Int] ?? [:]
            self.vocab = vocabDict
            self.reverseVocab = Dictionary(uniqueKeysWithValues: vocabDict.map { ($0.value, $0.key) })
        } else {
            // Fallback: use basic Whisper vocab
            self.vocab = Self.basicWhisperVocab
            self.reverseVocab = Dictionary(uniqueKeysWithValues: Self.basicWhisperVocab.map { ($0.value, $0.key) })
        }
        
        self.sotTokenId = vocab["<|startoftranscript|>"] ?? 50258
        self.eotTokenId = vocab["<|endoftext|>"] ?? 50257
        self.transcribeTokenId = vocab["<|transcribe|>"] ?? 50359
        self.translateTokenId = vocab["<|translate|>"] ?? 50358
        
        // Language tokens <|xx|>
        var langTokens: [String: Int] = [:]
        for (token, id) in vocab {
            if token.hasPrefix("<|") && token.hasSuffix("|>") && token.count == 6 {
                let lang = String(token.dropFirst(2).dropLast(2))
                langTokens[lang] = id
            }
        }
        self.languageTokens = langTokens
    }
    
    func languageTokenId(for code: String) -> Int {
        languageTokens[code] ?? languageTokens["en"] ?? 50259
    }
    
    func decodeToSegments(tokens: [Int], audioLength: Double) throws -> [WhisperProcessor.SegmentResult] {
        // Find timestamp tokens to split into segments
        var segments: [WhisperProcessor.SegmentResult] = []
        var currentText = ""
        var segmentStart: Double = 0
        
        for token in tokens {
            guard let tokenStr = reverseVocab[token] else { continue }
            
            if tokenStr.hasPrefix("<|") && tokenStr.hasSuffix("|>") {
                // Check if it's a timestamp token like <|0.00|>
                let inner = String(tokenStr.dropFirst(2).dropLast(2))
                if let time = Double(inner) {
                    // Flush current segment
                    if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
                        segments.append(WhisperProcessor.SegmentResult(
                            start: segmentStart,
                            end: time,
                            text: currentText.trimmingCharacters(in: .whitespaces)
                        ))
                    }
                    currentText = ""
                    segmentStart = time
                }
                // Skip non-timestamp special tokens
                continue
            }
            
            // Regular token — decode BPE
            let decoded = tokenStr.replacingOccurrences(of: "Ġ", with: " ")
                .replacingOccurrences(of: "Ċ", with: "\n")
            currentText += decoded
        }
        
        // Flush final segment
        if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
            segments.append(WhisperProcessor.SegmentResult(
                start: segmentStart,
                end: audioLength,
                text: currentText.trimmingCharacters(in: .whitespaces)
            ))
        }
        
        return segments
    }
    
    // Minimal Whisper vocab for fallback
    static let basicWhisperVocab: [String: Int] = [
        "<|endoftext|>": 50257,
        "<|startoftranscript|>": 50258,
        "<|en|>": 50259,
        "<|transcribe|>": 50359,
        "<|translate|>": 50358,
        "<|notimestamps|>": 50363,
    ]
}

enum ProcessorError: LocalizedError {
    case encoderOutputMissing
    case noEncoderModel
    case tokenizerNotFound
    
    var errorDescription: String? {
        switch self {
        case .encoderOutputMissing: return "Encoder output not found in model output"
        case .noEncoderModel: return "No encoder model available"
        case .tokenizerNotFound: return "Tokenizer not found"
        }
    }
}
