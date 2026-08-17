import Accelerate
import Foundation
import os

/// Alloc-free stereo FFT → 64 log-spaced bins with treble EQ + attack/release (WPE-style).
/// Input arrives through `ingest` into a ring (audio thread, no FFT); analysis is
/// pull-driven via `analyzeIfDue`, so FFT rate follows consumer demand, capped at 120 Hz.
/// @unchecked Sendable: producer fields are audio-IO-thread-only, analysis fields run
/// under the broker snapshot lock (or single-threaded direct `process` use), and the
/// `ringCursor` lock publishes the write position between them.
///
/// The lock covers the CURSOR, not the sample storage: the consumer copies its
/// window out of `leftRing`/`rightRing` unsynchronized while the producer may be
/// writing. Aligned 32-bit stores do not tear, so the observable failure is a
/// window mixing two generations, which the post-copy lap check detects and
/// discards. That is detection, not prevention — it stays a formal data race
/// and Thread Sanitizer will say so. Removing it needs ownership transfer
/// (SPSC hand-off or sealed double buffers), not a bigger ring; see the
/// memory/CPU backlog.
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

    // MARK: - Ring ingestion (SPSC: audio IO thread produces, snapshot pull consumes)

    private struct RingCursor {
        var totalSamples: Int
        var timestampNanos: UInt64
    }

    /// Producer→consumer handoff of (samples written, host time). The unfair lock
    /// stands in for a release/acquire atomic pair — deployment target 14.6 predates
    /// the Synchronization module. Each critical section is a single store or load.
    private let ringCursor = OSAllocatedUnfairLock(initialState: RingCursor(totalSamples: 0, timestampNanos: 0))
    /// Running sample count, touched only by the single producer (audio IO thread).
    private var producerTotal = 0
    private let ringCapacity: Int
    private let ringMask: Int
    /// Raw buffers so concurrent producer writes / consumer reads don't trip Swift's
    /// dynamic exclusivity checks (overlapping Array withUnsafe… accesses would).
    private let leftRing: UnsafeMutableBufferPointer<Float>
    private let rightRing: UnsafeMutableBufferPointer<Float>

    /// Consumer-side analysis state; mutual exclusion is the caller's (broker lock).
    private var lastAnalyzedTotal = 0
    private var lastAnalysisNanos: UInt64 = 0

    /// Pull cadence cap: at most one FFT per 1/120 s regardless of caller count.
    static let minAnalysisIntervalNanos: UInt64 = 8_333_333

    #if DEBUG
    /// Test seam: runs between the window copy and the lap recheck so a test can
    /// interleave producer writes deterministically.
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

        // 4× the window (power of two): the analyzed region trails the producer by
        // ≥ 3×fftSize samples, so in-flight callback writes never touch it.
        let capacity = resolved.fftSize * 4
        self.ringCapacity = capacity
        self.ringMask = capacity - 1
        self.leftRing = .allocate(capacity: capacity)
        self.rightRing = .allocate(capacity: capacity)
        self.leftRing.initialize(repeating: 0)
        self.rightRing.initialize(repeating: 0)
    }

    deinit {
        leftRing.deallocate()
        rightRing.deallocate()
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
        let total = ringCursor.withLock { $0.totalSamples }
        // Single caller thread means no concurrent producer, so the lap discard
        // cannot trip; the fallback only satisfies the optional.
        return analyze(total: total, timestampNanos: timestampNanos)
            ?? AudioSpectrumFrame(validatedLeft: leftOutput, validatedRight: rightOutput, timestampNanos: timestampNanos)
    }

    /// Audio-thread entry: copy the callback's samples into the ring and publish the
    /// cursor. No allocation, no FFT — analysis happens on consumer pull.
    /// Shorter channel zero-pads (HAL always delivers matched counts).
    func ingest(left: [Float], right: [Float], timestampNanos: UInt64) {
        let frameCount = max(left.count, right.count)
        guard frameCount > 0 else { return }
        // Oversized batch (never from HAL): only the freshest ringCapacity samples matter.
        let dropped = max(frameCount - ringCapacity, 0)
        writeRing(leftRing, samples: left, from: dropped, count: frameCount - dropped, at: producerTotal + dropped)
        writeRing(rightRing, samples: right, from: dropped, count: frameCount - dropped, at: producerTotal + dropped)
        producerTotal += frameCount
        let published = RingCursor(totalSamples: producerTotal, timestampNanos: timestampNanos)
        ringCursor.withLock { $0 = published }
    }

    /// Consumer pull: run one analysis if new samples arrived since the last one and
    /// the cadence cap allows; nil means "cached frame is still current". Caller
    /// provides mutual exclusion (broker snapshot lock).
    func analyzeIfDue(nowNanos: UInt64) -> AudioSpectrumFrame? {
        let cursor = ringCursor.withLock { $0 }
        guard cursor.totalSamples > lastAnalyzedTotal else { return nil }
        guard lastAnalysisNanos == 0 || nowNanos &- lastAnalysisNanos >= Self.minAnalysisIntervalNanos else {
            return nil
        }
        lastAnalysisNanos = nowNanos
        return analyze(total: cursor.totalSamples, timestampNanos: cursor.timestampNanos)
    }

    /// One analysis of the latest window. The spectrum math (Hann window, FFT,
    /// normalization, band reduction, smoothing) is unchanged from the push-driven
    /// version — only which windows get analyzed changed. Returns nil when the
    /// copied window was lapped by the producer (torn — see below).
    private func analyze(total: Int, timestampNanos: UInt64) -> AudioSpectrumFrame? {
        copyWindow(from: leftRing, upTo: total, into: &leftInput)
        copyWindow(from: rightRing, upTo: total, into: &rightInput)
        #if DEBUG
        afterWindowCopyForTesting?()
        #endif
        // Recheck the write cursor after the copy: if the producer advanced past
        // windowStart + capacity, the window's oldest samples were overwritten
        // mid-copy (consumer stalled longer than the ring covers, ~170 ms at
        // 48 kHz) and the copy mixes generations. Discard rather than render
        // torn data; smoothing state is untouched so the next pull retries.
        let writeTotal = ringCursor.withLock { $0.totalSamples }
        guard writeTotal - (total - configuration.fftSize) <= ringCapacity else { return nil }
        updateSmoothingIfNeeded(hopSize: total - lastAnalyzedTotal)
        lastAnalyzedTotal = total

        processChannel(input: leftInput, previous: &previousLeft, output: &leftOutput)
        processChannel(input: rightInput, previous: &previousRight, output: &rightOutput)

        return AudioSpectrumFrame(
            validatedLeft: leftOutput,
            validatedRight: rightOutput,
            timestampNanos: timestampNanos
        )
    }

    private func updateSmoothingIfNeeded(hopSize: Int) {
        // A consumer that stopped pulling (suspended, hibernated, App-Napped)
        // leaves `lastAnalyzedTotal` arbitrarily far behind the producer, and a
        // hop of hundreds of thousands of samples drives both coefficients to
        // ~0 — no smoothing at all on the first frame back, i.e. a spectrum pop
        // on resume. The window itself is fresh (the lap guard rejects torn
        // ones), so clamp the hop to the ring: gaps larger than that carry no
        // usable relation to the retained audio anyway.
        let clamped = Swift.min(hopSize, ringCapacity)
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

    private func writeRing(
        _ ring: UnsafeMutableBufferPointer<Float>,
        samples: [Float],
        from sourceStart: Int,
        count: Int,
        at ringStart: Int
    ) {
        for offset in 0..<count {
            let sourceIndex = sourceStart + offset
            ring[(ringStart + offset) & ringMask] = sourceIndex < samples.count ? samples[sourceIndex] : 0
        }
    }

    /// Ring → contiguous FFT window (last `target.count` samples ending at `total`),
    /// sanitizing non-finite samples like the old sliding append did.
    private func copyWindow(
        from ring: UnsafeMutableBufferPointer<Float>,
        upTo total: Int,
        into target: inout [Float]
    ) {
        let windowStart = total - target.count
        target.withUnsafeMutableBufferPointer { buffer in
            for offset in 0..<buffer.count {
                let absolute = windowStart + offset
                if absolute < 0 {
                    buffer[offset] = 0
                } else {
                    let sample = ring[absolute & ringMask]
                    buffer[offset] = sample.isFinite ? sample : 0
                }
            }
        }
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
