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
            vertexBuffer: geometry.vertices,
            indexBuffer: geometry.indices,
            indexCount: geometry.indexCount,
            puppetID: puppetID,
            textures: [[:]],
            samplers: [:],
            uniforms: WPEParityUniformDraw(matrices: .effectPass),
            placement: nil,
            sprites: [:],
            constants: [:],
            zeroConstants: [:]
        )
    }

    private func makeDraw(_ plan: WPEParityFrameDrawPlan, clock: WPEParityClock,
                          puppets: [String: WPEParityPuppetAnimator]) throws -> WPEParityDraw {
        let frame = WPEParityUniformFrame(clock: clock, daytime: 0,
                                          screen: WPEParityUniformScreen(clientWidth: 1, clientHeight: 1),
                                          pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
                                          eyePosition: .zero, view: matrix_identity_float4x4)
        var slots: [String: WPECBufferValue] = [:]
        return try plan.makeDraw(frame: frame, variant: 0, textures: [:], textureSlots: &slots, puppets: puppets)
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
