#if !LITE_BUILD
import Foundation
import Metal
import Testing
import simd
@testable import LiveWallpaper

/// The arena replaces a per-pass `[SIMD4<Float>]` and a per-frame `makeBuffer` with
/// bump allocations inside resident per-frame-slot storage. What has to hold: it
/// stops allocating, it never rewinds memory the GPU may still be reading, and a
/// reservation it cannot serve degrades to the old path instead of vanishing.
@Suite("WPE uniform arena")
struct WPEMetalUniformArenaTests {

    private static func makeArena(
        slotCount: Int = WPEMetalRenderExecutor.maxFramesInFlight,
        capacity: Int = WPEMetalUniformArena.defaultSlotCapacity
    ) throws -> WPEMetalUniformArena {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return WPEMetalUniformArena(device: device, slotCount: slotCount, initialCapacity: capacity)
    }

    private static func overlaps(
        _ a: WPEMetalUniformArena.Region, _ b: WPEMetalUniformArena.Region
    ) -> Bool {
        guard let aBase = a.storage.baseAddress, let bBase = b.storage.baseAddress else {
            return false
        }
        let aStart = UInt(bitPattern: UnsafeRawPointer(aBase))
        let bStart = UInt(bitPattern: UnsafeRawPointer(bBase))
        return aStart < bStart + UInt(b.byteCount) && bStart < aStart + UInt(a.byteCount)
    }

    /// One complete frame on `slot`: open, reserve, submit, and let the GPU finish.
    private static func runFrame(_ arena: WPEMetalUniformArena, slot: Int, sizes: [Int]) {
        arena.beginFrame(slot: slot)
        for size in sizes {
            _ = arena.reserve(slotCount: size, frameSlot: slot)
        }
        arena.beginSubmission(frameSlot: slot).complete()
    }

    // MARK: - Residency

    @Test("Once warm, no frame creates an MTLBuffer")
    func steadyStateCreatesNoBuffers() throws {
        let arena = try Self.makeArena()
        let sizes = [4, 40, 12, 96]

        for frame in 0..<4 {
            Self.runFrame(arena, slot: frame % arena.slotCount, sizes: sizes)
        }
        let warm = arena.bufferAllocationCount
        for frame in 4..<20 {
            Self.runFrame(arena, slot: frame % arena.slotCount, sizes: sizes)
        }

        // The point of the arena: steady state adds nothing.
        #expect(arena.bufferAllocationCount == warm)
        // And warm-up itself is one buffer per slot, not one per frame.
        #expect(warm == arena.slotCount)
        #expect(arena.overflowCount == 0)
    }

    // MARK: - In-flight safety

    @Test("A slot with an unfinished submission bumps forward instead of rewinding")
    func inFlightSlotIsNotRewound() throws {
        let arena = try Self.makeArena()

        arena.beginFrame(slot: 0)
        let speculative = try #require(arena.reserve(slotCount: 8, frameSlot: 0))
        // Stands in for the speculative frame's command buffer: committed, unfinished.
        let submission = arena.beginSubmission(frameSlot: 0)

        // The SceneScript fail-close re-encode: same lease, so the same slot, while
        // the speculative buffer is still running.
        arena.beginFrame(slot: 0)
        let stable = try #require(arena.reserve(slotCount: 8, frameSlot: 0))

        #expect(!Self.overlaps(speculative, stable))
        #expect(stable.offset >= speculative.offset + speculative.byteCount)
        #expect(arena.inFlightCount(ofSlot: 0) == 1)

        // Writes to the re-encode must not disturb the in-flight frame's uniforms.
        speculative.storage.update(repeating: SIMD4<Float>(1, 2, 3, 4))
        stable.storage.update(repeating: SIMD4<Float>(9, 9, 9, 9))
        #expect(speculative.storage.allSatisfy { $0 == SIMD4<Float>(1, 2, 3, 4) })

        // Only once the GPU reports completion may the slot be reused.
        submission.complete()
        #expect(arena.inFlightCount(ofSlot: 0) == 0)
        arena.beginFrame(slot: 0)
        let reused = try #require(arena.reserve(slotCount: 8, frameSlot: 0))
        #expect(reused.offset == speculative.offset)
    }

    @Test("An abandoned submission token releases its slot rather than pinning it")
    func droppedSubmissionReleasesTheSlot() throws {
        let arena = try Self.makeArena()
        arena.beginFrame(slot: 0)
        _ = arena.reserve(slotCount: 8, frameSlot: 0)
        do {
            let token = arena.beginSubmission(frameSlot: 0)
            withExtendedLifetime(token) {
                #expect(arena.inFlightCount(ofSlot: 0) == 1)
            }
        }
        // A command buffer released without ever being committed never read the
        // arena, so `deinit` freeing the slot is the correct direction.
        #expect(arena.inFlightCount(ofSlot: 0) == 0)
    }

    @Test("Two frame slots in flight together hand out disjoint memory")
    func frameSlotsDoNotOverlap() throws {
        let arena = try Self.makeArena()

        arena.beginFrame(slot: 0)
        let a = try #require(arena.reserve(slotCount: 64, frameSlot: 0))
        let submission = arena.beginSubmission(frameSlot: 0)

        arena.beginFrame(slot: 1)
        let b = try #require(arena.reserve(slotCount: 64, frameSlot: 1))

        #expect(!Self.overlaps(a, b))
        a.storage.update(repeating: SIMD4<Float>(1, 1, 1, 1))
        b.storage.update(repeating: SIMD4<Float>(2, 2, 2, 2))
        #expect(a.storage.allSatisfy { $0 == SIMD4<Float>(1, 1, 1, 1) })

        submission.complete()
    }

