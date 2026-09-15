import Accelerate
import Foundation

/// @unchecked Sendable: the cross-thread hand-off is owned by the exchange; every field here
/// is consumer-only, reached under the broker's snapshot lock (or single-threaded), never
/// from the audio thread.
final class AudioSpectrumProcessor: AudioSpectrumAnalyzing, @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var fftSize: Int = 2048
        // dB→[0,1] window (narrow 32 dB for bar contrast).
        var minDB: Float = -56
        var maxDB: Float = -24
        var gain: Float = 0.8
        var noiseFloor: Float = 0.002
        var attackTime: Float = 0.045
        // Release 0.090: more per-frame motion without single-frame flicker.
        var releaseTime: Float = 0.090
        var sampleRate: Float = 48_000
        /// Log-spaced band edges (linear packing left most bars flat).
        var lowFrequency: Float = 25
        var highFrequency: Float = 16_000
        /// Treble EQ: `(fCenter / lowFrequency)^eqExponent` (0 disables).
        var eqExponent: Float = 0.30
    }

    private struct Band {
        let range: Range<Int>
        let boost: Float
    }

    private let configuration: Configuration
    private let fftSetup: vDSP.FFT<DSPSplitComplex>?

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

    private var lastAnalyzedTotal = 0
    private var lastAnalysisNanos: UInt64 = 0

    /// Pull cadence cap: at most one FFT per 1/120 s regardless of caller count.
    static let minAnalysisIntervalNanos: UInt64 = 8_333_333

    #if DEBUG
    var afterWindowCopyForTesting: (() -> Void)?
    #endif

    init(configuration: Configuration = Configuration()) {
        var resolved = configuration
        if resolved.fftSize < 2 || !Self.isPowerOfTwo(resolved.fftSize) {
            resolved.fftSize = 2048
        }
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
        self.compressedBins = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        self.leftOutput = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        self.rightOutput = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        self.previousLeft = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        self.previousRight = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        self.bands = Self.logBands(configuration: resolved)
        self.exchange = AudioSpectrumWindowExchange(windowSize: resolved.fftSize)
    }

    private static func logBands(configuration: Configuration) -> [Band] {
        let halfBins = configuration.fftSize / 2
        let binWidth = configuration.sampleRate / Float(configuration.fftSize)
        let nyquist = configuration.sampleRate * 0.5
        let low = max(min(configuration.lowFrequency, nyquist * 0.5), binWidth)
        let high = max(min(configuration.highFrequency, nyquist * 0.98), low * 2)
        let ratio = high / low
        let count = AudioSpectrumFrame.binCount

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

    func process(left: [Float], right: [Float], timestampNanos: UInt64) -> AudioSpectrumFrame {
        ingest(left: left, right: right, timestampNanos: timestampNanos)
        // Discarding the returned frame: it carries the seal's timestamp, and this seam must stamp the caller's even when an ingest with no samples sealed nothing.
        _ = analyze()
        return AudioSpectrumFrame(
            validatedLeft: leftOutput,
            validatedRight: rightOutput,
            timestampNanos: timestampNanos
        )
    }

    func ingest(left: [Float], right: [Float], timestampNanos: UInt64) {
        exchange.publish(left: left, right: right, timestampNanos: timestampNanos)
    }

    /// nil means "cached frame is still current". Caller provides mutual exclusion (broker snapshot lock).
    func analyzeIfDue(nowNanos: UInt64) -> AudioSpectrumFrame? {
        let cursor = exchange.publishedCursor()
        guard cursor.totalSamples > lastAnalyzedTotal else { return nil }
        guard lastAnalysisNanos == 0 || nowNanos &- lastAnalysisNanos >= Self.minAnalysisIntervalNanos else {
            return nil
        }
        lastAnalysisNanos = nowNanos
        return analyze()
    }

    private func analyze() -> AudioSpectrumFrame? {
        let cursor = exchange.copySealedWindow(into: &leftInput, and: &rightInput)
        #if DEBUG
        afterWindowCopyForTesting?()
        #endif
        // Drop this frame if the producer ran more than a full history past this window's start; smoothing state is untouched.
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
        // Clamp the hop to the retained history: a hop of hundreds of thousands of samples drives both coefficients to ~0 — a spectrum pop on resume.
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

        for index in 0..<AudioSpectrumFrame.binCount {
            let mean = compressedBins[index]
            let target: Float
            if mean <= configuration.noiseFloor || !mean.isFinite {
                target = 0
            } else {
                let magnitude = max(mean * configuration.gain, configuration.noiseFloor)
                let db = 20 * log10f(magnitude)
                // maxDB is the 1.0 reference, not a ceiling: louder content keeps the same slope
                // so the web visualizer sees the above-1 values its contract allows.
                target = max((db - configuration.minDB) / dbRange, 0)
            }

            let coefficient = target > previous[index] ? attackCoefficient : releaseCoefficient
            let smoothed = previous[index] + coefficient * (target - previous[index])
            output[index] = max(smoothed, 0)
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
