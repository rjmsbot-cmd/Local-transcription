import Foundation

/// Transcription performance policy (Settings → Rendimiento).
///
/// WhisperKit decodes a long audio by splitting it into VAD-based chunks
/// (up to 30s each) and processing `concurrentWorkerCount` of them at a
/// time. Its default on non-macOS is **4** — the library's own guidance is
/// that more than 4 concurrent workers can regress on devices where the
/// Apple Neural Engine is the bottleneck (CoreML calls serialize on the
/// ANE). But part of each chunk's work (mel-spectrogram, VAD, tokenization,
/// logits filtering) runs on the CPU and *does* parallelize, so on devices
/// with many cores throwing more workers at it can still help.
enum PerformanceSettings {

    /// "Máxima velocidad" — use every available CPU core for chunk decoding.
    /// Default off because it is a trade-off: it dedicates more resources,
    /// but can regress on ANE-bound workloads. Backed by UserDefaults so the
    /// Settings toggle reads/writes the same value.
    static var maxSpeedMode: Bool {
        get { UserDefaults.standard.bool(forKey: PerformanceSettings.maxSpeedModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: PerformanceSettings.maxSpeedModeKey) }
    }

    static let maxSpeedModeKey = "perf.maxSpeedMode"

    /// Chunk concurrency handed to `DecodingOptions.concurrentWorkerCount`.
    /// - Default: 4 (WhisperKit's tested iOS sweet spot).
    /// - "Máxima velocidad": every core on the device (literally "dedicate
    ///   more resources").
    static var concurrentWorkerCount: Int {
        maxSpeedMode ? max(4, ProcessInfo.processInfo.activeProcessorCount) : 4
    }
}