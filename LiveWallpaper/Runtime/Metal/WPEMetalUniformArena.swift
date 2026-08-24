#if !LITE_BUILD
import Foundation
import Metal
import simd

/// Resident per-frame-slot storage for the transpiler's `WPEUniforms.vals[]` packing.
///
/// Before this, every graphics pass built a fresh `[SIMD4<Float>]` (~53 array
/// allocations per frame at steady state, one per `passEnc` in
/// `WPEFrameOccupancyMeter`) and every layout over 4 KB additionally built a
/// brand-new `MTLBuffer` every frame. Both become a bump allocation inside one
/// shared-storage buffer per in-flight frame slot.
///
/// ## In-flight safety
///
/// A region handed out by `reserve` stays readable by the GPU until the command
/// buffer that bound it completes, so the cursor for a slot is rewound ONLY while
/// that slot has zero committed-but-uncompleted command buffers. That count is
/// `InFlightCounters`: raised before `commit()` and dropped from the command
/// buffer's own completion handler.
///
/// The count — not the frame-slot index — is what makes this correct. Slot indices
/// alone are not enough here: on the SceneScript fail-close path a second
/// `render()` reuses one `WPEMetalFrameSubmissionLease`, and therefore one slot,
/// while the speculative frame's command buffer is already committed and unfinished
/// (`WPEMetalSceneRenderer+ScriptFailClose.swift`, "Speculative buffer committed
/// without present"). Keying the rewind on completion makes that case bump forward
/// instead of overwriting live memory, and keeps the invariant independent of
/// `maxFramesInFlight`.
final class WPEMetalUniformArena {

    /// Byte alignment applied to every sub-allocation, so a region's `offset` is
    /// always legal for `MTLRenderCommandEncoder.setFragmentBuffer(_:offset:index:)`.
    ///
    /// Metal exposes no runtime query for it: `MTLDevice` has
    /// `minimumLinearTextureAlignmentForPixelFormat:` and
    /// `minimumTextureBufferAlignmentForPixelFormat:`, both of which govern
    /// `makeTexture(descriptor:offset:bytesPerRow:)` and neither of which applies to
    /// buffer binding. Apple's docs for `setFragmentBuffer(_:offset:index:)` only say
    /// to "check for offset alignment requirements for buffers in `device` and
    /// `constant` address space" in the Metal Feature Set Tables, whose row
    /// "Minimum constant buffer offset alignment" reads 4 B for the Apple families.
    /// Two reviewers read that table and disagreed about whether a Mac2 row of 32 B
    /// is still present, so only the Apple figure is asserted here.
    ///
    /// 256 is deliberately over-aligned rather than the documented minimum: an Apple
    /// silicon Mac reports BOTH Apple7+ and Mac2, and Apple documents only that a
    /// device supports "the union of both feature families" — it never says which
    /// number wins for a numeric limit. A multiple of every documented value needs no
    /// such adjudication and no per-family branch. It is also a multiple of
    /// `MemoryLayout<SIMD4<Float>>.alignment` (16). Cost is under 256 bytes per pass.
    ///
    /// Older sources put this figure at 256 for macOS. Reviewers could not agree on
    /// whether that came from a since-renamed row or from the constant-offset row of
    /// the day, so this comment claims only that 256 satisfies every value either
    /// reading produces.
    static let offsetAlignment = 256

    /// Enough for ~128 typical passes without a grow cycle; a scene that needs more
    /// raises `capacityTarget` from what its own first frame asked for.
    static let defaultSlotCapacity = 64 * 1024

    /// Refuse to size a slot past this. A layout large enough to blow it keeps using
    /// the pre-arena per-pass allocation rather than pinning megabytes per frame slot.
    static let maximumSlotCapacity = 4 * 1024 * 1024

    /// One packed uniform block: `storage` aliases `buffer.contents() + offset`, and
    /// `buffer` keeps that memory alive for as long as the region is held.
    struct Region {
        let buffer: MTLBuffer
        let offset: Int
        let storage: UnsafeMutableBufferPointer<SIMD4<Float>>

        var byteCount: Int { MemoryLayout<SIMD4<Float>>.stride * storage.count }
    }

