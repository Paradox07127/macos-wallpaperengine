#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// A skinned puppet layer draws its own mesh with integer bone indices and the animator's `g_Bones`.
final class WPEParityPuppetDrawTests: XCTestCase {
    /// A skinned vertex stage as wpe-shaderc (DXC + MSC) reflects it: BLENDINDICES comes back as `uint32`.
    private static let vertexReflection = """
    {"schema":1,"stage":"vertex","entry":"main",
     "cbuffers":[{"name":"g_bufAnimation","register":2,"space":0,"size":96,"variables":[{"name":"g_Bones",
       "offset":0,"size":96,"baseType":"float","class":"matrix_columns","rows":4,"columns":3,"elements":2,
       "used":true}]}],
     "resources":[],"topLevelArgumentBuffer":[{"kind":"cbv","register":2,"space":0,"offset":0,"size":24}],
     "vertexInputs":[{"name":"position0","index":0,"elementType":"float","columns":3},
       {"name":"blendindices0","index":1,"elementType":"uint32","columns":4},
       {"name":"blendweight0","index":2,"elementType":"float","columns":4},
       {"name":"texcoord0","index":3,"elementType":"float","columns":2}],
     "stageOutputs":[],"mscReflection":{}}
    """

    func testBlendIndicesGetAnIntegerVertexFormat() throws {
        let descriptor = try WPEParityPipelineFactory.vertexDescriptor(for: Self.reflection().vertexInputs)
        let start = WPEParityMSCRuntime.stageInAttributeStartIndex
        XCTAssertEqual((0 ..< 4).map { descriptor.attributes[start + $0].format }, [.float3, .uint4, .float4, .float2])
        XCTAssertEqual(descriptor.layouts[WPEParityMSCRuntime.vertexBufferBindPoint].stride, 52)
    }

    /// The encoder's packer puts bone b's math rows 0, 1, 2 (translation in .w) in registers 3b, 3b + 1, 3b + 2.
    func testEncoderPacksEachBoneAsThreeRowRegisters() throws {
        var animator = Self.animator()
        animator.advance(dt: 0.1)
        var packer = try WPECBufferPacker(layout: WPECBufferLayout(Self.reflection().cbuffers[0]))
        try packer.write(XCTUnwrap(animator.values["g_Bones"]), to: "g_Bones")
        let rows = animator.palette[0].transpose
        for register in 0 ..< 3 {
            let packed = (0 ..< 4).map { component in
                packer.bytes.withUnsafeBytes { $0.load(fromByteOffset: register * 16 + component * 4, as: Float.self) }
            }
            XCTAssertEqual(packed, (0 ..< 4).map { rows[register][$0] }, "register \(register)")
        }
        XCTAssertEqual(rows[1].w, 1.6, accuracy: 1e-5, "bone 0 moved 1.6 up from its bind pose")
    }

