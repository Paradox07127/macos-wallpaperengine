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

@Suite("WPE batched fragment bindings")
struct WPEMetalBatchedFragmentBindingTests {
    private struct Draw {
        let count: Int
        let textures: [MTLTexture]
        let samplers: [MTLSamplerState]
    }

    private func makeDraw(device: MTLDevice, count: Int, revision: Int) throws -> Draw {
        let textures = try (0 ..< count).map { slot -> MTLTexture in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            var bytes: [UInt8] = []
            for pixel in 0 ..< 4 {
                bytes += [
                    UInt8((slot * 13 + revision * 41 + pixel * 37) % 251),
                    UInt8((slot * 23 + revision * 17 + pixel * 59) % 251),
                    UInt8((slot * 31 + revision * 53 + pixel * 19) % 251), 255,
                ]
            }
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: 8)
            }
            return texture
        }
        let samplers = try (0 ..< count).map { slot -> MTLSamplerState in
            let descriptor = MTLSamplerDescriptor()
            let mode = (slot + revision) % 4
            descriptor.minFilter = mode & 1 == 0 ? .nearest : .linear
            descriptor.magFilter = descriptor.minFilter
            descriptor.sAddressMode = mode & 2 == 0 ? .clampToEdge : .repeat
            descriptor.tAddressMode = descriptor.sAddressMode
            return try #require(device.makeSamplerState(descriptor: descriptor))
        }
        return Draw(count: count, textures: textures, samplers: samplers)
    }

    private func pipeline(device: MTLDevice, count: Int, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let arguments = (0 ..< count).map {
            "texture2d<float> t\($0) [[texture(\($0))]], sampler s\($0) [[sampler(\($0))]]"
        }.joined(separator: ", ")
        let reads = (0 ..< count).map {
            "if (slot == \($0)) return t\($0).sample(s\($0), uv);"
        }.joined(separator: "\n")
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct BindingVertexOut { float4 position [[position]]; };
        vertex BindingVertexOut binding_vertex(uint id [[vertex_id]]) {
            float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
            return { float4(p[id], 0, 1) };
        }
        fragment float4 binding_fragment(float4 position [[position]]\(arguments.isEmpty ? "" : ", " + arguments)) {
            uint slot = min(uint(position.x * \(count).0 / 64.0), uint(\(max(count - 1, 0))));
            float2 uv = position.xy / float2(3.0, 5.0) - 0.4;
            \(reads)
            return float4(0.25, 0.5, 0.75, 1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try #require(library.makeFunction(name: "binding_vertex"))
        descriptor.fragmentFunction = try #require(library.makeFunction(name: "binding_fragment"))
        descriptor.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func render(
        device: MTLDevice, draws: [Draw], pipelines: [Int: MTLRenderPipelineState],
        format: MTLPixelFormat, batched: Bool
    ) throws -> [UInt8] {
        let height = draws.count * 8
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: 64, height: height, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        let table = WPEMetalTextureSlotTable()
        for (index, draw) in draws.enumerated() {
            table.reset()
            try encoder.setRenderPipelineState(#require(pipelines[draw.count]))
            encoder.setScissorRect(MTLScissorRect(x: 0, y: index * 8, width: 64, height: 8))
            for slot in 0 ..< draw.count {
                table.set(texture: draw.textures[slot], samplingDescriptor: nil,
                          sampler: draw.samplers[slot], at: slot)
                if !batched {
                    encoder.setFragmentTexture(draw.textures[slot], index: slot)
                    encoder.setFragmentSamplerState(draw.samplers[slot], index: slot)
                }
            }
            if batched {
                // Reset must also support clearing a previously populated range with nil.
                // The zero-slot shader does not sample these unbound resources.
                if draw.count == 0 {
                    table.bindFragmentResources(to: encoder, count: table.slotCount)
                }
                table.bindFragmentResources(to: encoder, count: draw.count)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        let bytesPerRow = 64 * (format == .rgba16Float ? 8 : 4)
        let buffer = try #require(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 64, height: height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length))
    }

    @Test("Batch bindings preserve real texture and sampler reads across changing ranges",
          arguments: [1, 3, 9, 16], [MTLPixelFormat.rgba8Unorm, .rgba16Float])
    func batchMatchesIndividual(count: Int, format: MTLPixelFormat) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let draws = try [16, count, 16].enumerated().map {
            try makeDraw(device: device, count: $0.element, revision: $0.offset)
        }
        var pipelines: [Int: MTLRenderPipelineState] = [:]
        for size in Set(draws.map(\.count)) {
            pipelines[size] = try pipeline(device: device, count: size, format: format)
        }
        let reference = try render(device: device, draws: draws, pipelines: pipelines, format: format, batched: false)
        let actual = try render(device: device, draws: draws, pipelines: pipelines, format: format, batched: true)
        #expect(actual == reference)
        #expect(Set(actual).count > 8)
        // Negative controls prove the fixture observes both resource and sampler identity.
        let wrongTextures = draws.map { Draw(count: $0.count, textures: Array($0.textures.reversed()), samplers: $0.samplers) }
        #expect(try render(device: device, draws: wrongTextures, pipelines: pipelines, format: format, batched: true) != reference)
        let wrongSamplers = draws.map {
            Draw(count: $0.count, textures: $0.textures,
                 samplers: Array($0.samplers.dropFirst()) + [$0.samplers[0]])
        }
        #expect(try render(device: device, draws: wrongSamplers, pipelines: pipelines, format: format, batched: true) != reference)
    }

    @Test("Zero declared slots leave a texture-free fragment valid after scratch reset")
    func zeroSlots() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let draw = Draw(count: 0, textures: [], samplers: [])
        let format = MTLPixelFormat.rgba8Unorm
        let pipelines = try [
            0: pipeline(device: device, count: 0, format: format),
            16: pipeline(device: device, count: 16, format: format),
        ]
        let populated = try makeDraw(device: device, count: 16, revision: 1)
        let result = try render(device: device, draws: [populated, draw], pipelines: pipelines,
                                format: format, batched: true)
        #expect(Array(result[2048 ..< 2052]) == [64, 128, 191, 255])
    }
}

@Suite("WPE draw-local texture metadata")
struct WPEMetalDrawTextureMetadataTests {
    private func texture(device: MTLDevice, width: Int = 8, height: Int = 4) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func pass() -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: WPERenderPass(
                id: "metadata", phase: .effect(file: "effects/metadata/effect.json"),
                shader: "effects/metadata", source: .image("base"), target: .scene,
                textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled",
                cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
            ),
            shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]
        )
    }

    private func packed(
        executor: WPEMetalRenderExecutor, table: WPEMetalTextureSlotTable, slots: [Int] = [0]
    ) -> [SIMD4<Float>] {
        let layout = slots.enumerated().map {
            WPEUniformSlot(name: "g_Texture\($0.element)Resolution", glslType: "vec4", slot: $0.offset, slotCount: 1)
        }
        return executor.packTranslatedUniforms(for: pass(), layout: layout, texturesBySlot: table)
    }

    @Test("Snapshot keeps logical dimensions and the same four sampler states",
          arguments: [false, true], [false, true])
    func samplingAndResolution(clamp: Bool, nearest: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let texture = try texture(device: device)
        let registry = WPEMetalTextureMetadataRegistry.shared
        registry.register(texture: texture, imageWidth: 5, imageHeight: 3, clampUVs: clamp,
                          noInterpolation: nearest, worldWidth: 17, worldHeight: 11)
        let snapshot = registry.resolution(for: texture)
        let sampler = executor.customShaderSamplerState(resolution: snapshot)
        #expect(sampler === executor.customShaderSamplerState(for: texture))
        #if DEBUG
        #expect(executor.customShaderSamplerDescription(resolution: snapshot)
            == executor.customShaderSamplerDescription(for: texture))
        #endif
        #expect(snapshot.worldWidth == 17)
        #expect(snapshot.worldHeight == 11)
        let table = WPEMetalTextureSlotTable()
        table.set(texture: texture, samplingDescriptor: nil, sampler: sampler, resolution: snapshot, at: 0)
        let reference = WPEMetalTextureSlotTable()
        reference[0] = texture // The existing, uncached registry fallback.
        #expect(packed(executor: executor, table: table) == packed(executor: executor, table: reference))
        #expect(packed(executor: executor, table: table) == [SIMD4<Float>(8, 4, 5, 3)])
        #expect(table.resolution(at: 0) == snapshot)
        #expect(executor.customShaderSamplerState(resolution: nil) === executor.customShaderSamplerState(for: nil))
    }

    @Test("New draw registration, removal and resource replacement cannot retain old metadata")
    func mutationsAtDrawBoundaries() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let first = try texture(device: device)
        let second = try texture(device: device, width: 12, height: 6)
        let registry = WPEMetalTextureMetadataRegistry.shared
        let table = WPEMetalTextureSlotTable()
        for logicalWidth in [5, 7] {
            registry.register(texture: first, imageWidth: logicalWidth, imageHeight: 3,
                              clampUVs: false, noInterpolation: true)
            table.reset()
            let snapshot = registry.resolution(for: first)
            table.set(texture: first, samplingDescriptor: nil,
                      sampler: executor.customShaderSamplerState(resolution: snapshot), resolution: snapshot, at: 0)
            #expect(packed(executor: executor, table: table) == [SIMD4<Float>(8, 4, Float(logicalWidth), 3)])
        }
        registry.unregister(texture: first)
        table.reset()
        let unregistered = registry.resolution(for: first)
        table.set(texture: first, samplingDescriptor: nil, resolution: unregistered, at: 0)
        #expect(unregistered.clampUVs && !unregistered.noInterpolation)
        #expect(packed(executor: executor, table: table) == [SIMD4<Float>(8, 4, 8, 4)])
        table[0] = second
        #expect(table.resolution(at: 0) == nil)
        #expect(packed(executor: executor, table: table) == [SIMD4<Float>(12, 6, 12, 6)])
        table.set(texture: first, samplingDescriptor: nil, resolution: unregistered, at: 0)
        table.set(texture: second, samplingDescriptor: nil, at: 0)
        #expect(table.resolution(at: 0) == nil)
        #expect(packed(executor: executor, table: table) == [SIMD4<Float>(12, 6, 12, 6)])
        table.set(texture: nil, samplingDescriptor: nil, resolution: unregistered, at: 0)
        #expect(table.resolution(at: 0) == nil)
        #expect(packed(executor: executor, table: table) == [SIMD4<Float>(repeating: 0)])
        #expect(table.resolution(at: -1) == nil)
        #expect(table.resolution(at: table.slotCount) == nil)
    }

    @Test("One atlas texture preserves independent per-slot TEXS transforms")
    func atlasTransformsStayPerSlot() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let texture = try texture(device: device)
        let snapshot = WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
        let first = WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.5, 0.125, -0.25, 0.75), translation: SIMD2<Float>(0.375, 0.625)
        )
        let second = WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.25, -0.5, 0.125, 0.375), translation: SIMD2<Float>(0.75, 0.125)
        )
        let table = WPEMetalTextureSlotTable()
        table.set(texture: texture, samplingDescriptor: first, resolution: snapshot, at: 0)
        table.set(texture: texture, samplingDescriptor: second, resolution: snapshot, at: 1)
        let layout = [
            WPEUniformSlot(name: "g_Texture0Rotation", glslType: "vec4", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "g_Texture1Rotation", glslType: "vec4", slot: 1, slotCount: 1),
            WPEUniformSlot(name: "g_Texture0Translation", glslType: "vec2", slot: 2, slotCount: 1),
            WPEUniformSlot(name: "g_Texture1Translation", glslType: "vec2", slot: 3, slotCount: 1),
        ]
        let values = executor.packTranslatedUniforms(for: pass(), layout: layout, texturesBySlot: table)
        #expect(values == [first.rotation, second.rotation,
                           SIMD4<Float>(first.translation.x, first.translation.y, 0, 0),
                           SIMD4<Float>(second.translation.x, second.translation.y, 0, 0)])
        #expect(packed(executor: executor, table: table, slots: [0, 1])
            == [SIMD4<Float>(8, 4, 8, 4), SIMD4<Float>(8, 4, 8, 4)])
        table.reset()
        #expect(table.resolution(at: 0) == nil && table.resolution(at: 1) == nil)
        #expect(table.samplingDescriptor(at: 0) == nil && table.samplingDescriptor(at: 1) == nil)
    }
}

