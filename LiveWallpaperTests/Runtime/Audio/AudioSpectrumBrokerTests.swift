import os
import Testing
@testable import LiveWallpaper

/// One-shot injection seam standing in for the capture-attached processor:
/// hands out its frame on the first pull, nil afterwards, so later snapshots
/// exercise the broker's cached copy. Shared by the script-runtime tests.
final class SpectrumAnalyzerStub: AudioSpectrumAnalyzing, @unchecked Sendable {
    private let pending: OSAllocatedUnfairLock<AudioSpectrumFrame?>

    init(_ frame: AudioSpectrumFrame) {
        pending = OSAllocatedUnfairLock(initialState: frame)
    }

    func analyzeIfDue(nowNanos: UInt64) -> AudioSpectrumFrame? {
        pending.withLock { state in
            defer { state = nil }
            return state
        }
    }
}

@Suite("Audio spectrum broker")
struct AudioSpectrumBrokerTests {
    @Test("Default snapshot is silence")
    func defaultSnapshotIsSilence() {
        let broker = AudioSpectrumBroker()

        let snapshot = broker.snapshot()

        #expect(snapshot == .silence)
    }

    @Test("Analyzer frame is cached and returned normalized")
    func analyzerFrameIsCachedNormalized() {
        let broker = AudioSpectrumBroker()
        let frame = AudioSpectrumFrame(
            left: [0.25, 0.5],
            right: [0.75],
            timestampNanos: 42
        )

        broker.attachAnalyzer(SpectrumAnalyzerStub(frame))
        let snapshot = broker.snapshot()
        // Second pull hits the stub's nil — this is the cached copy.
        let cached = broker.snapshot()

        #expect(snapshot == frame)
        #expect(cached == frame)
        #expect(snapshot.left.count == AudioSpectrumFrame.binCount)
        #expect(snapshot.right.count == AudioSpectrumFrame.binCount)
        #expect(snapshot.left[0] == 0.25)
        #expect(snapshot.left[1] == 0.5)
        #expect(snapshot.left[2] == 0)
        #expect(snapshot.right[0] == 0.75)
        #expect(snapshot.right[1] == 0)
    }

    @Test("Reset to silence clears latest frame")
    func resetToSilenceClearsLatestFrame() {
        let broker = AudioSpectrumBroker()
        broker.attachAnalyzer(
            SpectrumAnalyzerStub(AudioSpectrumFrame(left: [0.4], right: [0.6], timestampNanos: 99))
        )
        #expect(broker.snapshot() != .silence)

        broker.attachAnalyzer(nil)
        broker.resetToSilence()

        #expect(broker.snapshot() == .silence)
    }

    @Test("Concurrent attach and snapshot stay memory-safe")
    func concurrentAttachAndSnapshot() async {
        let broker = AudioSpectrumBroker()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<1000 {
                    let value = Float(index % 2)
                    broker.attachAnalyzer(
                        SpectrumAnalyzerStub(
                            AudioSpectrumFrame(
                                left: [value],
                                right: [value],
                                timestampNanos: UInt64(index)
                            )
                        )
                    )
                }
            }
            group.addTask {
                for _ in 0..<1000 {
                    _ = broker.snapshot()
                }
            }
        }

        #expect(broker.snapshot().left.count == AudioSpectrumFrame.binCount)
    }
}
