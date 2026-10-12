#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// Composes a whole WPE frame (scene + post chain), compiles it and runs it twice on Metal.
final class WPEParityFrameEndToEndTests: XCTestCase {
    private static let side = 64
    private static let formats: [String: MTLPixelFormat] = ["rgba8unorm": .rgba8Unorm, "depth32float": .depth32Float]
    private static let layerColor: [UInt8] = [51, 153, 102, 255]
    /// Contents of every caller-owned target before the first frame, so reading an unwritten one shows.
    private static let poison = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)

    func testLayerWithTwoPassEffectAndColorCorrectionReachesTheBackbuffer() throws {
        try runTwoFrames(msaaSamples: 1)
    }

    func testMultisampledFrameGivesTheSameBackbuffer() throws {
        try runTwoFrames(msaaSamples: 4)
    }

    private func runTwoFrames(msaaSamples: Int) throws {
        let directory = try fixtureDirectory()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let factory = WPEParityPipelineFactory(device: device)
        let program = try loadProgram("shaders/passthrough", in: directory)

        let effect = WPEParitySceneEffect(id: "E", passes: [WPEParityScenePass(shader: "e0"),
                                                            WPEParityScenePass(shader: "e1")])
        let scene = WPEParitySceneDescription(
            width: Self.side, height: Self.side, clearColor: SIMD3(0.1, 0.2, 0.3), msaaSamples: msaaSamples,
            objects: [WPEParitySceneObject(id: "L", width: Self.side, height: Self.side, effects: [effect])]
        )
        let post = WPEParityPostProcessConfig(msaaSampleCount: msaaSamples, colorCorrectionEnabled: true,
                                              backbufferWidth: Self.side, backbufferHeight: Self.side)
        let frame = try WPEParityFrameComposer.compose(scene: scene, post: post, frameIndex: 0)
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        let executor = try WPEParityGraphExecutor(
            graph: graph, device: device, drawEncoder: WPEParityDrawEncoder(factory: factory),
            arena: XCTUnwrap(WPEParityFrameArena(device: device, capacity: 64 * 1024)), pixelFormats: Self.formats
        )

        var textures: [WPEResourceID: MTLTexture] = [:]
        for resource in frame.resources where executor.transientTextures[resource.id] == nil {
            textures[resource.id] = try resource.lifetime == .imported
                ? makeImage(device) : makeTarget(device, resource)
        }
        try clearToPoison(queue, frame.resources.filter { $0.lifetime != .imported }.compactMap { textures[$0.id] })
        let bindings = Self.bindings(frame)
        let backbuffer = try XCTUnwrap(textures["backbuffer"])

        for frameNumber in 1 ... 2 {
            let submission = try executor.encodeFrame(on: queue, textures: textures) { operation, bound in
                let description = try XCTUnwrap(frame.draws[operation], "no description for operation \(operation)")
                let binding = try XCTUnwrap(bindings[operation])
                return try self.makeDraw(description, binding: binding, program: program, factory: factory,
                                         textures: bound)
            }
            guard case let .committed(commandBuffer) = submission else { return XCTFail("frame was skipped") }
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
            // Albedo copies C into the composite (ONE/ZERO); both effect passes blend it at alpha 1 over the clear
            // (SRC_ALPHA/INV_SRC_ALPHA gives C); ccsimple copies the FFB snapshot of C: RGB = C = (51, 153, 102).
            let pixels = try readBack(device, queue, backbuffer)
            for pixel in 0 ..< pixels.count / 4 {
                let rgb = Array(pixels[pixel * 4 ..< pixel * 4 + 3])
                guard zip(rgb, Self.layerColor).allSatisfy({ abs(Int($0) - Int($1)) <= 1 }) else {
                    return XCTFail("frame \(frameNumber) pixel \(pixel): \(rgb), expected \(Self.layerColor.prefix(3))")
                }
            }
        }
    }

    // MARK: Draws

    private struct Binding {
        let sampleCount: Int
        let hasDepth: Bool
    }

    /// Bound targets at each draw operation, as the pipeline must declare them.
    private static func bindings(_ frame: WPEParityFrame) -> [Int: Binding] {
        let resources = Dictionary(uniqueKeysWithValues: frame.resources.map { ($0.id, $0) })
        var bound = Binding(sampleCount: 1, hasDepth: false)
        var result: [Int: Binding] = [:]
        for (index, operation) in frame.operations.enumerated() {
            switch operation.kind {
            case let .setTargets(color, depth):
                bound = Binding(sampleCount: color.first.flatMap { resources[$0.resource] }?.sampleCount ?? 1,
                                hasDepth: depth != nil)
            case .draw:
                result[index] = bound
            default:
                break
            }
        }
        return result
    }

    /// Every draw is a full-screen passthrough of its first read under the description's blend state.
    private func makeDraw(_ description: WPEParityFrameDraw, binding: Binding, program: WPEParityShaderArtifact,
                          factory: WPEParityPipelineFactory,
                          textures: [WPEResourceID: MTLTexture]) throws -> WPEParityDraw {
        let reads: [WPEResourceID]
        let blend: WPEParityBlendState
        switch description {
        case let .scene(draw):
            let mode: WPEParityBlendMode = switch draw.blend {
            case .normal: .normal
            case .translucent: .translucent
            case .additive: .additive
            }
            var modifiers: WPEParityBlendModifiers = draw.writeMask == .rgba ? .writeAlpha : []
            if draw.alphaMax {
                modifiers.insert(.alphaMax)
            }
            (reads, blend) = (draw.reads, .wpe(mode, modifiers: modifiers))
        case let .post(draw):
            let blendState: WPEParityBlendState = switch draw.blend {
            case .normal: .wpe(.normal, modifiers: .writeAlpha)
            case .translucent: .wpe(.translucent)
            case .additive: .wpe(.additive)
            }
            (reads, blend) = (draw.reads, blendState)
        }
        let pipeline = try factory.makePipeline(
            artifact: program, blend: blend, colorPixelFormat: .rgba8Unorm,
            depthStencilPixelFormat: binding.hasDepth ? .depth32Float : .invalid, sampleCount: binding.sampleCount
        )
        // VS_INPUT: float3 POSITION0, float2 TEXCOORD0; D3D texcoord v=0 is the top row.
        let vertices: [Float] = [-1, 1, 0, 0, 0, -1, -1, 0, 0, 1, 1, 1, 0, 1, 0, 1, -1, 0, 1, 1]
        let buffer = try XCTUnwrap(factory.device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: .storageModeShared
        ))
        var draw = WPEParityDraw(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: buffer,
            primitiveType: .triangleStrip,
            vertexCount: 4
        )
        let source = try XCTUnwrap(reads.first)
        draw.textures = try ["g_Texture0": XCTUnwrap(textures[source], "no texture for \(source)")]
        draw.samplers = ["g_Texture0SamplerState": .wpe(filter: .point, address: .clamp)]
        return draw
    }

    // MARK: Textures

    private func makeImage(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Self.side, height: Self.side, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let texels = (0 ..< Self.side * Self.side).flatMap { _ in Self.layerColor }
        texture.replace(region: MTLRegionMake2D(0, 0, Self.side, Self.side), mipmapLevel: 0,
                        withBytes: texels, bytesPerRow: Self.side * 4)
        return texture
    }

    private func makeTarget(_ device: MTLDevice, _ resource: WPELogicalResource) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = resource.sampleCount > 1 ? .type2DMultisample : .type2D
        descriptor.pixelFormat = try XCTUnwrap(Self.formats[resource.format], resource.format)
        descriptor.width = resource.width
        descriptor.height = resource.height
        descriptor.mipmapLevelCount = resource.mipCount
        descriptor.sampleCount = resource.sampleCount
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor), "\(resource.id)")
    }

    private func clearToPoison(_ queue: MTLCommandQueue, _ targets: [MTLTexture]) throws {
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        for texture in targets {
            let pass = MTLRenderPassDescriptor()
            if texture.pixelFormat == .depth32Float {
                pass.depthAttachment.texture = texture
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = 1
                pass.depthAttachment.storeAction = .store
            } else {
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = Self.poison
                pass.colorAttachments[0].storeAction = .store
            }
            try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }

    private func readBack(_ device: MTLDevice, _ queue: MTLCommandQueue, _ texture: MTLTexture) throws -> [UInt8] {
        let length = Self.side * Self.side * 4
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Self.side, height: Self.side, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: Self.side * 4, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
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

    private func loadProgram(_ name: String, in directory: URL) throws -> WPEParityShaderArtifact {
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
        let reflection = try JSONDecoder().decode(WPEStageReflection.self, from: Self.fillingVertexInputs(json))
        return try WPEParityShaderArtifact.Stage(
            metallib: Data(contentsOf: compiled.appending(path: "\(number).metallib")),
            reflection: reflection,
            functionName: reflection.entry
        )
    }

    /// The capture leaves `vertexInputs` empty while MSC's raw reflection lists them under `state.vertex_inputs`.
    private static func fillingVertexInputs(_ json: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              (object["vertexInputs"] as? [Any])?.isEmpty == true,
              let msc = object["mscReflection"] as? [String: Any],
              let state = msc["state"] as? [String: Any],
              let inputs = state["vertex_inputs"] as? [[String: Any]] else { return json }
        object["vertexInputs"] = inputs.map { input -> [String: Any] in
            ["name": input["name"] ?? "", "index": input["index"] ?? 0,
             "elementType": input["elementType"] ?? "", "columns": input["columnCount"] ?? 0]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
#endif
