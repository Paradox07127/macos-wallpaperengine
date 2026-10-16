#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

extension WPEParitySceneDriverTests {
    /// The bundled toolchain lowers the original caster's SV_ViewportArrayIndex and the receiver's
    /// SamplerComparisonState so they work on a Depth32Float atlas.
    func testShadowToolchainEmitsViewportIndexAndDepthComparison() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (assets, compiler) = try shadowInputs()
        let caster = try WPEParityProgramResolver.resolve(WPEParityProgramDescription(
            material: WPEParityProgramMaterial(shader: "shadowcaster", path: "materials/util/shadowcaster.json"),
            engineFlags: WPEEngineComboFlags(), boundTextures: [:]
        ), sources: assets)
        let casterStages = try await compiler.compile(WPEParityShaderCompileRequest(
            program: caster.hlsl, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let casterVertex = try XCTUnwrap(casterStages.stages[.vertex]?.metallib)
        XCTAssertNotNil(casterVertex.range(of: Data("air.viewport_array_index".utf8)),
                        "caster vertex stage must write [[viewport_array_index]]")

        // SampleCmpLevelZero at both texel centres of a 2×1 Depth32Float texture holding 0.25 and 0.75.
        let program = WPEHLSLProgram(vertex: Array("""
        float4 main(uint id : SV_VertexID) : SV_Position {
            const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            return float4(p[id], 0, 1);
        }
        """.utf8), fragment: Array("""
        Texture2D g_Texture6 : register(t6);
        SamplerComparisonState g_Texture6SamplerComparisonState : register(s6);
        float4 main(float4 position : SV_Position) : SV_Target {
            return g_Texture6.SampleCmpLevelZero(g_Texture6SamplerComparisonState, float2(position.x / 2, 0.5), 0.5).rrrr;
        }
        """.utf8))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appending(path: "compare-cache")
        ))
        let artifact = try await store.artifact(for: WPEParityShaderCompileRequest(
            program: program, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha),
                                                colorPixelFormat: .rgba8Unorm)
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2, height: 1,
                                                                       mipmapped: false)
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 1,
                                                                        mipmapped: false)
        targetDescriptor.usage = .renderTarget
        targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let arena = try XCTUnwrap(WPEParityFrameArena(device: device, capacity: 65536))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let stored: [Float] = [0.25, 0.75]
        let source = try XCTUnwrap(device.makeBuffer(bytes: stored, length: 8, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: source, sourceOffset: 0, sourceBytesPerRow: 8, sourceBytesPerImage: 8,
                  sourceSize: MTLSize(width: 2, height: 1, depth: 1), to: depth, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let frame = try XCTUnwrap(arena.beginFrame(for: command))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var draw = try WPEParityDraw(
            pipeline: pipeline, depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared)),
            primitiveType: .triangle, vertexCount: 3
        )
        draw.textures = ["g_Texture6": depth]
        draw.samplers = ["g_Texture6SamplerComparisonState": .wpeComparison()]
        try WPEParityDrawEncoder(factory: factory).encode(draw, frame: frame, hasDepthAttachment: false, on: encoder)
        encoder.endEncoding()
        command.commit()
        await command.completed()
        XCTAssertNil(command.error)
        var output = [UInt8](repeating: 0, count: 8)
        target.getBytes(&output, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
        XCTAssertEqual([output[0], output[4]], [255, 0], "only the texel the 0.5 reference is GREATER than may pass")

        var flags = WPEEngineComboFlags()
        flags.spotLights = 1
        flags.spotShadowLights = 1
        flags.shadowQuality = 2
        let receiver = try WPEParityProgramResolver.resolve(WPEParityProgramDescription(
            material: WPEParityProgramMaterial(shader: "generic4", combos: ["LIGHTING": 1]),
            engineFlags: flags, boundTextures: [:]
        ), sources: assets)
        XCTAssertTrue(receiver.combos.contains(WPEShaderDefine(name: "LIGHTS_SHADOW_MAPPING", value: "1")))
        let receiverStages = try await compiler.compile(WPEParityShaderCompileRequest(
            program: receiver.hlsl, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let reflection = try JSONDecoder().decode(WPEStageReflection.self,
                                                  from: XCTUnwrap(receiverStages.stages[.fragment]).reflectionJSON)
        XCTAssertTrue(reflection.resources.contains { $0.name == "g_Texture6" && $0.kind == .texture })
        XCTAssertTrue(reflection.resources.contains { $0.name == "g_Texture6SamplerComparisonState" && $0.kind == .sampler })
    }

    /// Each instance draws a full-viewport triangle at depth 0.25·(instance+1) into viewport `instance`
    /// (shadowcaster.vert:104-105), so the two viewports of the 4×2 atlas hold different depths.
    func testInstancedDrawSelectsViewportPerInstanceOnDepthOnlyTarget() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (_, compiler) = try shadowInputs()
        let program = WPEHLSLProgram(vertex: Array("""
        struct Output {
            float4 position : SV_Position;
            uint viewport : SV_ViewportArrayIndex;
        };
        Output main(uint id : SV_VertexID, uint instance : SV_InstanceID) {
            const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            Output output;
            output.position = float4(p[id], 0.25 * (instance + 1), 1);
            output.viewport = instance;
            return output;
        }
        """.utf8), fragment: Array("void main() {}".utf8))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appending(path: "instanced-cache")
        ))
        let artifact = try await store.artifact(for: WPEParityShaderCompileRequest(
            program: program, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.normal), colorPixelFormat: .invalid,
                                                depthStencilPixelFormat: .depth32Float)

        let instanced = try await renderViewportDepth(instanceCount: 2, pipeline: pipeline, factory: factory, device: device)
        XCTAssertEqual(instanced, [0.25, 0.25, 0.5, 0.5, 0.25, 0.25, 0.5, 0.5],
                       "the second instance did not reach the right viewport")
        let single = try await renderViewportDepth(instanceCount: 1, pipeline: pipeline, factory: factory, device: device)
        XCTAssertEqual(single, [0.25, 0.25, 0, 0, 0.25, 0.25, 0, 0], "a single instance wrote outside viewport 0")
    }

    private func renderViewportDepth(instanceCount: Int, pipeline: WPEParityPipeline, factory: WPEParityPipelineFactory,
                                     device: MTLDevice) async throws -> [Float] {
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 4, height: 2,
                                                                       mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let arena = try XCTUnwrap(WPEParityFrameArena(device: device, capacity: 65536))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try XCTUnwrap(arena.beginFrame(for: command))
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        let indices: [UInt16] = [0, 1, 2]
        var draw = try WPEParityDraw(
            pipeline: pipeline, depthStencil: .wpe(depthTest: true, depthWrite: true),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: true, multisample: false),
            vertexBuffer: XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared)),
            primitiveType: .triangle, vertexCount: 3,
            indexBuffer: XCTUnwrap(device.makeBuffer(bytes: indices, length: 6, options: .storageModeShared)),
            indexCount: 3
        )
        draw.instanceCount = instanceCount
        draw.viewports = [MTLViewport(originX: 0, originY: 0, width: 2, height: 2, znear: 0, zfar: 1),
                          MTLViewport(originX: 2, originY: 0, width: 2, height: 2, znear: 0, zfar: 1)]
        try WPEParityDrawEncoder(factory: factory).encode(draw, frame: frame, hasDepthAttachment: true, on: encoder)
        encoder.endEncoding()
        let readback = try XCTUnwrap(device.makeBuffer(length: 32, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 4, height: 2, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: 16, destinationBytesPerImage: 32)
        blit.endEncoding()
        command.commit()
        await command.completed()
        XCTAssertNil(command.error)
        return Array(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: Float.self), count: 8))
    }

    func shadowInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        let (_, original) = try XCTUnwrap(try? sceneInputs(), "required captured scene and original WPE asset sources")
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath().standardizedFileURL
        let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil, "required bundle component \(url)")
            return url
        }
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1], metalIRConverter: tools[2],
                                                         workDirectory: scratch.appending(path: "shadow-shaderc"))
        return (WPEParityProgramAssets(sources: [.directory(scratch)] + original.sources), compiler)
    }
}
#endif