    // MARK: - Packing preconditions

    @Test("A rewound region comes back zeroed, so the packer sees no stale lanes")
    func rewoundRegionIsZeroed() throws {
        let arena = try Self.makeArena()

        arena.beginFrame(slot: 0)
        // A leading reservation puts the region under test at a nonzero offset,
        // which is where offset arithmetic and a missing zero-fill both hide.
        let lead = try #require(arena.reserve(slotCount: 4, frameSlot: 0))
        let first = try #require(arena.reserve(slotCount: 4, frameSlot: 0))
        #expect(first.offset > 0)
        lead.storage.update(repeating: SIMD4<Float>(repeating: 7))
        first.storage.update(repeating: SIMD4<Float>(repeating: 7))

        arena.beginSubmission(frameSlot: 0).complete()
        arena.beginFrame(slot: 0)
        _ = arena.reserve(slotCount: 4, frameSlot: 0)
        let reused = try #require(arena.reserve(slotCount: 4, frameSlot: 0))

        // Same memory as `first` — and the packer relies on it being zero, because it
        // writes only the lanes a uniform's glslType covers.
        #expect(reused.offset == first.offset)
        #expect(reused.storage.allSatisfy { $0 == SIMD4<Float>() })
    }

    @Test("Every region offset is legal for setFragmentBuffer")
    func regionOffsetsAreAligned() throws {
        let arena = try Self.makeArena()
        arena.beginFrame(slot: 0)

        // Sizes chosen to be nowhere near a multiple of the alignment on their own:
        // 1 slot is 16 bytes, 3 slots 48, 17 slots 272.
        for size in [1, 3, 17, 5] {
            let region = try #require(arena.reserve(slotCount: size, frameSlot: 0))
            #expect(region.offset % WPEMetalUniformArena.offsetAlignment == 0)
            #expect(region.byteCount == size * MemoryLayout<SIMD4<Float>>.stride)
        }
    }

    // MARK: - Exhaustion

    @Test("A reservation that does not fit refuses, then the next frame has room")
    func overflowRefusesThenGrows() throws {
        let arena = try Self.makeArena(capacity: 512)
        arena.beginFrame(slot: 0)

        // 256 slots is 4096 bytes against a 512-byte slot.
        let refused = arena.reserve(slotCount: 256, frameSlot: 0)
        #expect(refused == nil)
        #expect(arena.overflowCount == 1)

        // The refusal recorded what the frame wanted, so the next rewind sizes up and
        // the scene converges to zero fallbacks.
        arena.beginSubmission(frameSlot: 0).complete()
        arena.beginFrame(slot: 0)
        let granted = try #require(arena.reserve(slotCount: 256, frameSlot: 0))
        #expect(granted.byteCount == 4096)
        #expect(arena.overflowCount == 1)
    }

    @Test("A reservation past the per-slot cap never grows the arena into it")
    func oversizedReservationNeverGrowsPastTheCap() throws {
        let arena = try Self.makeArena(capacity: 512)
        let overCap = WPEMetalUniformArena.maximumSlotCapacity
            / MemoryLayout<SIMD4<Float>>.stride + 1

        for _ in 0..<3 {
            arena.beginFrame(slot: 0)
            let refused = arena.reserve(slotCount: overCap, frameSlot: 0)
            #expect(refused == nil)
            arena.beginSubmission(frameSlot: 0).complete()
        }

        #expect(arena.capacity(ofSlot: 0) <= WPEMetalUniformArena.maximumSlotCapacity)
        #expect(arena.overflowCount == 3)
    }

    @Test("A slot index outside the arena refuses instead of trapping")
    func outOfRangeSlotRefuses() throws {
        let arena = try Self.makeArena(slotCount: 2)
        arena.beginFrame(slot: 7)
        let refused = arena.reserve(slotCount: 4, frameSlot: 7)
        #expect(refused == nil)
        #expect(arena.inFlightCount(ofSlot: 7) == 0)
    }

    // MARK: - Production wiring

    /// Every test above drives the arena object directly, so deleting the single
    /// `render()` line that hands it the frame's command buffer leaves them all
    /// green while the in-flight rule they pin protects nothing — a double render
    /// would then rewind memory the GPU is still reading.
    ///
    /// Source-level because there is no seam that observes the attach, and
    /// deliberately minimal: only that the call exists inside `render(` and
    /// precedes the first `commit()` (Metal refuses handlers after commit).
    /// Reformatting the call across lines is expected to fail this and is a
    /// one-line fix here.
    @Test("render() registers the arena submission before the first commit")
    func renderRegistersArenaSubmissionBeforeCommit() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalRenderExecutor.swift"
        )
        let renderBody = source[try #require(source.range(of: "\n    func render(")).upperBound...]
        let track = try #require(
            renderBody.range(of: "uniformArena.trackSubmission(of: commandBuffer, frameSlot:"),
            "render() no longer registers the uniform arena submission"
        )
        let commit = try #require(renderBody.range(of: "commandBuffer.commit()"))
        #expect(track.lowerBound < commit.lowerBound)
    }
}
#endif