@Suite("WPE derived uniform direct packing")
struct WPEMetalDerivedUniformPackingTests {
    private let canonicalNames = [
        "g_TexelSize", "g_TexelSizeHalf", "g_Screen", "g_Texture0Resolution",
        "g_Texture0Rotation", "g_Texture0Translation", "g_Texture1Rotation", "g_Texture1Translation",
    ]

    private func layout() -> [WPEUniformSlot] {
        let types = ["vec2", "vec2", "vec3", "vec4", "vec4", "vec2", "vec4", "vec2"]
        return zip(canonicalNames, types).enumerated().map {
            WPEUniformSlot(name: $0.element.0, glslType: $0.element.1, slot: $0.offset, slotCount: 1,
                           defaultValue: .vector([71, 72, 73, 74]))
        } + [WPEUniformSlot(name: "u_User", glslType: "vec4", slot: 9, slotCount: 1)]
    }

    private func pass() -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: WPERenderPass(
                id: "derived", phase: .effect(file: "effects/derived/effect.json"),
                shader: "effects/derived", source: .image("base"), target: .scene,
                textures: [:], binds: [:], constants: ["g_Texture1Rotation": .vector([51, 52, 53, 54])],
                combos: [:], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
            ),
            shader: nil, textureBindings: [:], comboValues: [:],
            uniformValues: ["g_TexelSize": .vector([31, 32]), "u_User": .vector([1, 2, 3, 4])]
        )
    }

    private func table(device: MTLDevice, snapshot: Bool) throws -> WPEMetalTextureSlotTable {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 128, height: 64, mipmapped: false
        )
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let registry = WPEMetalTextureMetadataRegistry.shared
        registry.register(texture: texture, imageWidth: 125, imageHeight: 61, clampUVs: false,
                          noInterpolation: false, worldWidth: 300, worldHeight: 200)
        let table = WPEMetalTextureSlotTable()
        for slot in 0 ... 1 {
            let transform = WPETexSpriteSamplingDescriptor(
                rotation: SIMD4<Float>(0.25, -0.5, Float(slot), 0.75),
                translation: SIMD2<Float>(Float(slot) / 2, 0.375)
            )
            table.set(texture: texture, samplingDescriptor: transform,
                      resolution: snapshot ? registry.resolution(for: texture) : nil, at: slot)
        }
        return table
    }

    private func bytes(_ values: [SIMD4<Float>]) -> [UInt8] {
        values.withUnsafeBytes { Array($0) }
    }

    @discardableResult
    private func compare(executor: WPEMetalRenderExecutor, layout: [WPEUniformSlot],
                         table: WPEMetalTextureSlotTable?) -> [SIMD4<Float>] {
        executor.derivedUniformPackingEnabled = false
        let reference = executor.packTranslatedUniforms(for: pass(), layout: layout, texturesBySlot: table)
        executor.derivedUniformPackingEnabled = true
        let actual = executor.packTranslatedUniforms(for: pass(), layout: layout, texturesBySlot: table)
        #expect(bytes(actual) == bytes(reference))
        return actual
    }

    @Test("Six canonical sources match legacy bytes, including unclaimed slots", arguments: [false, true])
    func canonicalSources(snapshot: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.setCurrentScenePixelSizeForTesting(CGSize(width: 3841, height: 2161))
        let layout = layout()
        let table = try table(device: device, snapshot: snapshot)
        let actual = compare(executor: executor, layout: layout, table: table)
        #expect(executor.uniformPlans(for: pass(), layout: layout).compactMap(\.directPacking).count == 8)
        #expect(actual[0] == SIMD4<Float>(Float(1.0 / 3841), Float(1.0 / 2161), 0, 0))
        #expect(actual[1] == SIMD4<Float>(Float(0.5 / 3841), Float(0.5 / 2161), 0, 0))
        #expect(actual[2] == SIMD4<Float>(3841, 2161, Float(3841.0 / 2161), 0))
        #expect(actual[3] == SIMD4<Float>(128, 64, 125, 61))
        #expect(actual[4] != actual[6] && actual[5] != actual[7])
        #expect(actual[8] == .zero && actual[9] == SIMD4<Float>(1, 2, 3, 4))
        var storage = [SIMD4<Float>](repeating: SIMD4<Float>(repeating: 99), count: actual.count + 2)
        storage.withUnsafeMutableBufferPointer {
            let region = UnsafeMutableBufferPointer(rebasing: $0[1 ..< (actual.count + 1)])
            region.update(repeating: .zero)
            executor.packTranslatedUniformSlots(for: pass(), layout: layout, texturesBySlot: table, into: region)
        }
        #expect(bytes(Array(storage[1 ..< (actual.count + 1)])) == bytes(actual))
        #expect(storage.first == SIMD4<Float>(repeating: 99) && storage.last == SIMD4<Float>(repeating: 99))
    }

    @Test("Degenerate scene and missing resources preserve authored, constant and default fallbacks")
    func fallbackAndNonfiniteSources() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let table = try table(device: device, snapshot: false)
        for size in [CGSize.zero, CGSize(width: -1, height: 2), CGSize(width: CGFloat.nan, height: 2),
                     CGSize(width: CGFloat.infinity, height: CGFloat.infinity), CGSize(width: 3840, height: 2160)] {
            executor.setCurrentScenePixelSizeForTesting(size)
            compare(executor: executor, layout: layout(), table: table)
            let missing = compare(executor: executor, layout: layout(), table: nil)
            #expect(missing[3] == SIMD4<Float>(71, 72, 73, 74))
            #expect(missing[6] == SIMD4<Float>(51, 52, 53, 54))
            if !(size.width > 0 && size.height > 0) {
                #expect(missing[0] == SIMD4<Float>(31, 32, 0, 0))
                #expect(missing[1] == SIMD4<Float>(71, 72, 0, 0))
            }
        }
        let texture = try #require(table[0])
        table.set(texture: texture, samplingDescriptor: WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(-0.0, .infinity, -.infinity, Float(bitPattern: 0x7FC0_1234)),
            translation: SIMD2<Float>(-0.0, Float(bitPattern: 0x7FC0_5678))
        ), at: 1)
        compare(executor: executor, layout: layout(), table: table)
        table.set(texture: texture, samplingDescriptor: WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(Float(bitPattern: 0x7F80_1234), Float(bitPattern: 0xFFC0_5678),
                                   Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude),
            translation: SIMD2<Float>(Float(bitPattern: 0xFF80_1234), -0.0)
        ), at: 1)
        compare(executor: executor, layout: layout(), table: table)
        table.set(texture: texture, samplingDescriptor: WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(Float(bitPattern: 0xFFC0_5678), Float.leastNonzeroMagnitude,
                                   -Float.leastNonzeroMagnitude, -0.0),
            translation: SIMD2<Float>(Float.leastNonzeroMagnitude, Float(bitPattern: 0xFFC0_1234))
        ), at: 1)
        #expect(executor.directUniformVector(.textureRotation(1), texturesBySlot: table) != nil)
        #expect(executor.directUniformVector(.textureTranslation(1), texturesBySlot: table) != nil)
        compare(executor: executor, layout: layout(), table: table)
        for bits: UInt32 in [0x7F80_1234, 0xFF80_1234] {
            for lane in 0 ..< 4 {
                var rotation = SIMD4<Float>(1, 2, 3, 4)
                rotation[lane] = Float(bitPattern: bits)
                table.set(texture: texture, samplingDescriptor: WPETexSpriteSamplingDescriptor(
                    rotation: rotation, translation: SIMD2<Float>(5, 6)
                ), at: 1)
                #expect(executor.directUniformVector(.textureRotation(1), texturesBySlot: table) == nil)
                compare(executor: executor, layout: layout(), table: table)
            }
            for lane in 0 ..< 2 {
                var translation = SIMD2<Float>(5, 6)
                translation[lane] = Float(bitPattern: bits)
                table.set(texture: texture, samplingDescriptor: WPETexSpriteSamplingDescriptor(
                    rotation: SIMD4<Float>(1, 2, 3, 4), translation: translation
                ), at: 1)
                #expect(executor.directUniformVector(.textureTranslation(1), texturesBySlot: table) == nil)
                compare(executor: executor, layout: layout(), table: table)
            }
        }
        table[1] = texture // Same texture, but this new binding no longer has TEXS metadata.
        let missingTEXS = compare(executor: executor, layout: layout(), table: table)
        #expect(missingTEXS[6] == SIMD4<Float>(51, 52, 53, 54))
        #expect(missingTEXS[7] == SIMD4<Float>(71, 72, 0, 0))
    }

    @Test("Noncanonical declarations and arrays remain on the legacy path across layout invalidation")
    func noncanonicalDeclarations() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.setCurrentScenePixelSizeForTesting(CGSize(width: 3841, height: 2161))
        let table = try table(device: device, snapshot: true)
        for original in layout().prefix(8) {
            for type in ["float", "vec2", "vec3", "vec4", "ivec4", "mat2"] where type != original.glslType {
                let declaration = WPEUniformSlot(name: original.name, glslType: type, slot: 0,
                                                 slotCount: type == "mat2" ? 2 : 1)
                compare(executor: executor, layout: [declaration], table: table)
                #expect(executor.uniformPlans(for: pass(), layout: [declaration])[0].directPacking == nil)
            }
            for declaration in [
                WPEUniformSlot(name: original.name, glslType: original.glslType, slot: 0, slotCount: 2, arrayLength: 2),
                WPEUniformSlot(name: original.name, glslType: original.glslType, slot: 0, slotCount: 2),
                WPEUniformSlot(name: original.name.lowercased(), glslType: original.glslType, slot: 0, slotCount: 1),
            ] {
                compare(executor: executor, layout: [declaration], table: table)
                #expect(executor.uniformPlans(for: pass(), layout: [declaration])[0].directPacking == nil)
            }
        }
        compare(executor: executor, layout: layout(), table: table)
        #expect(executor.uniformPlans(for: pass(), layout: layout()).compactMap(\.directPacking).count == 8)
    }

    @Test("Real packing A/B microbenchmark consumes output and includes Hina-like and ordinary layouts")
    func packingMicrobenchmark() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let table = try table(device: device, snapshot: true)
        let pass = pass()
        let environment = ProcessInfo.processInfo.environment
        let iterations = min(max(Int(environment["WPE_DERIVED_UNIFORM_BENCH_ITERATIONS"] ?? "64") ?? 64, 1), 100_000)
        let mixed = (0 ..< 293).map { index in
            WPEUniformSlot(name: index < 55 ? "g_Texture0Resolution" : (index < 63 ? "g_TexelSize" : "u_User"),
                           glslType: (55 ..< 63).contains(index) ? "vec2" : "vec4", slot: index, slotCount: 1)
        }
        let ordinary = (0 ..< 293).map { WPEUniformSlot(name: "u_User", glslType: "vec4", slot: $0, slotCount: 1) }
        var results: [[String: Any]] = []
        for (name, layout) in [("derived", layout()), ("hina_mix", mixed), ("ordinary", ordinary)] {
            let count = WPEMetalRenderExecutor.translatedSlotCount(for: layout)
            let storage = UnsafeMutableBufferPointer<SIMD4<Float>>.allocate(capacity: count)
            storage.initialize(repeating: .zero)
            defer { storage.deinitialize(); storage.deallocate() }
            func run(enabled: Bool, iterations: Int) -> (UInt64, UInt64) {
                executor.derivedUniformPackingEnabled = enabled
                var checksum: UInt64 = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for iteration in 0 ..< iterations {
                    executor.setCurrentScenePixelSizeForTesting(CGSize(width: 3840 + iteration % 2, height: 2160 + iteration % 3))
                    storage.update(repeating: .zero)
                    executor.packTranslatedUniformSlots(for: pass, layout: layout, texturesBySlot: table, into: storage)
                    for value in storage {
                        checksum = checksum &+ UInt64(value.x.bitPattern) &+ UInt64(value.y.bitPattern)
                        checksum = checksum &+ UInt64(value.z.bitPattern) &+ UInt64(value.w.bitPattern)
                    }
                }
                return (DispatchTime.now().uptimeNanoseconds - start, checksum)
            }
            #expect(run(enabled: false, iterations: 8).1 == run(enabled: true, iterations: 8).1)
            var expected: UInt64?
            for block in 0 ..< 12 {
                let enabled = block % 4 == 1 || block % 4 == 2 // ABBA, repeated three times.
                let (elapsed, checksum) = run(enabled: enabled, iterations: iterations)
                if let expected {
                    #expect(checksum == expected)
                } else {
                    expected = checksum
                }
                results.append(["layout": name, "direct": enabled, "block": block,
                                "iterations": iterations, "elapsedNs": elapsed, "checksum": String(checksum)])
            }
        }
        if let output = environment["WPE_DERIVED_UNIFORM_BENCH_OUTPUT"], !output.isEmpty {
            #if DEBUG
            let configuration = "Debug"
            #else
            let configuration = "Release"
            #endif
            // Payload only: excludes ContiguousArray storage headers, capacity rounding and allocator overhead.
            let scratchPayloadBytes = 16 * (MemoryLayout<MTLSamplerState?>.stride
                + MemoryLayout<WPEMetalTextureResolution?>.stride)
            let report: [String: Any] = [
                "configuration": configuration, "blocks": results,
                "priorBatchMetadataScratchPayloadBytes": scratchPayloadBytes,
                "uniformResolutionPlanStride": MemoryLayout<WPEMetalRenderExecutor.UniformResolutionPlan>.stride,
                "scope": "Synthetic packing only; hina_mix matches the 63/293 declaration ratio, not real frame timing",
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
#endif
