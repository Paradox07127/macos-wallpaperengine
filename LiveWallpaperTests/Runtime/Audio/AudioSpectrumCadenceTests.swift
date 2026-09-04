import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Audio spectrum pull cadence")
struct AudioSpectrumCadenceTests {
    private static let interval = AudioSpectrumProcessor.minAnalysisIntervalNanos

    @Test("Ring wrap-around: analysis sees the last window, in order")
    func ringWrapAroundPreservesWindow() {
        let processor = AudioSpectrumProcessor()
        // Push the write cursor to 7000 so the final 2048-sample window
        // (7000..<9048) crosses the 8192 ring boundary.
        let silence = [Float](repeating: 0, count: 500)
        for _ in 0..<14 {
            processor.ingest(left: silence, right: silence, timestampNanos: 1)
        }
        // Silence analysis: smoothing state stays zero, hop resets to 2048 below.
        #expect(processor.analyzeIfDue(nowNanos: Self.interval) != nil)

        let window = Self.orderSensitiveSignal(count: 2048)
        var offset = 0
        while offset < window.count {
            let chunk = Array(window[offset..<min(offset + 256, window.count)])
            processor.ingest(left: chunk, right: chunk, timestampNanos: 2)
            offset += 256
        }
        let wrapped = processor.analyzeIfDue(nowNanos: Self.interval * 3)

        // Oracle: fresh processor fed the same window contiguously (no wrap),
        // with the same hop (2048) and the same all-zero smoothing history.
        let oracle = AudioSpectrumProcessor()
        let expected = oracle.process(left: window, right: window, timestampNanos: 2)

        #expect(expected.left.contains { $0 > 0 })
        #expect(wrapped?.left == expected.left)
        #expect(wrapped?.right == expected.right)
    }

    @Test("Two pulls inside the cadence cap run one analysis")
    func cadenceGateDedupsPulls() {
        let processor = AudioSpectrumProcessor()
        let tone = Self.orderSensitiveSignal(count: 2048)
        processor.ingest(left: tone, right: tone, timestampNanos: 1)

        #expect(processor.analyzeIfDue(nowNanos: 1_000_000_000) != nil)

        // New samples arrived, but the second pull lands inside the cap.
        processor.ingest(left: tone, right: tone, timestampNanos: 2)
        #expect(processor.analyzeIfDue(nowNanos: 1_000_000_000 + Self.interval - 1) == nil)

        // Once the interval elapses, the pending samples are analyzed.
        #expect(processor.analyzeIfDue(nowNanos: 1_000_000_000 + Self.interval) != nil)
    }

    @Test("No new samples means no new analysis, at any interval")
    func noNewSamplesReturnsNil() {
        let processor = AudioSpectrumProcessor()
        #expect(processor.analyzeIfDue(nowNanos: 1) == nil)

        let tone = Self.orderSensitiveSignal(count: 2048)
        processor.ingest(left: tone, right: tone, timestampNanos: 1)
        #expect(processor.analyzeIfDue(nowNanos: 1_000_000_000) != nil)
        #expect(processor.analyzeIfDue(nowNanos: 60_000_000_000) == nil)
    }

    @Test("Broker generation advances only when a new spectrum is produced")
    func brokerTimestampTracksAnalyses() {
        let broker = AudioSpectrumBroker()
        let processor = AudioSpectrumProcessor()
        broker.attachAnalyzer(processor)

        let tone = Self.orderSensitiveSignal(count: 2048)
        processor.ingest(left: tone, right: tone, timestampNanos: 7)

        let first = broker.snapshot()
        #expect(first.timestampNanos == 7)
        #expect(first.left.contains { $0 > 0 })
        // No new samples: repeated snapshots return the cached frame unchanged.
        #expect(broker.snapshot() == first)

        // Detached: new samples no longer reach the cache.
        broker.attachAnalyzer(nil)
        processor.ingest(left: tone, right: tone, timestampNanos: 9)
        #expect(broker.snapshot().timestampNanos == 7)
    }

    @Test("Oversized ingest keeps only the freshest samples")
    func oversizedIngestKeepsTail() {
        let processor = AudioSpectrumProcessor()
        // 20k samples: loud noise everywhere except a silent 2048-sample tail.
        var oversized = Self.orderSensitiveSignal(count: 20_000)
        for index in (20_000 - 2048)..<20_000 {
            oversized[index] = 0
        }
        let frame = processor.process(left: oversized, right: oversized, timestampNanos: 1)
        #expect(frame.left.allSatisfy { $0 == 0 })

        // Control: the loud head alone is not silent, so the zeros above prove
        // the analysis window really is the tail.
        let control = AudioSpectrumProcessor().process(
            left: Array(oversized[0..<2048]),
            right: Array(oversized[0..<2048]),
            timestampNanos: 1
        )
        #expect(control.left.contains { $0 > 0 })
    }

    @Test("A producer lap during the window copy discards the analysis")
    func lapDuringCopyDiscardsAnalysis() {
        let processor = AudioSpectrumProcessor()
        let tone = Self.orderSensitiveSignal(count: 2048)
        processor.ingest(left: tone, right: tone, timestampNanos: 1)

        // Ring capacity is 4x2048 = 8192; writing 8192 samples on top of the
        // 2048-sample window laps its oldest sample mid-copy.
        let flood = [Float](repeating: 0.25, count: 8192)
        processor.afterWindowCopyForTesting = {
            processor.ingest(left: flood, right: flood, timestampNanos: 2)
        }
        #expect(processor.analyzeIfDue(nowNanos: Self.interval) == nil)
        processor.afterWindowCopyForTesting = nil

        // The next pull analyzes the fresh (post-flood) data instead.
        #expect(processor.analyzeIfDue(nowNanos: Self.interval * 2) != nil)
    }

    @Test("A concurrent write that stops short of a lap keeps the analysis")
    func nearLapDuringCopyKeepsAnalysis() {
        let processor = AudioSpectrumProcessor()
        let tone = Self.orderSensitiveSignal(count: 2048)
        processor.ingest(left: tone, right: tone, timestampNanos: 1)

        // 6144 more samples put the write cursor exactly at windowStart +
        // capacity — the window's oldest sample is still intact.
        let nearFlood = [Float](repeating: 0.25, count: 6144)
        processor.afterWindowCopyForTesting = {
            processor.ingest(left: nearFlood, right: nearFlood, timestampNanos: 2)
        }
        defer { processor.afterWindowCopyForTesting = nil }
        #expect(processor.analyzeIfDue(nowNanos: Self.interval) != nil)
    }

    /// Ramp-enveloped two-tone signal: any cyclic shift of the window changes the
    /// windowed FFT, so spectrum equality implies sample order was preserved.
    private static func orderSensitiveSignal(count: Int) -> [Float] {
        (0..<count).map { index in
            let t = Float(index) / Float(count)
            let ramp = 0.2 + 0.8 * t
            return ramp * (0.5 * sinf(2 * .pi * 12 * t) + 0.3 * sinf(2 * .pi * 97 * t))
        }
    }
}
