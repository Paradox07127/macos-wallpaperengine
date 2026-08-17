import Accelerate
import Foundation

/// Alloc-free stereo FFT → 64 log-spaced bins with treble EQ + attack/release (WPE-style).
/// Input arrives through `ingest` into an `AudioSpectrumWindowExchange` (audio thread, no
/// FFT); analysis is pull-driven via `analyzeIfDue`, so FFT rate follows consumer demand,
/// capped at 120 Hz.
/// @unchecked Sendable: the cross-thread sample hand-off is owned by the exchange, and
/// every field declared here is consumer-only — reached from `process`/`analyzeIfDue`
/// under the broker's snapshot lock (or single-threaded), never from the audio thread.
final class AudioSpectrumProcessor: AudioSpectrumAnalyzing, @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var fftSize: Int = 2048
        var binCount: Int = 64
        // dB→[0,1] window calibrated to WPE oracle 3470764447 (narrow 32 dB for bar contrast).
        var minDB: Float = -56
        var maxDB: Float = -24
        var gain: Float = 0.8
        var noiseFloor: Float = 0.002
        var attackTime: Float = 0.045
        // Release 0.090 (was 0.180): more per-frame motion without single-frame flicker.
        var releaseTime: Float = 0.090
        var sampleRate: Float = 48_000
        /// Log-spaced band edges (linear packing left most bars flat).
        var lowFrequency: Float = 25
        var highFrequency: Float = 16_000
        /// Treble EQ: `(fCenter / lowFrequency)^eqExponent` (0 disables).
        var eqExponent: Float = 0.30
    }

    /// Precomputed magnitude range + EQ boost for one output band.
    private struct Band {
        let range: Range<Int>
        let boost: Float
    }

    private let configuration: Configuration
    private let fftSetup: vDSP.FFT<DSPSplitComplex>?

    /// Smoothing coeffs depend on hop size — recomputed when hop changes.
    private var attackCoefficient: Float = 1
    private var releaseCoefficient: Float = 1
    private var lastHopSize: Int = 0

    private var window: [Float]
    /// `1/Σ window` — unnormalized vDSP magnitudes otherwise saturate full-scale audio to 1.0.
    private let inverseWindowSum: Float
    private var leftInput: [Float]
    private var rightInput: [Float]
    private var windowedInput: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudes: [Float]
    private var compressedBins: [Float]
    private var leftOutput: [Float]
    private var rightOutput: [Float]
    private var previousLeft: [Float]
    private var previousRight: [Float]
    private let bands: [Band]

    // MARK: - Sample hand-off (audio IO thread produces, snapshot pull consumes)

    private let exchange: AudioSpectrumWindowExchange

    /// Consumer-side analysis state; mutual exclusion is the caller's (broker lock).
    private var lastAnalyzedTotal = 0
    private var lastAnalysisNanos: UInt64 = 0

    /// Pull cadence cap: at most one FFT per 1/120 s regardless of caller count.
    static let minAnalysisIntervalNanos: UInt64 = 8_333_333

    #if DEBUG
    /// Test seam: runs between taking the sealed window and the staleness recheck so a
    /// test can interleave producer writes deterministically.
    var afterWindowCopyForTesting: (() -> Void)?
    #endif

    init(configuration: Configuration = Configuration()) {
        var resolved = configuration
        if resolved.fftSize < 2 || !Self.isPowerOfTwo(resolved.fftSize) {
            resolved.fftSize = 2048
        }
        resolved.binCount = AudioSpectrumFrame.binCount
        if resolved.maxDB <= resolved.minDB {
            resolved.maxDB = resolved.minDB + 1
        }
        if resolved.sampleRate <= 0 {
            resolved.sampleRate = 48_000
        }

        self.configuration = resolved
        let log2n = vDSP_Length(log2(Double(resolved.fftSize)))
        self.fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)

        var hann = [Float](repeating: 0, count: resolved.fftSize)
        vDSP_hann_window(&hann, vDSP_Length(resolved.fftSize), Int32(vDSP_HANN_NORM))
        self.window = hann
        self.inverseWindowSum = 1 / max(hann.reduce(0, +), 1)
        self.leftInput = [Float](repeating: 0, count: resolved.fftSize)
        self.rightInput = [Float](repeating: 0, count: resolved.fftSize)
        self.windowedInput = [Float](repeating: 0, count: resolved.fftSize)
        self.realBuffer = [Float](repeating: 0, count: resolved.fftSize / 2)
        self.imagBuffer = [Float](repeating: 0, count: resolved.fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: resolved.fftSize / 2)
        self.compressedBins = [Float](repeating: 0, count: resolved.binCount)
        self.leftOutput = [Float](repeating: 0, count: resolved.binCount)
        self.rightOutput = [Float](repeating: 0, count: resolved.binCount)
        self.previousLeft = [Float](repeating: 0, count: resolved.binCount)
        self.previousRight = [Float](repeating: 0, count: resolved.binCount)
        self.bands = Self.logBands(configuration: resolved)
        self.exchange = AudioSpectrumWindowExchange(windowSize: resolved.fftSize)
    }

    /// Build log-spaced bands with treble EQ; each spans ≥1 bin; edges clamped.
    private static func logBands(configuration: Configuration) -> [Band] {
        let halfBins = configuration.fftSize / 2
        let binWidth = configuration.sampleRate / Float(configuration.fftSize)
        let nyquist = configuration.sampleRate * 0.5
        let low = max(min(configuration.lowFrequency, nyquist * 0.5), binWidth)
        let high = max(min(configuration.highFrequency, nyquist * 0.98), low * 2)
        let ratio = high / low
        let count = configuration.binCount

        return (0..<count).map { band in
            let fStart = low * powf(ratio, Float(band) / Float(count))
            let fEnd = low * powf(ratio, Float(band + 1) / Float(count))
            let start = min(max(Int(fStart / binWidth), 1), halfBins - 1)
            let end = min(max(Int((fEnd / binWidth).rounded()), start + 1), halfBins)
            let center = sqrtf(fStart * fEnd)
            let boost = configuration.eqExponent == 0
                ? Float(1)
                : min(powf(center / low, configuration.eqExponent), 16)
            return Band(range: start..<end, boost: boost)
        }
    }

    /// Immediate ingest + analysis in one call (single-threaded test/oracle seam;
    /// capture pulls via `analyzeIfDue`).
    func process(left: [Float], right: [Float], timestampNanos: UInt64) -> AudioSpectrumFrame {
        ingest(left: left, right: right, timestampNanos: timestampNanos)
        // Discarding the returned frame: it carries the seal's timestamp, and this seam
        // must stamp the caller's even when an ingest with no samples sealed nothing.
        _ = analyze()
        return AudioSpectrumFrame(
            validatedLeft: leftOutput,
            validatedRight: rightOutput,
            timestampNanos: timestampNanos
        )
    }

    /// Audio-thread entry: hand the callback's samples to the exchange. No allocation,
    /// no FFT, no waiting on a lock — analysis happens on consumer pull.
    func ingest(left: [Float], right: [Float], timestampNanos: UInt64) {
        exchange.publish(left: left, right: right, timestampNanos: timestampNanos)
    }

    /// Consumer pull: run one analysis if new samples arrived since the last one and
    /// the cadence cap allows; nil means "cached frame is still current". Caller
    /// provides mutual exclusion (broker snapshot lock).
    func analyzeIfDue(nowNanos: UInt64) -> AudioSpectrumFrame? {
        let cursor = exchange.publishedCursor()
        guard cursor.totalSamples > lastAnalyzedTotal else { return nil }
        guard lastAnalysisNanos == 0 || nowNanos &- lastAnalysisNanos >= Self.minAnalysisIntervalNanos else {
            return nil
        }
        lastAnalysisNanos = nowNanos
        return analyze()
    }

    /// One analysis of the latest sealed window. The spectrum math (Hann window, FFT,
    /// normalization, band reduction, smoothing) is unchanged from the push-driven
    /// version — only which windows get analyzed changed. Returns nil when the window
    /// taken is already stale beyond the retained history (see below).
    private func analyze() -> AudioSpectrumFrame? {
        let cursor = exchange.copySealedWindow(into: &leftInput, and: &rightInput)
        #if DEBUG
        afterWindowCopyForTesting?()
        #endif
        // The copy runs under the exchange lock, so the window is always exactly one
        // generation. It can still be old: a producer that has since run more than a
        // full history (~170 ms at 48 kHz) past this window's start means the consumer
        // was descheduled that long, so drop this frame and let the next pull take the
        // fresh seal. Smoothing state is untouched, so nothing is lost but one interval.
        let published = exchange.publishedCursor().totalSamples
        guard published - (cursor.totalSamples - configuration.fftSize) <= exchange.historyCapacity else {
            return nil
        }
        updateSmoothingIfNeeded(hopSize: cursor.totalSamples - lastAnalyzedTotal)
        lastAnalyzedTotal = cursor.totalSamples

        processChannel(input: leftInput, previous: &previousLeft, output: &leftOutput)
        processChannel(input: rightInput, previous: &previousRight, output: &rightOutput)

        return AudioSpectrumFrame(
            validatedLeft: leftOutput,
            validatedRight: rightOutput,
            timestampNanos: cursor.timestampNanos
        )
    }

    private func updateSmoothingIfNeeded(hopSize: Int) {
        // A consumer that stopped pulling (suspended, hibernated, App-Napped)
        // leaves `lastAnalyzedTotal` arbitrarily far behind the producer, and a
        // hop of hundreds of thousands of samples drives both coefficients to
        // ~0 — no smoothing at all on the first frame back, i.e. a spectrum pop
        // on resume. The window itself is one coherent generation, so clamp the
        // hop to the retained history: gaps larger than that carry no usable
        // relation to the retained audio anyway.
        let clamped = Swift.min(hopSize, exchange.historyCapacity)
        let hop = clamped > 0 ? clamped : configuration.fftSize
        guard hop != lastHopSize else { return }
        lastHopSize = hop
        attackCoefficient = Self.smoothingCoefficient(
            time: configuration.attackTime,
            stepSize: hop,
            sampleRate: configuration.sampleRate
        )
        releaseCoefficient = Self.smoothingCoefficient(
            time: configuration.releaseTime,
            stepSize: hop,
            sampleRate: configuration.sampleRate
        )
    }

    private func processChannel(input: [Float], previous: inout [Float], output: inout [Float]) {
        guard let fftSetup else {
            for index in output.indices { output[index] = 0 }
            copyInPlace(output, into: &previous)
            return
        }

        vDSP.multiply(input, window, result: &windowedInput)

        windowedInput.withUnsafeBufferPointer { inputPointer in
            inputPointer.baseAddress!.withMemoryRebound(
                to: DSPComplex.self,
                capacity: configuration.fftSize / 2
            ) { complexPointer in
                realBuffer.withUnsafeMutableBufferPointer { realPointer in
                    imagBuffer.withUnsafeMutableBufferPointer { imagPointer in
                        var split = DSPSplitComplex(
                            realp: realPointer.baseAddress!,
                            imagp: imagPointer.baseAddress!
                        )
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(configuration.fftSize / 2))
                        fftSetup.forward(input: split, output: &split)
                        vDSP.absolute(split, result: &magnitudes)
                    }
                }
            }
        }

        // Normalize raw FFT magnitudes before dB mapping (see inverseWindowSum).
        vDSP.multiply(inverseWindowSum, magnitudes, result: &magnitudes)

        compressMagnitudesIntoBins()
        normalizeAndSmooth(previous: &previous, output: &output)
    }

    private func compressMagnitudesIntoBins() {
        for (bin, band) in bands.enumerated() {
            var sum: Float = 0
            for index in band.range {
                sum += magnitudes[index]
            }
            compressedBins[bin] = band.boost * sum / Float(band.range.count)
        }
    }

    private func normalizeAndSmooth(previous: inout [Float], output: inout [Float]) {
        let dbRange = configuration.maxDB - configuration.minDB

        for index in 0..<configuration.binCount {
            let mean = compressedBins[index]
            let target: Float
            if mean <= configuration.noiseFloor || !mean.isFinite {
                target = 0
            } else {
                let magnitude = max(mean * configuration.gain, configuration.noiseFloor)
                let db = 20 * log10f(magnitude)
                target = min(max((db - configuration.minDB) / dbRange, 0), 1)
            }

            let coefficient = target > previous[index] ? attackCoefficient : releaseCoefficient
            let smoothed = previous[index] + coefficient * (target - previous[index])
            output[index] = min(max(smoothed, 0), 1)
        }

        copyInPlace(output, into: &previous)
    }

    /// Element-wise copy — assignment would alias and COW-alloc on next mutation.
    private func copyInPlace(_ source: [Float], into destination: inout [Float]) {
        let count = min(source.count, destination.count)
        for index in 0..<count {
            destination[index] = source[index]
        }
    }

    private static func smoothingCoefficient(time: Float, stepSize: Int, sampleRate: Float) -> Float {
        guard time > 0, sampleRate > 0, stepSize > 0 else { return 1 }
        let duration = Float(stepSize) / sampleRate
        return min(max(1 - expf(-duration / time), 0), 1)
    }

    private static func isPowerOfTwo(_ value: Int) -> Bool {
        value > 0 && (value & (value - 1)) == 0
    }
}