    /// `@unchecked Sendable`: `counts` is the only mutable state and every read and
    /// write of it holds `lock`. A command-buffer completion handler captures this
    /// object and nothing else — the arena's buffers and cursors never leave the
    /// render thread.
    fileprivate final class InFlightCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int]

        init(slotCount: Int) {
            counts = [Int](repeating: 0, count: slotCount)
        }

        func retain(slot: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard counts.indices.contains(slot) else { return }
            counts[slot] += 1
        }

        func release(slot: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard counts.indices.contains(slot), counts[slot] > 0 else { return }
            counts[slot] -= 1
        }

        func count(slot: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.indices.contains(slot) ? counts[slot] : 0
        }
    }

    private let device: MTLDevice
    private let counters: InFlightCounters
    private var buffers: [MTLBuffer?]
    private var cursors: [Int]
    private var capacityTarget: Int

    /// Every `MTLBuffer` this arena has ever created. The steady-state assertion is
    /// that it stops moving; `WPEFrameOccupancyMeter` cannot stand in for it because
    /// it is process-global across displays and hard-disabled under XCTest.
    private(set) var bufferAllocationCount = 0

    /// Reservations that did not fit and fell back to a per-pass allocation.
    private(set) var overflowCount = 0

    init(device: MTLDevice, slotCount: Int, initialCapacity: Int = defaultSlotCapacity) {
        precondition(slotCount > 0)
        self.device = device
        counters = InFlightCounters(slotCount: slotCount)
        buffers = [MTLBuffer?](repeating: nil, count: slotCount)
        cursors = [Int](repeating: 0, count: slotCount)
        capacityTarget = max(Self.align(initialCapacity), Self.offsetAlignment)
    }

    var slotCount: Int { buffers.count }

    func capacity(ofSlot slot: Int) -> Int {
        buffers.indices.contains(slot) ? (buffers[slot]?.length ?? 0) : 0
    }

    func inFlightCount(ofSlot slot: Int) -> Int { counters.count(slot: slot) }

    /// Opens `slot` for a frame's reservations, rewinding it only when the GPU can no
    /// longer be reading anything previously handed out from it. Growing the slot's
    /// buffer happens here for the same reason — it is the one moment the old
    /// contents are provably dead.
    func beginFrame(slot: Int) {
        guard buffers.indices.contains(slot), counters.count(slot: slot) == 0 else { return }
        cursors[slot] = 0
        if let buffer = buffers[slot], buffer.length >= capacityTarget { return }
        guard let grown = device.makeBuffer(length: capacityTarget, options: .storageModeShared) else {
            // Leave whatever the slot already had; reservations that no longer fit
            // fall back per pass instead of losing the binding.
            return
        }
        buffers[slot] = grown
        bufferAllocationCount += 1
    }

    /// Carves `slotCount` × 16 zeroed bytes out of `frameSlot`, or nil when it does
    /// not fit. A nil is a fallback signal, never a licence to skip the binding.
    func reserve(slotCount: Int, frameSlot: Int) -> Region? {
        guard slotCount > 0, buffers.indices.contains(frameSlot) else { return nil }
        let byteCount = MemoryLayout<SIMD4<Float>>.stride * slotCount
        let start = cursors[frameSlot]
        let end = start + byteCount
        guard let buffer = buffers[frameSlot], end <= buffer.length else {
            overflowCount += 1
            // Record what this frame actually wanted so the next rewind sizes up and
            // the scene converges to zero fallbacks.
            growCapacityTarget(toFit: end)
            return nil
        }
        cursors[frameSlot] = Self.align(end)
        let base = buffer.contents().advanced(by: start)
        // Byte-for-byte parity with `[SIMD4<Float>](repeating: .zero, count:)`: the
        // packer writes only the lanes a uniform's glslType covers and relies on the
        // rest — vec3's `.w`, unreferenced slots — already being zero.
        memset(base, 0, byteCount)
        return Region(
            buffer: buffer,
            offset: start,
            storage: UnsafeMutableBufferPointer(
                start: base.bindMemory(to: SIMD4<Float>.self, capacity: slotCount),
                count: slotCount
            )
        )
    }

    /// Holds `slot` against rewind until `commandBuffer` reports completion. MUST be
    /// called before `commit()`, which is the last point Metal accepts a handler.
    func trackSubmission(of commandBuffer: MTLCommandBuffer, frameSlot: Int) {
        let token = beginSubmission(frameSlot: frameSlot)
        commandBuffer.addCompletedHandler { _ in token.complete() }
    }

    /// `trackSubmission` without a command buffer, so the rewind rule is testable.
    func beginSubmission(frameSlot: Int) -> Submission {
        counters.retain(slot: frameSlot)
        return Submission(counters: counters, slot: frameSlot)
    }

    /// Exactly-once release token. `deinit` is the fail-safe for a command buffer
    /// dropped without commit — the GPU never read the region, so freeing it is right.
    ///
    /// `@unchecked Sendable`: `counters` is the only mutable state and `lock` guards
    /// both the read and the nil-out, so the completion handler and a concurrent
    /// `deinit` cannot both release the slot. `slot` is let.
    final class Submission: @unchecked Sendable {
        private let lock = NSLock()
        private var counters: InFlightCounters?
        private let slot: Int

        fileprivate init(counters: InFlightCounters, slot: Int) {
            self.counters = counters
            self.slot = slot
        }

        func complete() {
            lock.lock()
            let counters = self.counters
            self.counters = nil
            lock.unlock()
            counters?.release(slot: slot)
        }

        deinit {
            complete()
        }
    }

    private func growCapacityTarget(toFit byteCount: Int) {
        let wanted = Self.align(byteCount)
        guard wanted <= Self.maximumSlotCapacity else { return }
        capacityTarget = max(capacityTarget, wanted)
    }

    static func align(_ byteCount: Int) -> Int {
        (byteCount + offsetAlignment - 1) & ~(offsetAlignment - 1)
    }
}
#endif