    func testPuppetMeshIsPackedInReflectionOrder() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let uvMax = SIMD2<Float>(0.5, 0.25)
        let geometry = try XCTUnwrap(WPEParityFrameDrawPlanner.puppetGeometry(
            Self.puppet, uvMax: uvMax, inputs: Self.reflection().vertexInputs, device: device
        ))
        XCTAssertEqual(geometry.indexCount, Self.puppet.indices.count)
        let indices = geometry.indices.contents().assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: indices, count: geometry.indexCount)), Self.puppet.indices)

        // position0 float3, blendindices0 uint4, blendweight0 float4, texcoord0 float2: 13 words per vertex.
        XCTAssertEqual(geometry.vertices.length, 13 * 4 * Self.puppet.vertices.count)
        let words = geometry.vertices.contents().assumingMemoryBound(to: UInt32.self)
        for (index, vertex) in Self.puppet.vertices.enumerated() {
            let packed = Array(UnsafeBufferPointer(start: words + index * 13, count: 13))
            let floats = { (range: Range<Int>) in range.map { Float(bitPattern: packed[$0]) } }
            XCTAssertEqual(floats(0 ..< 3), [vertex.position.x, vertex.position.y, vertex.position.z])
            XCTAssertEqual(Array(packed[3 ..< 7]), (0 ..< 4).map { UInt32(vertex.skinBlendIndices[$0]) })
            XCTAssertEqual(floats(7 ..< 11), (0 ..< 4).map { vertex.skinBlendWeights[$0] })
            XCTAssertEqual(floats(11 ..< 13), [vertex.uv.x * uvMax.x, vertex.uv.y * uvMax.y])
        }
    }

    /// Native table order differs from reflection order. Keep extra semantics, uint precision and NaN bits;
    /// only the albedo UV pair scales. The same buffer then crosses the production Metal vertex descriptor.
    func testNativeVertexStreamPreservesWordsThroughMetalStageIn() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layout = WPEPuppetVertexLayout(format: 0x10000 | 0x2000000 | 2 | 4 | 0x800000 | 0x1000000 | 0x20 | 0x40 | 0x8000)
        let nan: UInt32 = 0x7FC0_1234
        func floats(_ values: [Float]) -> [UInt32] {
            values.map(\.bitPattern)
        }
        var native: [UInt32] = []
        for xy: SIMD2<Float> in [SIMD2(-1, -1), SIMD2(3, -1), SIMD2(-1, 3)] {
            native += floats([xy.x, xy.y, 0, 2])
            native += floats([11, 12, 13])
            native += [nan] + floats([21, 22])
            native += floats([31, 32, 33, 34])
            native += [16_777_217, 0xFFFF_FFFE, 2, 3]
            native += floats([0.25, 0.75, 0, 0])
            native += floats([0.5, 0.25, 0.75, 0.875])
            native += floats([41, 42])
            native += floats([0.1, 0.2, 0.3, 0.4])
        }
        let stream = WPEPuppetVertexStream(data: native.withUnsafeBytes { Data($0) }, layout: layout)
        let names = ["texcoord1", "blendindices0", "position0", "normal0", "texcoord0", "color0",
                     "position1", "tangent0", "blendweight0"]
        let attributes: [[String: Any]] = names.enumerated().map {
            ["name": $0.element, "index": $0.offset, "elementType": $0.offset == 1 ? "uint32" : "float", "columns": 4]
        }
        let inputs = try JSONDecoder().decode([WPEStageReflection.StageAttribute].self,
                                              from: JSONSerialization.data(withJSONObject: attributes))
        let words = try WPEParityFrameDrawPlanner.rawVertexWords(stream, inputs: inputs, uvMax: SIMD2(0.5, 0.25))
        XCTAssertEqual(Array(words[0 ..< 4]), floats([41, 42, 0, 1]))
        XCTAssertEqual(Array(words[4 ..< 8]), [16_777_217, 0xFFFF_FFFE, 2, 3])
        XCTAssertEqual(Array(words[8 ..< 12]), floats([-1, -1, 0, 2]))
        XCTAssertEqual(Array(words[12 ..< 16]), [nan] + floats([21, 22, 1]))
        XCTAssertEqual(Array(words[16 ..< 20]), floats([0.25, 0.0625, 0.75, 0.875]))
        XCTAssertEqual(Array(words[20 ..< 24]), floats([0.1, 0.2, 0.3, 0.4]))
        XCTAssertEqual(Array(words[24 ..< 28]), floats([11, 12, 13, 1]))
        XCTAssertEqual(Array(words[28 ..< 32]), floats([31, 32, 33, 34]))
        XCTAssertEqual(Array(words[32 ..< 36]), floats([0.25, 0.75, 0, 0]))

        let puppet = WPEParityScenePuppet(vertices: [], indices: [0, 1, 2], boneCount: 0, skinned: false,
                                          vertexStream: stream)
        let geometry = try XCTUnwrap(WPEParityFrameDrawPlanner.puppetGeometry(
            puppet, uvMax: SIMD2(0.5, 0.25), inputs: inputs, device: device
        ))
        let start = WPEParityMSCRuntime.stageInAttributeStartIndex
        let library = try await device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct Input {
            uint4 bones [[attribute(\(start + 1))]];
            float4 position [[attribute(\(start + 2))]];
            float4 normal [[attribute(\(start + 3))]];
            float4 uv [[attribute(\(start + 4))]];
        };
        struct Output { float4 position [[position]]; uint4 words [[flat]]; };
        vertex Output nativeVertex(Input in [[stage_in]]) {
            return {float4(in.position.xy, 0, 1),
                    uint4(in.bones.x, as_type<uint>(in.position.w), as_type<uint>(in.uv.z), as_type<uint>(in.normal.x))};
        }
        fragment uint4 nativeFragment(Output in [[stage_in]]) { return in.words; }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "nativeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "nativeFragment")
        descriptor.vertexDescriptor = try WPEParityPipelineFactory.vertexDescriptor(for: inputs)
        descriptor.colorAttachments[0].pixelFormat = .rgba32Uint
        let pipeline = try await device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Uint, width: 1, height: 1, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        textureDescriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(geometry.vertices, offset: 0, index: WPEParityMSCRuntime.vertexBufferBindPoint)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: 3, indexType: .uint16,
                                      indexBuffer: geometry.indices, indexBufferOffset: 0)
        encoder.endEncoding()
        command.commit()
        await command.completed()
        XCTAssertNil(command.error)
        var pixel = [UInt32](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel, [16_777_217, Float(2).bitPattern, Float(0.75).bitPattern, nan])
    }

    func testClipMaskOnlyReplacesSharedRenderVarX() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var plan = try makePlan(device: device, puppetID: nil)
        var state = WPEParityRenderVarState()
        state.rv0 = SIMD4(7, 8, 9, 10)
        state.rv1 = SIMD4(11, 12, 13, 14)
        for inverted in [true, false] {
            plan.clipMaskInverted = inverted
            plan.applyRenderVarWrites(to: &state)
            XCTAssertEqual(state.rv0, SIMD4(inverted ? 1 : 0, 8, 9, 10))
            XCTAssertEqual(state.rv1, SIMD4(11, 12, 13, 14))
            var slots: [String: WPECBufferValue] = [:]
            let draw = try plan.makeDraw(frame: Self.frame(), variant: 0, textures: [:], textureSlots: &slots,
                                         puppets: [:], renderVar0: state.rv0)
            guard case let .vector(value)? = draw.constants[.fragment]?["g_RenderVar0"] else {
                return XCTFail("clip mask has no shared RV0")
            }
            XCTAssertEqual(value, [inverted ? 1 : 0, 8, 9, 10])
        }
    }

    func testNativeStreamRejectsSyntheticPositionAndUnknownFormatBits() {
        for format: UInt32 in [0, 0x8000_0001] {
            let layout = WPEPuppetVertexLayout(format: format)
            let stream = WPEPuppetVertexStream(data: Data(repeating: 0, count: layout.stride), layout: layout)
            XCTAssertThrowsError(try WPEParityFrameDrawPlanner.rawVertexWords(stream, inputs: [])) { error in
                guard case let WPEParityFrameSkip.pipeline(message) = error else {
                    return XCTFail("unexpected readiness error: \(error)")
                }
                XCTAssertTrue(message.contains(format == 0 ? "missing authored POSITION0" : "unsupported"))
            }
        }
    }

    /// Compile the shipped mask shader through the production rewriter/DXC/MSC and draw a half-target mask.
    /// Both its covered pixel and the authored clear outside it must invert, while shared RV0.yzw survive.
    func testShippedClipMaskInvertsCoveredPixelsAndClear() async throws {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let assetsURL = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: assetsURL.appending(path: "shaders/clippingmaskimage4.frag").path) else {
            throw XCTSkip("Needs the shipped WPE clippingmaskimage4 shader")
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "parity-mask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let assets = WPEParityProgramAssets(sources: [.directory(assetsURL)])
        let program = try WPEParityProgramResolver.resolve(
            WPEParityProgramDescription(material: .init(shader: "clippingmaskimage4"),
                                        engineFlags: WPEEngineComboFlags(), boundTextures: [:]), sources: assets
        )
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = WPEParityShaderStore(compiler: compiler,
                                         diskCache: WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cache")))
        let artifact = try await store.artifact(for: WPEParityShaderCompileRequest(
            program: program.hlsl, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.translucent), colorPixelFormat: .r8Unorm)
        let puppet = WPEParityScenePuppet(vertices: [
            .init(position: SIMD3(-1, -1, 0), uv: .zero), .init(position: SIMD3(0, -1, 0), uv: .zero),
            .init(position: SIMD3(-1, 1, 0), uv: .zero), .init(position: SIMD3(0, 1, 0), uv: .zero),
        ], indices: [0, 1, 2, 2, 1, 3], boneCount: 0, skinned: false)
        let geometry = try XCTUnwrap(WPEParityFrameDrawPlanner.puppetGeometry(
            puppet, uvMax: .one, inputs: artifact.vertex.reflection.vertexInputs, device: device
        ))
        func texture(_ pixel: [UInt8]) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1,
                                                                      height: 1, mipmapped: false)
            let made = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            made.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: pixel, bytesPerRow: 4)
            return made
        }
        let sampler = WPEParitySamplerState.wpe(filter: .point, address: .clamp)
        var plan = try WPEParityFrameDrawPlan(
            pipeline: pipeline, depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            geometry: .mesh(vertices: geometry.vertices, indices: geometry.indices, indexCount: geometry.indexCount),
            puppetID: nil, textures: [["g_Texture0": .image(texture([255, 255, 255, 255])),
                                       "g_Texture1": .image(texture([64, 0, 0, 255]))]],
            samplers: ["g_Texture0SamplerState": sampler, "g_Texture1SamplerState": sampler],
            uniforms: WPEParityUniformDraw(matrices: WPEParityUniformMatrices(
                model: matrix_identity_float4x4, view: matrix_identity_float4x4, projection: matrix_identity_float4x4
            )), placement: nil, sprites: [:], constants: [:], renderVarWrites: (nil, nil),
            fallbackTextures: []
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 2, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let arena = try XCTUnwrap(WPEParityFrameArena(device: device, capacity: 65536))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var state = WPEParityRenderVarState()
        state.rv0 = SIMD4(0, 7, 8, 9)
        for inverted in [false, true] {
            plan.clipMaskInverted = inverted
            plan.applyRenderVarWrites(to: &state)
            var slots: [String: WPECBufferValue] = [:]
            let draw = try plan.makeDraw(frame: Self.frame(), variant: 0, textures: [:], textureSlots: &slots,
                                         puppets: [:], renderVar0: state.rv0)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let frame = try XCTUnwrap(arena.beginFrame(for: command))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(inverted ? 1 : 0, 0, 0, 1)
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            try WPEParityDrawEncoder(factory: factory).encode(draw, frame: frame, hasDepthAttachment: false, on: encoder)
            encoder.endEncoding()
            command.commit()
            await command.completed()
            XCTAssertNil(command.error)
            var pixels = [UInt8](repeating: 0, count: 2)
            target.getBytes(&pixels, bytesPerRow: 2, from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
            XCTAssertEqual(pixels, inverted ? [191, 255] : [64, 0])
            XCTAssertEqual(state.rv0, SIMD4(inverted ? 1 : 0, 7, 8, 9))
        }
    }

    /// The renderer advances each animator by the scene frametime and hands it to every draw of its puppet.
    func testPuppetDrawUploadsBonesThatFollowTheAnimator() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let puppetDraw = try makePlan(device: device, puppetID: "P")
        let layerDraw = try makePlan(device: device, puppetID: nil)
        var animator = Self.animator()
        var clock = WPEParityClock()
        var uploads: [[[Float]]] = []
        for _ in 0 ..< 2 {
            clock.advance(elapsed: 0.05, ratePercent: 100, paused: false)
            animator.advance(dt: Double(clock.frametime))
            let draw = try makeDraw(puppetDraw, clock: clock, puppets: ["P": animator])
            XCTAssertEqual(draw.indexCount, Self.puppet.indices.count)
            guard case let .array(bones)? = draw.constants[.vertex]?["g_Bones"] else {
                return XCTFail("the puppet draw has no g_Bones")
            }
            let columns = bones.flatMap { bone -> [[Float]] in
                guard case let .matrix(matrix) = bone else { return [] }
                return matrix.columns
            }
            XCTAssertEqual(columns.count, 3 * Self.puppet.boneCount)
            XCTAssertEqual(columns.map(\.count), [Int](repeating: 4, count: columns.count))
            uploads.append(columns)
            XCTAssertNil(try makeDraw(layerDraw, clock: clock, puppets: ["P": animator]).constants[.vertex]?["g_Bones"])
        }
        XCTAssertNotEqual(uploads[0], uploads[1], "g_Bones follows the animation")
    }

    // MARK: Fixture

    private static let puppet = WPEParityScenePuppet(vertices: [
        WPEPuppetVertex(position: SIMD3(-10, -20, 0), uv: SIMD2(0, 1), skinBlendIndices: SIMD4(0, 1, 0, 0),
                        skinBlendWeights: SIMD4(0.75, 0.25, 0, 0)),
        WPEPuppetVertex(position: SIMD3(10, -20, 0), uv: SIMD2(1, 1), skinBlendIndices: SIMD4(1, 0, 0, 0)),
        WPEPuppetVertex(position: SIMD3(0, 20, 0), uv: SIMD2(0.5, 0)),
    ], indices: [0, 1, 2, 2, 1, 0], boneCount: 2, skinned: true)

    private func makePlan(device: MTLDevice, puppetID: String?) throws -> WPEParityFrameDrawPlan {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 puppetVertex() { return float4(0, 0, 0, 1); }
        fragment float4 puppetFragment() { return float4(1); }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "puppetVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "puppetFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let fragment = WPEStageReflection(stage: .fragment, cbuffers: [], resources: [], topLevelArgumentBuffer: [])
        let pipeline = try WPEParityPipeline(state: device.makeRenderPipelineState(descriptor: descriptor),
                                             vertex: WPEParityPipeline.Stage(Self.reflection()),
                                             fragment: WPEParityPipeline.Stage(fragment))
        let geometry = try XCTUnwrap(WPEParityFrameDrawPlanner.puppetGeometry(
            Self.puppet, uvMax: .one, inputs: Self.reflection().vertexInputs, device: device
        ))
        return WPEParityFrameDrawPlan(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            geometry: .mesh(vertices: geometry.vertices, indices: geometry.indices, indexCount: geometry.indexCount),
            puppetID: puppetID,
            textures: [[:]],
            samplers: [:],
            uniforms: WPEParityUniformDraw(matrices: .effectPass),
            placement: nil,
            sprites: [:],
            constants: [:],
            renderVarWrites: (nil, nil),
            fallbackTextures: []
        )
    }

    private func makeDraw(_ plan: WPEParityFrameDrawPlan, clock: WPEParityClock,
                          puppets: [String: WPEParityPuppetAnimator]) throws -> WPEParityDraw {
        var slots: [String: WPECBufferValue] = [:]
        return try plan.makeDraw(frame: Self.frame(clock: clock), variant: 0, textures: [:], textureSlots: &slots,
                                 puppets: puppets)
    }

    private static func frame(clock: WPEParityClock = WPEParityClock()) -> WPEParityUniformFrame {
        WPEParityUniformFrame(clock: clock, daytime: 0,
                                          screen: WPEParityUniformScreen(clientWidth: 1, clientHeight: 1),
                                          pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
                                          eyePosition: .zero, view: matrix_identity_float4x4)
    }

    private static func reflection() throws -> WPEStageReflection {
        try JSONDecoder().decode(WPEStageReflection.self, from: Data(vertexReflection.utf8))
    }

    /// Bone 0 bound at (1, 0, 0) moves to (1, 4, 0) over one frame at 4 fps; bone 1 hangs under it.
    private static func animator() -> WPEParityPuppetAnimator {
        func translation(_ value: SIMD3<Float>) -> [Float] {
            [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, value.x, value.y, value.z, 1]
        }
        let keys = [SIMD3<Float>(1, 0, 0), SIMD3(1, 4, 0)].enumerated().map {
            WPEPuppetAnimKey(frame: $0, translation: $1, euler: .zero, scale: .one)
        }
        let animation = WPEPuppetAnimation(id: 7, name: "move", mode: "loop", fps: 4, frameCount: 1,
                                           channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: keys)])
        let model = WPEPuppetModel(version: 23, meshes: [], bones: [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: translation(SIMD3(1, 0, 0))),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: translation(SIMD3(0, 2, 0))),
        ], animations: [animation])
        return WPEParityPuppetAnimator(model: model, layers: [
            WPESceneAnimationLayer(id: 1, rate: 1, visible: true, blend: 1, animation: 7),
        ])
    }
}
#endif
