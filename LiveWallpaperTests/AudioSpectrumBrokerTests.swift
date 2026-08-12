import Testing
@testable import LiveWallpaper

@Suite("Audio spectrum broker")
struct AudioSpectrumBrokerTests {
    @Test("Default snapshot is silence")
    func defaultSnapshotIsSilence() {
        let broker = AudioSpectrumBroker()

        let snapshot = broker.snapshot()

        #expect(snapshot == .silence)
    }

    @Test("Publish then snapshot returns published normalized frame")
    func publishThenSnapshotReturnsPublishedFrame() {
        let broker = AudioSpectrumBroker()
        let frame = AudioSpectrumFrame(
            left: [0.25, 0.5],
            right: [0.75],
            timestampNanos: 42
        )

        broker.publish(frame)
        let snapshot = broker.snapshot()

        #expect(snapshot == frame)
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
        broker.publish(AudioSpectrumFrame(left: [0.4], right: [0.6], timestampNanos: 99))

        broker.resetToSilence()

        #expect(broker.snapshot() == .silence)
    }

    @Test("Concurrent publish and snapshot stay memory-safe")
    func concurrentPublishAndSnapshot() async {
        let broker = AudioSpectrumBroker()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<1000 {
                    let value = Float(index % 2)
                    broker.publish(
                        AudioSpectrumFrame(
                            left: [value],
                            right: [value],
                            timestampNanos: UInt64(index)
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
