import Dispatch
import Foundation
import os
import Testing
@testable import LiveWallpaper

/// B4: the spectrum ring used to be shared storage — the producer wrote Float slots that
/// the consumer copied while holding nothing, and a post-copy lap check only *detected*
/// the mixed windows that produced. These tests pin the replacement: ownership transfer,
/// where a stalled consumer can only miss whole generations, never blend two.
@Suite("Audio spectrum window hand-off")
struct AudioSpectrumProcessorHandoffTests {
    private static let windowSize = 64

    // MARK: - Criterion 1: a consumer stalled mid-copy never sees a mixed window

    @Test("A consumer stalled mid-copy while the producer laps gets one whole generation")
    func stalledConsumerNeverSeesAMixedWindow() {
        let exchange = AudioSpectrumWindowExchange(windowSize: Self.windowSize)
        let historyCapacity = exchange.historyCapacity
        let running = OSAllocatedUnfairLock(initialState: true)
        let producedSamples = OSAllocatedUnfairLock(initialState: 0)
        let lapsInsideSlowestCopy = OSAllocatedUnfairLock(initialState: 0)
        let producerFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            var total = 0
            var producerLeft = [Float](repeating: 0, count: 16)
            var producerRight = [Float](repeating: 0, count: 16)
            while running.withLock({ $0 }) {
                for offset in 0..<16 {
                    producerLeft[offset] = Float(total + offset)
                    producerRight[offset] = -Float(total + offset)
                }
                exchange.publish(
                    left: producerLeft,
                    right: producerRight,
                    timestampNanos: UInt64(total)
                )
                total += 16
                let published = total
                producedSamples.withLock { $0 = published }
                // Throttled so the index-coded sample values stay well inside Float's
                // exact integer range for the whole run.
                Thread.sleep(forTimeInterval: 0.000_05)
            }
            producerFinished.signal()
        }

        // Runs while the consumer holds the hand-off lock: parks there until the producer
        // has written past the retained history four times over.
        exchange.midCopyHookForTesting = {
            let before = producedSamples.withLock { $0 }
            let deadline = Date().addingTimeInterval(5)
            while producedSamples.withLock({ $0 }) - before < historyCapacity * 4, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            let laps = (producedSamples.withLock { $0 } - before) / historyCapacity
            lapsInsideSlowestCopy.withLock { $0 = max($0, laps) }
        }

        var left = [Float](repeating: 0, count: Self.windowSize)
        var right = [Float](repeating: 0, count: Self.windowSize)
        var observedTotals: [Int] = []

