#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// The scene's particle systems and each frame's share of the arena for their draws.
struct WPEParityParticleFrame {
    var scene: WPEParityParticleScene
    /// Arena bytes particle vertices and their draws' cbuffers and tables may take in one frame; the rest of the
    /// arena stays with the other draws.
    var budget: Int
    /// Batches dropped because a frame's particle draws outgrew `budget`, over the renderer's life.
    private(set) var dropped = 0
    private var used = 0
    private var overflowed = false

    init(scene: WPEParityParticleScene, budget: Int) {
        self.scene = scene
        self.budget = budget
    }

    mutating func beginFrame() {
        used = 0
        overflowed = false
    }

    /// Copies `batch` into the frame's arena and reserves the `argumentBytes` its draw encodes next; once one batch
    /// does not fit, every later batch of the frame is dropped.
    mutating func upload(_ batch: WPEParityParticleVertexBatch, argumentBytes: Int,
                         to arena: WPEParityFrameArena.Frame) -> WPEParityFrameArena.Allocation? {
        let length = WPEParityFrameArena.aligned(batch.bytes.count) + argumentBytes
        guard !overflowed, used + length <= budget, arena.canAllocate(length: length),
              let allocation = arena.allocate(length: batch.bytes.count) else {
            overflowed = true
            dropped += 1
            return nil
        }
        used += length
        batch.bytes.withUnsafeBytes { allocation.contents.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return allocation
    }
}
#endif
