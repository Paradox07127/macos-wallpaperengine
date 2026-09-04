#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// The `>4 KB` uniform path used to swallow an allocation failure: the branch was
/// an `else if let` with no `else`, so the slot stayed unbound and nothing was
/// logged, leaving the fragment stage to read undefined uniforms in silence.
@Suite("WPE translated uniform binding")
struct WPEMetalTranslatedUniformBindingTests {

    private struct Harness {
        let executor: WPEMetalRenderExecutor
        /// Retained so the encoder outlives its command buffer's local scope.
        let commandBuffer: MTLCommandBuffer
        let encoder: MTLRenderCommandEncoder
    }

    private static func makeHarness() throws -> Harness {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 16, height: 16, mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        let commandBuffer = try #require(queue.makeCommandBuffer())
        return Harness(
            executor: try WPEMetalRenderExecutor(device: device),
            commandBuffer: commandBuffer,
            encoder: try #require(commandBuffer.makeRenderCommandEncoder(descriptor: renderPass))
        )
    }

    private static func slots(_ count: Int) -> [SIMD4<Float>] {
        (0..<count).map { SIMD4<Float>(Float($0), 0, 0, 0) }
    }

    @Test("At or under 4 KB the slots still ride the inline fast path")
    func inlinePathIsUnchanged() throws {
        let harness = try Self.makeHarness()
        // 256 × 16 bytes is exactly the `setFragmentBytes` cap.
        let outcome = harness.executor.bindTranslatedUniformSlots(
            Self.slots(256), to: harness.encoder
        )
        harness.encoder.endEncoding()

        #expect(outcome == .inline(byteCount: 4096))
        #expect(harness.executor.gpuErrorSink.summary.count == 0)
    }

    @Test("Above 4 KB the slots bind a transient buffer")
    func largePathBindsABuffer() throws {
        let harness = try Self.makeHarness()
        let outcome = harness.executor.bindTranslatedUniformSlots(
            Self.slots(257), to: harness.encoder
        )
        harness.encoder.endEncoding()

        #expect(outcome == .buffer(byteCount: 4112))
        #expect(harness.executor.gpuErrorSink.summary.count == 0)
    }

    @Test("An empty slot array binds nothing and reports nothing")
    func emptySlotsAreANoOp() throws {
        let harness = try Self.makeHarness()
        let outcome = harness.executor.bindTranslatedUniformSlots([], to: harness.encoder)
        harness.encoder.endEncoding()

        #expect(outcome == .empty)
        #expect(harness.executor.gpuErrorSink.summary.count == 0)
    }

    @Test("A failed large-buffer allocation is reported, not silently skipped")
    func allocationFailureIsReported() throws {
        let harness = try Self.makeHarness()
        var attempts: [Int] = []

        var outcome: WPEMetalRenderExecutor.TranslatedUniformBinding = .empty
        for _ in 0..<3 {
            outcome = harness.executor.bindTranslatedUniformSlots(
                Self.slots(257),
                to: harness.encoder,
                allocate: { _, byteCount in
                    attempts.append(byteCount)
                    return nil
                }
            )
        }
        harness.encoder.endEncoding()

        #expect(outcome == .allocationFailed(byteCount: 4112))
        // The seam really was the >4 KB branch, three times over.
        #expect(attempts == [4112, 4112, 4112])
        // Every failure reaches the sink the scene diagnostics read.
        let summary = harness.executor.gpuErrorSink.summary
        #expect(summary.count == 3)
        #expect(summary.last?.contains("uniform-buffer") == true)
        #expect(summary.last?.contains("4112") == true)
    }

    // MARK: - Uniform arena

