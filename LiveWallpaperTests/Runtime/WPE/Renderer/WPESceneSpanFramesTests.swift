#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Scene span completed frame publication")
struct WPESceneSpanFramesTests {
    @Test("Late GPU completions cannot publish into a new load generation")
    func generationRejectsOldCompletion() {
        let frames = WPESceneSpanLatestFrame<Int>()
        frames.reset(generation: 1)
        #expect(frames.publish(10, generation: 1, sequence: 1))
        frames.reset(generation: 2)
        #expect(frames.latest() == nil)
        #expect(!frames.publish(11, generation: 1, sequence: 2))
        #expect(frames.publish(20, generation: 2, sequence: 1))
        #expect(frames.latest() == 20)
    }

    @Test("An out-of-order completion never replaces a newer completed frame")
    func sequenceRejectsOldCompletion() {
        let frames = WPESceneSpanLatestFrame<Int>()
        frames.reset(generation: 1)
        #expect(frames.publish(2, generation: 1, sequence: 2))
        #expect(!frames.publish(1, generation: 1, sequence: 1))
        #expect(!frames.publish(3, generation: 1, sequence: 2))
        #expect(frames.latest() == 2)
    }

    private final class Packet: Sendable {}

    @Test("Replacing the latest packet preserves an outstanding reader lease")
    func readerLifetime() {
        let frames = WPESceneSpanLatestFrame<Packet>()
        frames.reset(generation: 1)
        weak var old: Packet?
        do {
            let packet = Packet()
            old = packet
            #expect(frames.publish(packet, generation: 1, sequence: 1))
        }
        var reader = frames.latest()
        #expect(reader != nil)
        #expect(frames.publish(Packet(), generation: 1, sequence: 2))
        #expect(old != nil)
        reader = nil
        #expect(old == nil)
    }

    @Test("Concurrent producers resolve to the highest completed sequence")
    func concurrentPublication() async {
        let frames = WPESceneSpanLatestFrame<Int>()
        frames.reset(generation: 1)
        await withTaskGroup(of: Void.self) { group in
            for sequence in 1 ... 100 {
                group.addTask { frames.publish(sequence, generation: 1, sequence: UInt64(sequence)) }
            }
        }
        #expect(frames.latest() == 100)
    }
}
#endif