        for _ in 0..<6 {
            // A slow consumer: let the producer get a whole history ahead between pulls.
            Self.waitForSeal(exchange, reaching: (observedTotals.last ?? 0) + historyCapacity)
            let cursor = exchange.copySealedWindow(into: &left, and: &right)
            observedTotals.append(cursor.totalSamples)
            #expect(
                Self.isOneGeneration(left, endingAt: cursor.totalSamples, sign: 1),
                Comment(rawValue: "Left window ending at \(cursor.totalSamples) mixes generations")
            )
            #expect(
                Self.isOneGeneration(right, endingAt: cursor.totalSamples, sign: -1),
                Comment(rawValue: "Right window ending at \(cursor.totalSamples) mixes generations")
            )
        }

        running.withLock { $0 = false }
        exchange.midCopyHookForTesting = nil
        _ = producerFinished.wait(timeout: .now() + 5)
        let totalProduced = producedSamples.withLock { $0 }

        // Without these the six assertions above are vacuous: the producer really did
        // wrap the ring several times inside a single copy…
        #expect(lapsInsideSlowestCopy.withLock { $0 } >= 2)
        #expect(observedTotals.count == 6)
        // …and this consumer really was too slow to keep up, seeing a handful of the
        // windows the producer sealed. That is the drop-frame half of the contract.
        #expect(totalProduced / 16 > observedTotals.count * 10)
        #expect(zip(observedTotals, observedTotals.dropFirst()).allSatisfy { pair in pair.1 > pair.0 })
    }

    // MARK: - Control group: the shape this replaced tears on the same schedule

    @Test("Control: the pre-hand-off shared ring tears where the exchange does not")
    func unsynchronizedRingTearsWhereTheExchangeDoesNot() {
        let size = Self.windowSize

        // Same schedule, old shape: the consumer copies out of the shared ring element by
        // element while the producer laps it four times halfway through.
        let ring = SharedRingUnderTest(capacity: size * 4)
        ring.append(count: size)
        let torn = ring.copyWindow(size: size) { shared in
            for _ in 0..<4 { shared.append(count: shared.capacity) }
        }
        #expect(!Self.isOneGeneration(torn.samples, endingAt: torn.cursor, sign: 1))

        // Same schedule, hand-off shape.
        let exchange = AudioSpectrumWindowExchange(windowSize: size)
        let historyCapacity = exchange.historyCapacity
        let producer = RampProducer()
        producer.publish(count: size, to: exchange)
        exchange.midCopyHookForTesting = {
            for _ in 0..<4 { producer.publish(count: historyCapacity, to: exchange) }
        }
        var left = [Float](repeating: 0, count: size)
        var right = [Float](repeating: 0, count: size)
        let cursor = exchange.copySealedWindow(into: &left, and: &right)
        exchange.midCopyHookForTesting = nil

        #expect(Self.isOneGeneration(left, endingAt: cursor.totalSamples, sign: 1))
        #expect(Self.isOneGeneration(right, endingAt: cursor.totalSamples, sign: -1))
        // The producer did run during the copy; it just cannot reach the window in flight.
        #expect(producer.total == size + historyCapacity * 4)
    }

    // MARK: - Behaviour the hand-off has to preserve

    @Test("The sealed window is the newest windowSize samples, across a ring wrap")
    func sealedWindowIsTheNewestSamplesAcrossAWrap() {
        let size = Self.windowSize
        let exchange = AudioSpectrumWindowExchange(windowSize: size)
        let producer = RampProducer()
        for _ in 0..<9 { producer.publish(count: exchange.historyCapacity / 2, to: exchange) }
        producer.publish(count: 150, to: exchange)

        var left = [Float](repeating: 0, count: size)
        var right = [Float](repeating: 0, count: size)
        let cursor = exchange.copySealedWindow(into: &left, and: &right)

        // Control: these counts really do straddle the ring seam, so the two-block copy
        // is under test rather than the single-block path.
        let start = (cursor.totalSamples - size) % exchange.historyCapacity
        #expect(start + size > exchange.historyCapacity)

        #expect(cursor.totalSamples == producer.total)
        #expect(Self.isOneGeneration(left, endingAt: cursor.totalSamples, sign: 1))
        #expect(Self.isOneGeneration(right, endingAt: cursor.totalSamples, sign: -1))
    }

    @Test("Before the first full window the hand-off left-pads with silence")
    func partialFirstWindowIsLeftPadded() {
        let size = Self.windowSize
        let exchange = AudioSpectrumWindowExchange(windowSize: size)
        RampProducer().publish(count: 3, to: exchange)

        var left = [Float](repeating: 9, count: size)
        var right = [Float](repeating: 9, count: size)
        let cursor = exchange.copySealedWindow(into: &left, and: &right)

        #expect(cursor.totalSamples == 3)
        #expect(left.prefix(size - 3).allSatisfy { $0 == 0 })
        #expect(Array(left.suffix(3)) == [0, 1, 2])
        #expect(Array(right.suffix(3)) == [0, -1, -2])
    }

    @Test("Non-finite samples are zeroed on the way into the ring")
    func nonFiniteSamplesAreSanitizedOnIngest() {
        let size = Self.windowSize
        let exchange = AudioSpectrumWindowExchange(windowSize: size)
        exchange.publish(left: [1, .nan, .infinity, 2], right: [.nan, 1, 2, 3], timestampNanos: 5)

        var left = [Float](repeating: 9, count: size)
        var right = [Float](repeating: 9, count: size)
        let cursor = exchange.copySealedWindow(into: &left, and: &right)

        #expect(cursor == AudioSpectrumWindowExchange.Cursor(totalSamples: 4, timestampNanos: 5))
        #expect(Array(left.suffix(4)) == [1, 0, 0, 2])
        #expect(Array(right.suffix(4)) == [0, 1, 2, 3])
    }

    // MARK: - Criterion 3: the audio-thread path stays realtime-safe

    @Test("The audio-thread publish path carries no FFT, no allocation, no waiting lock")
    func publishPathHoldsTheRealtimeContract() throws {
        let exchangeSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Audio/AudioSpectrumWindowExchange.swift"
        )
        let processorSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Audio/AudioSpectrumProcessor.swift"
        )

        let ingestBody = try #require(Self.body(of: "func ingest(", in: processorSource))
        let publishBody = try #require(Self.body(of: "func publish(", in: exchangeSource))
        let appendBody = try #require(Self.body(of: "func appendToRing(", in: exchangeSource))
        let stageBody = try #require(Self.body(of: "func stageNewestWindow(", in: exchangeSource))
        // publish() is the whole audio-thread call tree, so the probes cover its callees.
        let audioThreadBody = [publishBody, appendBody, stageBody].joined(separator: "\n")

        // Control: the slices are the real bodies. An empty string would satisfy every
        // negative probe below and report green.
        #expect(audioThreadBody.contains("producedSamples += frameCount"))
        #expect(audioThreadBody.contains("stage.baseAddress!.update(from:"))
        #expect(ingestBody.contains("exchange.publish("))

        let forbidden = [
            "vDSP", "fftSetup", "FFT",
            "[Float](", "Array(", ".allocate(", ".append(", "reserveCapacity",
            "withLockUnchecked", "withLock {", "withLock("
        ]
        for token in forbidden {
            #expect(
                !audioThreadBody.contains(token),
                Comment(rawValue: "AudioSpectrumWindowExchange.publish path must stay realtime-safe: found \(token)")
            )
            #expect(
                !ingestBody.contains(token),
                Comment(rawValue: "AudioSpectrumProcessor.ingest must stay realtime-safe: found \(token)")
            )
        }
        // The only lock the audio thread touches, and it never waits on it.
        #expect(audioThreadBody.contains("withLockIfAvailableUnchecked"))

        // Control for the negative probes: the same extractor does see those tokens where
        // they legitimately live, so the absences above are evidence and not a typo.
        let analysisBody = try #require(Self.body(of: "func processChannel(", in: processorSource))
        #expect(analysisBody.contains("fftSetup"))
        #expect(analysisBody.contains("vDSP"))
        let consumerCursorBody = try #require(Self.body(of: "func publishedCursor(", in: exchangeSource))
        #expect(consumerCursorBody.contains("withLockUnchecked"))
    }

    // MARK: - The processor over the hand-off, under real concurrency

    @Test("Ingesting and pulling concurrently keeps every delivered frame normalized")
    func concurrentIngestAndPullStaysNormalized() {
        let processor = AudioSpectrumProcessor()
        let running = OSAllocatedUnfairLock(initialState: true)
        let producerFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            var chunk = [Float](repeating: 0, count: 512)
            var phase: Float = 0
            while running.withLock({ $0 }) {
                for index in 0..<chunk.count {
                    chunk[index] = 0.7 * sinf(phase + Float(index) * 0.05)
                }
                phase += 0.13
                processor.ingest(left: chunk, right: chunk, timestampNanos: 1)
                Thread.sleep(forTimeInterval: 0.001)
            }
            producerFinished.signal()
        }

        var frames = 0
        var now = AudioSpectrumProcessor.minAnalysisIntervalNanos
        for _ in 0..<200 {
            if let frame = processor.analyzeIfDue(nowNanos: now) {
                frames += 1
                #expect(frame.left.count == AudioSpectrumFrame.binCount)
                #expect(frame.left.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                #expect(frame.right.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
            }
            now &+= AudioSpectrumProcessor.minAnalysisIntervalNanos
            Thread.sleep(forTimeInterval: 0.001)
        }

        running.withLock { $0 = false }
        _ = producerFinished.wait(timeout: .now() + 5)
        #expect(frames > 0)
    }

    // MARK: - Helpers

    /// The producers below code every sample with its absolute stream index, so a window
    /// is verifiable from its cursor alone: coherent exactly when it is the unbroken run
    /// ending at `total`. A window mixing laps fails on its first out-of-run sample.
    private static func isOneGeneration(_ samples: [Float], endingAt total: Int, sign: Float) -> Bool {
        let start = total - samples.count
        for index in samples.indices where start + index >= 0 {
            guard samples[index] == sign * Float(start + index) else { return false }
        }
        return true
    }

    private static func waitForSeal(_ exchange: AudioSpectrumWindowExchange, reaching total: Int) {
        let deadline = Date().addingTimeInterval(5)
        while exchange.publishedCursor().totalSamples < total, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    /// Body of the first declaration whose signature starts with `marker`, brace-matched
    /// from its opening `{`.
    private static func body(of marker: String, in source: String) -> String? {
        guard let signature = source.range(of: marker),
              let open = source[signature.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<index]) }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Absolute-index-coded publisher; single-threaded use only.
    private final class RampProducer {
        private(set) var total = 0

        func publish(count: Int, to exchange: AudioSpectrumWindowExchange) {
            var left = [Float](repeating: 0, count: count)
            var right = [Float](repeating: 0, count: count)
            for index in 0..<count {
                left[index] = Float(total + index)
                right[index] = -Float(total + index)
            }
            exchange.publish(left: left, right: right, timestampNanos: UInt64(total))
            total += count
        }
    }

    /// The pre-B4 shape, kept here as the control: one shared ring, the consumer copying
    /// out of it element by element while the producer keeps writing into it. Driven on a
    /// single thread, so the control can demonstrate tearing without itself racing.
    private final class SharedRingUnderTest {
        let capacity: Int
        private let mask: Int
        private var storage: [Float]
        private(set) var total = 0

        init(capacity: Int) {
            self.capacity = capacity
            self.mask = capacity - 1
            self.storage = [Float](repeating: 0, count: capacity)
        }

        func append(count: Int) {
            for offset in 0..<count {
                storage[(total + offset) & mask] = Float(total + offset)
            }
            total += count
        }

        func copyWindow(
            size: Int,
            midCopy: (SharedRingUnderTest) -> Void
        ) -> (samples: [Float], cursor: Int) {
            let cursor = total
            var window = [Float](repeating: 0, count: size)
            for offset in 0..<size {
                if offset == size / 2 { midCopy(self) }
                let absolute = cursor - size + offset
                window[offset] = absolute < 0 ? 0 : storage[absolute & mask]
            }
            return (window, cursor)
        }
    }
}