    /// Every packing shape the slot walk has a branch for.
    private static func coverageLayout() -> [WPEUniformSlot] {
        [
            WPEUniformSlot(
                name: "u_Float", glslType: "float", slot: 0, slotCount: 1,
                defaultValue: .number(0.5)
            ),
            WPEUniformSlot(
                name: "u_Vec2", glslType: "vec2", slot: 1, slotCount: 1,
                defaultValue: .vector([0.25, 0.75])
            ),
            WPEUniformSlot(
                name: "u_Vec3", glslType: "vec3", slot: 2, slotCount: 1,
                defaultValue: .vector([1, 2, 3])
            ),
            WPEUniformSlot(
                name: "u_Vec4", glslType: "vec4", slot: 3, slotCount: 1,
                defaultValue: .vector([4, 5, 6, 7])
            ),
            WPEUniformSlot(
                name: "u_Mat2", glslType: "mat2", slot: 4, slotCount: 2,
                defaultValue: .vector([8, 9, 10, 11])
            ),
            WPEUniformSlot(
                name: "u_Mat3", glslType: "mat3", slot: 6, slotCount: 3,
                defaultValue: .vector([12, 13, 14, 15, 16, 17, 18, 19, 20])
            ),
            WPEUniformSlot(
                name: "u_Mat4", glslType: "mat4", slot: 9, slotCount: 4,
                defaultValue: .vector((0..<16).map { Double($0) + 21 })
            ),
            WPEUniformSlot(
                name: "u_Array", glslType: "vec2", slot: 13, slotCount: 4, arrayLength: 4,
                defaultValue: .vector([37, 38, 39, 40, 41, 42, 43, 44])
            ),
            // No default: its lanes must stay zero, which is what makes a missing
            // zero-fill in the arena visible as a byte difference.
            WPEUniformSlot(name: "u_NoDefault", glslType: "vec3", slot: 17, slotCount: 1)
        ]
    }

