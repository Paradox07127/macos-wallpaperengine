#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

/// Latest completed frame only. The producer and each presenter use separate
/// executors; the lock protects publication, never drawable acquisition or GPU waits.
final class WPESceneSpanLatestFrame<Frame: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var sequence: UInt64 = 0
    private var frame: Frame?

    func reset(generation: Int) {
        lock.lock()
        self.generation = generation
        sequence = 0
        let retired = frame
        frame = nil
        lock.unlock()
        withExtendedLifetime(retired) {}
    }

    @discardableResult
    func publish(_ frame: Frame, generation: Int, sequence: UInt64) -> Bool {
        lock.lock()
        guard generation == self.generation, sequence > self.sequence else {
            lock.unlock()
            return false
        }
        let retired = self.frame
        self.frame = frame
        self.sequence = sequence
        lock.unlock()
        withExtendedLifetime(retired) {}
        return true
    }

    func latest() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

/// Immutable GPU resource lease. The producer's recycling tracker is pinned
/// before publication and released only after the latest slot and every GPU
/// reader release this packet. MTLTexture is never mutated through this handle.
final class WPESceneSpanFrame: @unchecked Sendable {
    let texture: MTLTexture
    let generation: Int
    let sequence: UInt64
    let sourceSize: CGSize
    let fitMode: WPEPresentFitMode
    private let tracker: WPEMetalRenderExecutor.PresentInFlightTracker

    init(texture: MTLTexture, generation: Int, sequence: UInt64, sourceSize: CGSize,
         fitMode: WPEPresentFitMode, tracker: WPEMetalRenderExecutor.PresentInFlightTracker) {
        self.texture = texture
        self.generation = generation
        self.sequence = sequence
        self.sourceSize = sourceSize
        self.fitMode = fitMode
        self.tracker = tracker
        tracker.increment(ObjectIdentifier(texture))
    }

    deinit { tracker.decrement(ObjectIdentifier(texture)) }
}

typealias WPESceneSpanFrames = WPESceneSpanLatestFrame<WPESceneSpanFrame>
#endif
