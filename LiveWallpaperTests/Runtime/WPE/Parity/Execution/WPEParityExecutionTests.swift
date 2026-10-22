#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

final class WPEParityExecutionTests: XCTestCase {
    private static let side = 4

    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let factory: WPEParityPipelineFactory
        let encoder: WPEParityDrawEncoder
        let arena: WPEParityFrameArena
    }

    // MARK: Tests

    func testTextureDimensionValidationRejectsTwoDForOtherShaderViews() throws {
        for dimension in [WPEStageReflection.Resource.Dimension.texture3D, .texture2DArray, .cube, .texture2DMS, .none] {
            let resource = WPEStageReflection.Resource(name: "texture", kind: .texture, register: 0, space: 0,
                                                       dimension: dimension, count: 1)
            XCTAssertThrowsError(try WPEParityDrawEncoder.validateDimension(resource, textureType: .type2D))
        }
        for (dimension, type) in [(WPEStageReflection.Resource.Dimension.texture2D, MTLTextureType.type2D),
                                  (.texture2DMS, .type2DMultisample), (.texture3D, .type3D),
                                  (.texture2DArray, .type2DArray), (.cube, .typeCube)] {
            try WPEParityDrawEncoder.validateDimension(.init(name: "texture", kind: .texture, register: 0, space: 0,
                                                             dimension: dimension, count: 1), textureType: type)
        }
    }

    func testPassthroughCopiesInputTexture() throws {
        let harness = try makeHarness()
        let artifact = try loadProgram("shaders/passthrough")
        let pipeline = try harness.factory.makePipeline(
            artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha), colorPixelFormat: .rgba8Unorm
        )
        var texels: [UInt8] = []
        for y in 0 ..< Self.side {
            for x in 0 ..< Self.side {
                texels += [UInt8(x * 60 + 10), UInt8(y * 60 + 20), UInt8((x + y) * 30 + 5), UInt8(255 - (x * 4 + y) * 10)]
            }
        }
        let input = try makeInputTexture(harness.device, texels: texels)
        // VS_INPUT: float3 POSITION0, float2 TEXCOORD0; D3D texcoord v=0 is the top row.
        let vertices: [Float] = [-1, 1, 0, 0, 0, -1, -1, 0, 0, 1, 1, 1, 0, 1, 0, 1, -1, 0, 1, 1]
        var draw = try makeDraw(harness, pipeline: pipeline, vertices: vertices)
        draw.textures = ["g_Texture0": input]
        draw.samplers = ["g_Texture0SamplerState": .wpe(filter: .point, address: .clamp)]

        XCTAssertThrowsError(try harness.encoder.prepare(pipeline: pipeline, depthStencil: draw.depthStencil,
                                                         textureNames: ["g_Texture0"], samplers: [:])) { error in
            XCTAssertEqual(error as? WPEParityExecutionError, .missingSampler("g_Texture0SamplerState"))
        }
        try harness.encoder.prepare(pipeline: pipeline, depthStencil: draw.depthStencil,
                                    textureNames: Set(draw.textures.keys), samplers: draw.samplers)

        let target = try makeTarget(harness.device)
        try renderAndWait(harness, draw: draw, target: target)
        let output = try readBack(harness, target: target)
        XCTAssertEqual(output.count, texels.count)
        for (index, pair) in zip(output, texels).enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), 1, "byte \(index)")
        }
    }

    func testFlatColourComesFromPackedCBuffer() throws {
        let harness = try makeHarness()
        let artifact = try loadProgram("shaders/flat")
        // PS: OUT.gl_FragColor = vec4(g_Color, g_Alpha).
        let expected: [UInt8] = [51, 102, 204, 153]

        let pipeline = try harness.factory.makePipeline(
            artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha), colorPixelFormat: .rgba8Unorm
        )
        let output = try renderFlat(harness, pipeline: pipeline, color: SIMD3(0.2, 0.4, 0.8), alpha: 0.6)
        assertEvery(output, equals: expected)

        // Control: the same values packed 16 bytes past where the shader reads them.
        let shifted = try shiftingCBuffers(of: artifact.fragment.reflection, by: 16)
        let shiftedArtifact = WPEParityShaderArtifact(
            vertex: artifact.vertex,
            fragment: .init(metallib: artifact.fragment.metallib, reflection: shifted,
                            functionName: artifact.fragment.functionName),
            geometry: nil
        )
        let shiftedPipeline = try harness.factory.makePipeline(
            artifact: shiftedArtifact, blend: .wpe(.normal, modifiers: .writeAlpha), colorPixelFormat: .rgba8Unorm
        )
        let control = try renderFlat(harness, pipeline: shiftedPipeline, color: SIMD3(0.2, 0.4, 0.8), alpha: 0.6)
        let matches = stride(from: 0, to: control.count, by: 4).allSatisfy { start in
            zip(control[start ..< start + 4], expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
        XCTAssertFalse(matches, "output still matched with the cbuffer written at the wrong offset")
    }

    func testFourthFrameWaitsForAnArenaSlot() throws {
        let harness = try makeHarness()
        let artifact = try loadProgram("shaders/flat")
        let pipeline = try harness.factory.makePipeline(
            artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha), colorPixelFormat: .rgba8Unorm
        )
        let target = try makeTarget(harness.device)

        var inFlight: [MTLCommandBuffer] = []
        var released: [XCTestExpectation] = []
        for index in 0 ..< WPEParityFrameArena.slotCount {
            let commandBuffer = try XCTUnwrap(harness.queue.makeCommandBuffer())
            let frame = try XCTUnwrap(harness.arena.beginFrame(for: commandBuffer), "slot \(index)")
            // Completed handlers run in registration order, so this one fires after the arena's release.
            let expectation = expectation(description: "frame \(index) completed")
            commandBuffer.addCompletedHandler { _ in expectation.fulfill() }
            try encodePass(harness, draw: flatDraw(harness, pipeline: pipeline, color: SIMD3(1, 0, 0), alpha: 1),
                           target: target, frame: frame, commandBuffer: commandBuffer)
            inFlight.append(commandBuffer)
            released.append(expectation)
        }

        let fourth = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertNil(harness.arena.beginFrame(for: fourth), "a fourth slot was handed out while three frames were in flight")

        inFlight.forEach { $0.commit() }
        wait(for: released, timeout: 10)
        for commandBuffer in inFlight {
            XCTAssertNil(commandBuffer.error)
        }

        let frame = try XCTUnwrap(harness.arena.beginFrame(for: fourth), "no slot after the first frames completed")
        try encodePass(harness, draw: flatDraw(harness, pipeline: pipeline, color: SIMD3(0.8, 0.4, 0.2), alpha: 1),
                       target: target, frame: frame, commandBuffer: fourth)
        fourth.commit()
        fourth.waitUntilCompleted()
        XCTAssertNil(fourth.error)
        try assertEvery(readBack(harness, target: target), equals: [204, 102, 51, 255])
    }

    // MARK: Fixture

    private func fixtureDirectory() throws -> URL {
        guard let url = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        return url
    }

    private struct ManifestEntry: Decodable {
        let n: Int
        let name: String
    }

    /// First `.vert` / `.frag` manifest entries for `name`.
    private func loadProgram(_ name: String) throws -> WPEParityShaderArtifact {
        let directory = try fixtureDirectory()
        let manifest = try JSONDecoder().decode(
            [ManifestEntry].self, from: Data(contentsOf: directory.appending(path: "manifest.json"))
        )
        let vertex = try XCTUnwrap(manifest.first { $0.name == name + ".vert" }).n
        let fragment = try XCTUnwrap(manifest.first { $0.name == name + ".frag" }).n
        return try WPEParityShaderArtifact(
            vertex: loadStage(vertex, in: directory), fragment: loadStage(fragment, in: directory), geometry: nil
        )
    }

    private func loadStage(_ number: Int, in directory: URL) throws -> WPEParityShaderArtifact.Stage {
        let compiled = directory.appending(path: "compiled")
        let json = try Data(contentsOf: compiled.appending(path: "\(number).json"))
        let reflection = try JSONDecoder().decode(WPEStageReflection.self, from: WPEParityFixtureShaderCompiler.fillingVertexInputs(json))
        return try WPEParityShaderArtifact.Stage(
            metallib: Data(contentsOf: compiled.appending(path: "\(number).metallib")),
            reflection: reflection,
            functionName: reflection.entry
        )
    }

    private func shiftingCBuffers(of reflection: WPEStageReflection, by delta: Int) throws -> WPEStageReflection {
        let cbuffers = reflection.cbuffers.map { cbuffer in
            WPEStageReflection.CBuffer(
                name: cbuffer.name, register: cbuffer.register, space: cbuffer.space, size: cbuffer.size + delta,
                variables: cbuffer.variables.map {
                    .init(name: $0.name, offset: $0.offset + delta, size: $0.size, baseType: $0.baseType,
                          class: $0.class, rows: $0.rows, columns: $0.columns, elements: $0.elements, used: $0.used)
                }
            )
        }
        return WPEStageReflection(
            schema: reflection.schema, stage: reflection.stage, entry: reflection.entry, cbuffers: cbuffers,
            resources: reflection.resources, topLevelArgumentBuffer: reflection.topLevelArgumentBuffer,
            vertexInputs: reflection.vertexInputs, stageOutputs: reflection.stageOutputs,
            mscReflection: reflection.mscReflection
        )
    }

    // MARK: Metal helpers

    private func makeHarness() throws -> Harness {
        _ = try fixtureDirectory()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let factory = WPEParityPipelineFactory(device: device)
        return try Harness(
            device: device,
            queue: XCTUnwrap(device.makeCommandQueue()),
            factory: factory,
            encoder: WPEParityDrawEncoder(factory: factory),
            arena: XCTUnwrap(WPEParityFrameArena(device: device, capacity: 64 * 1024))
        )
    }

    private func makeDraw(_ harness: Harness, pipeline: WPEParityPipeline, vertices: [Float]) throws -> WPEParityDraw {
        let buffer = try XCTUnwrap(harness.device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: .storageModeShared
        ))
        return WPEParityDraw(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: buffer,
            primitiveType: .triangleStrip,
            vertexCount: 4
        )
    }

    private func flatDraw(_ harness: Harness, pipeline: WPEParityPipeline,
                          color: SIMD3<Float>, alpha: Float) throws -> WPEParityDraw {
        // VS_INPUT: float3 POSITION0, float4 COLOR0.
        let corners: [(Float, Float)] = [(-1, 1), (-1, -1), (1, 1), (1, -1)]
        var draw = try makeDraw(harness, pipeline: pipeline, vertices: corners.flatMap { [$0.0, $0.1, 0, 1, 1, 1, 1] })
        let identity = WPEFloatMatrix(columns: (0 ..< 4).map { column in
            SIMD4<Float>((0 ..< 4).map { $0 == column ? 1 : 0 })
        })
        let constants: [String: WPECBufferValue] = [
            "g_ModelViewProjectionMatrix": .matrix(identity),
            "g_Color": .vector([color.x, color.y, color.z]),
            "g_Alpha": .float(alpha),
        ]
        draw.constants = [.vertex: constants, .fragment: constants]
        return draw
    }

    private func renderFlat(_ harness: Harness, pipeline: WPEParityPipeline,
                            color: SIMD3<Float>, alpha: Float) throws -> [UInt8] {
        let target = try makeTarget(harness.device)
        try renderAndWait(harness, draw: flatDraw(harness, pipeline: pipeline, color: color, alpha: alpha), target: target)
        return try readBack(harness, target: target)
    }

    private func makeInputTexture(_ device: MTLDevice, texels: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Self.side, height: Self.side, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, Self.side, Self.side), mipmapLevel: 0,
                        withBytes: texels, bytesPerRow: Self.side * 4)
        return texture
    }

    private func makeTarget(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Self.side, height: Self.side, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func encodePass(_ harness: Harness, draw: WPEParityDraw, target: MTLTexture,
                            frame: WPEParityFrameArena.Frame, commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        try harness.encoder.encode(draw, frame: frame, hasDepthAttachment: false, on: encoder)
        encoder.endEncoding()
    }

    private func renderAndWait(_ harness: Harness, draw: WPEParityDraw, target: MTLTexture) throws {
        let commandBuffer = try XCTUnwrap(harness.queue.makeCommandBuffer())
        let frame = try XCTUnwrap(harness.arena.beginFrame(for: commandBuffer))
        try encodePass(harness, draw: draw, target: target, frame: frame, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }

    private func readBack(_ harness: Harness, target: MTLTexture) throws -> [UInt8] {
        let length = Self.side * Self.side * 4
        let buffer = try XCTUnwrap(harness.device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(harness.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Self.side, height: Self.side, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: Self.side * 4, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }

    private func assertEvery(_ output: [UInt8], equals pixel: [UInt8], line: UInt = #line) {
        XCTAssertEqual(output.count, Self.side * Self.side * 4, line: line)
        for (index, value) in output.enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(value) - Int(pixel[index % 4])), 1, "byte \(index)", line: line)
        }
    }
}
#endif