    private static func makePass(id: String) -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: WPERenderPass(
                id: id,
                phase: .effect(file: "effects/arena/effect.json"),
                shader: "effects/arena",
                source: .image("materials/base.png"),
                target: .scene,
                textures: [:],
                binds: [:],
                constants: [:],
                combos: [:],
                blending: "disabled",
                cullMode: "nocull",
                depthTest: "disabled",
                depthWrite: "disabled"
            ),
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )
    }

    private static func rawBytes(_ slots: [SIMD4<Float>]) -> [UInt8] {
        slots.withUnsafeBytes { Array($0) }
    }

    @Test("Arena packing writes byte-identical slots over dirtied, reused memory")
    func arenaPackingIsByteIdenticalToTheArrayPath() throws {
        let harness = try Self.makeHarness()
        let executor = harness.executor
        let layout = Self.coverageLayout()
        let pass = Self.makePass(id: "arena.parity")
        let slotCount = WPEMetalRenderExecutor.translatedSlotCount(for: layout)

        let reference = executor.packTranslatedUniforms(for: pass, layout: layout)
        #expect(reference.count == slotCount)
        // A layout that packed all zeros would make the comparison below vacuous.
        #expect(reference.contains { $0 != SIMD4<Float>() })

        executor.currentUniformArenaSlot = 0
        defer { executor.currentUniformArenaSlot = nil }
        let arena = executor.uniformArena

        // Dirty the exact bytes the packed region will land on: a leading reservation
        // fixes the offset, and the rewind below reissues the same memory. Without
        // this the region would be freshly zeroed by Metal and a dropped zero-fill
        // would still pass.
        arena.beginFrame(slot: 0)
        _ = try #require(arena.reserve(slotCount: 4, frameSlot: 0))
        let dirty = try #require(arena.reserve(slotCount: slotCount, frameSlot: 0))
        #expect(dirty.offset > 0)
        dirty.storage.update(repeating: SIMD4<Float>(repeating: 7))

        arena.beginSubmission(frameSlot: 0).complete()
        arena.beginFrame(slot: 0)
        _ = try #require(arena.reserve(slotCount: 4, frameSlot: 0))

        let packed = executor.packTranslatedUniformsForBinding(for: pass, layout: layout)
        guard case .arena(let region) = packed else {
            Issue.record("expected the arena path, got \(packed)")
            return
        }
        #expect(region.offset == dirty.offset)
        #expect(Self.rawBytes(reference) == Self.rawBytes(Array(region.storage)))
        harness.encoder.endEncoding()
    }

    @Test("Arena slots keep the 4 KB split and bind at the region's own offset")
    func arenaKeepsTheInlineAndBufferSplit() throws {
        let harness = try Self.makeHarness()
        let executor = harness.executor
        executor.currentUniformArenaSlot = 0
        defer { executor.currentUniformArenaSlot = nil }
        executor.uniformArena.beginFrame(slot: 0)

        let small = Self.coverageLayout()
        let smallBytes = WPEMetalRenderExecutor.translatedSlotCount(for: small) * 16
        let smallPacked = executor.packTranslatedUniformsForBinding(
            for: Self.makePass(id: "arena.small"), layout: small
        )
        #expect(executor.bindTranslatedUniformSlots(smallPacked, to: harness.encoder)
            == .inline(byteCount: smallBytes))

        // 300 float array elements is 4800 bytes — past the `setFragmentBytes` cap.
        let large = [
            WPEUniformSlot(
                name: "u_Big", glslType: "float", slot: 0, slotCount: 300, arrayLength: 300
            )
        ]
        let largePacked = executor.packTranslatedUniformsForBinding(
            for: Self.makePass(id: "arena.large"), layout: large
        )
        guard case .arena(let region) = largePacked else {
            Issue.record("expected the arena path, got \(largePacked)")
            return
        }
        // The bind must use the region's offset, not 0 — this is a sub-allocation.
        #expect(region.offset > 0)
        #expect(executor.bindTranslatedUniformSlots(largePacked, to: harness.encoder)
            == .buffer(byteCount: 4800))
        harness.encoder.endEncoding()

        // The arena path allocates nothing per pass, so nothing is reported.
        #expect(executor.gpuErrorSink.summary.count == 0)
    }

    @Test("An exhausted arena still binds, through the array path")
    func exhaustedArenaFallsBackAndStillBinds() throws {
        let harness = try Self.makeHarness()
        let executor = harness.executor
        executor.currentUniformArenaSlot = 0
        defer { executor.currentUniformArenaSlot = nil }
        let arena = executor.uniformArena
        arena.beginFrame(slot: 0)

        // Burn the slot down so the next reservation cannot be served.
        var reservations = 0
        while arena.reserve(slotCount: 256, frameSlot: 0) != nil {
            reservations += 1
            #expect(reservations < 4096, "the slot should exhaust long before this")
        }
        #expect(reservations > 0)

        let packed = executor.packTranslatedUniformsForBinding(
            for: Self.makePass(id: "arena.overflow"), layout: Self.coverageLayout()
        )
        guard case .array(let slots) = packed else {
            Issue.record("expected the fallback array path, got \(packed)")
            return
        }
        // The fallback must produce the same bytes as the ordinary array packer …
        #expect(Self.rawBytes(slots) == Self.rawBytes(
            executor.packTranslatedUniforms(for: Self.makePass(id: "arena.overflow"),
                                            layout: Self.coverageLayout())
        ))
        // … and, above all, it must still bind. A silent skip is the exact bug the
        // `.allocationFailed` state was added for.
        let outcome = executor.bindTranslatedUniformSlots(packed, to: harness.encoder)
        harness.encoder.endEncoding()
        #expect(outcome == .inline(byteCount: 18 * 16))
        #expect(executor.gpuErrorSink.summary.count == 0)
    }

    @Test("Without a frame lease the packer keeps the pre-arena path")
    func noFrameSlotMeansNoArena() throws {
        let harness = try Self.makeHarness()
        let executor = harness.executor
        // `currentUniformArenaSlot` stays nil: sync/readback and legacy async callers
        // have no slot identity to partition the arena by.
        #expect(executor.currentUniformArenaSlot == nil)

        let packed = executor.packTranslatedUniformsForBinding(
            for: Self.makePass(id: "arena.nolease"), layout: Self.coverageLayout()
        )
        guard case .array = packed else {
            Issue.record("expected the array path, got \(packed)")
            return
        }
        let outcome = executor.bindTranslatedUniformSlots(packed, to: harness.encoder)
        harness.encoder.endEncoding()
        #expect(outcome == .inline(byteCount: 18 * 16))
    }

    @Test("An empty layout packs and binds nothing")
    func emptyLayoutIsANoOp() throws {
        let harness = try Self.makeHarness()
        let packed = harness.executor.packTranslatedUniformsForBinding(
            for: Self.makePass(id: "arena.empty"), layout: []
        )
        #expect(packed.isEmpty)
        let outcome = harness.executor.bindTranslatedUniformSlots(packed, to: harness.encoder)
        harness.encoder.endEncoding()
        #expect(outcome == .empty)
    }
}
#endif
