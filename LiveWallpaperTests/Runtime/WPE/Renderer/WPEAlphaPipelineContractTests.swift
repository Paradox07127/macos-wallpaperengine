#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE resolved resource alpha contracts", .serialized)
struct WPEAlphaPipelineContractTests {
    @Test("Native and translated consumers agree after straight/PMA intermediate publication", arguments: [false, true], [false, true])
    func adjacentPasses(straight: Bool, translated: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, bytes: [192, 128, 64, 128])
        let producer = prepared("producer", shader: "genericimage2", source: .asset("source"), target: .layerComposite(name: "a"),
                                alpha: straight ? .init(unpremultipliedInputSlots: [], premultipliedOutput: false) : nil)
        let consumer = prepared("consumer", shader: translated ? "contract_sample" : "genericimage2", source: .fbo("a"), target: .scene,
                                program: translated ? sampleProgram : nil)
        let pipeline = graph([producer, consumer]).resolvingRenderContracts()
        let resolved = pipeline.layers[0].passes[1]
        #expect(resolved.renderContract.inputs[0]?.semantics.alpha == (straight ? .straight : .premultiplied))
        if translated {
            #expect(resolved.renderContract.shaderAlpha.unpremultipliedInputSlots == (straight ? [] : [0]))
            try seed(executor, pass: resolved)
        } else {
            #expect(resolved.renderContract.nativeAlpha.input == (straight ? .none : .unpremultiply))
        }
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: ["source": source])
        let pixel = try rawPixels(output, coordinates: [[2, 2]], executor: executor)[0]
        for channel in 0 ..< 3 {
            let expected = Double([192, 128, 64][channel]) / 255 * (translated ? 1 : 128.0 / 255)
            #expect(abs(pixel[channel] - expected) < 2.0 / 255)
        }
        #expect(abs(pixel[3] - 1) < 1.0 / 255)
    }

    @Test("Data and zero-alpha emission survive a translated intermediate", arguments: [WPEResourceSemantics.data(.normal), .emission], [false, true])
    func independentChannels(semantics: WPEResourceSemantics, hdr: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let producerProgram = WPEShaderProgram(name: "contract_data", vertexSource: sampleProgram.vertexSource,
                                               fragmentSource: hdr ? "void main() { gl_FragColor = vec4(2.0, -0.25, 0.1, 0.0); }" : "void main() { gl_FragColor = vec4(0.6, 0.2, 0.1, 0.0); }", isBuiltin: false)
        let raw = prepared("producer", shader: producerProgram.name, source: .asset("unused"), target: .layerComposite(name: "a"), program: producerProgram)
        let contract = WPEPassRenderContract.resolve(pass: raw.pass, shader: producerProgram, bindings: [:], alphaOverride: nil, outputDeclaration: semantics)
        let producer = raw.replacingRenderContract(contract)
        let consumer = prepared("consumer", shader: sampleProgram.name, source: .fbo("a"), target: .scene, program: sampleProgram)
        let pipeline = graph([producer, consumer]).resolvingRenderContracts()
        for pass in pipeline.layers[0].passes {
            try seed(executor, pass: pass)
        }
        #expect(pipeline.layers[0].passes[1].renderContract.shaderAlpha.unpremultipliedInputSlots.isEmpty)
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:], cameraUniforms: WPEMetalCameraUniforms(
            orthogonalProjection: .init(width: 4, height: 4, auto: true), sceneCamera: .defaultCamera, sceneHDR: hdr
        ))
        let pixel = try rawPixels(output, coordinates: [[2, 2]], executor: executor)[0]
        for (channel, value) in (hdr ? [2.0, -0.25, 0.1] : [0.6, 0.2, 0.1]).enumerated() {
            #expect(abs(pixel[channel] - value) < 2.0 / 255)
        }
    }

    @Test("Straight image publication enters a native effect in PMA exactly once")
    func straightNativeEffectChain() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, bytes: [192, 128, 64, 128])
        let producer = prepared("producer", shader: "genericimage2", source: .asset("source"), target: .layerComposite(name: "a"),
                                alpha: .init(unpremultipliedInputSlots: [], premultipliedOutput: false))
        let effect = prepared("blur", shader: "effects/blur", source: .fbo("a"), target: .layerComposite(name: "b"))
        let consumer = prepared("consumer", shader: "genericimage2", source: .fbo("b"), target: .scene)
        let pipeline = graph([producer, effect, consumer]).resolvingRenderContracts()
        #expect(pipeline.layers[0].passes[1].renderContract.nativeAlpha.input == .premultiply)
        #expect(pipeline.layers[0].passes[2].renderContract.nativeAlpha.input == .unpremultiply)
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: ["source": source])
        let pixel = try rawPixels(output, coordinates: [[2, 2]], executor: executor)[0]
        #expect(abs(pixel[0] - 192.0 / 255 * 128.0 / 255) < 2.0 / 255)
    }

    @Test("One pass ID can cache different native input representations")
    func nativeCacheIdentity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let color = try texture(device, bytes: [192, 128, 64, 128])
        let pma = try texture(device, bytes: [96, 64, 32, 128])
        let base = prepared("same", shader: "genericimage2", source: .asset("source"), target: .scene)
        for (source, semantics) in [(color, WPEResourceSemantics.straightColor), (pma, .premultipliedColor), (color, .straightColor)] {
            let pipeline = graph([base]).resolvingRenderContracts { _ in semantics }
            let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: ["source": source])
            let pixel = try rawPixels(output, coordinates: [[2, 2]], executor: executor)[0]
            #expect(abs(pixel[0] - 96.0 / 255) < 2.0 / 255)
        }
    }

    @Test("Native unpremultiply retains float arithmetic before storing an HDR PMA result")
    func nativeHDRIntermediateRange() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let words = [Float(40000), 20000, 10000, 0.25].map { Float16($0).bitPattern }
        words.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        let pass = prepared("nativeHDR", shader: "genericimage2", source: .asset("source"), target: .scene)
        let pipeline = graph([pass]).resolvingRenderContracts { _ in .premultipliedColor }
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 4, height: 4, auto: true), sceneCamera: .defaultCamera, sceneHDR: true)
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: ["source": source], cameraUniforms: camera)
        let pixel = try rawPixels(output, coordinates: [[2, 2]], executor: executor)[0]
        for (channel, expected) in [40000.0, 20000, 10000].enumerated() {
            #expect(pixel[channel].isFinite && abs(pixel[channel] - expected) <= 32)
        }
    }

    @Test("Unknown inputs keep the compatibility ABI and expose a diagnosis")
    func unknownAndAttachmentPolicy() {
        let pass = prepared("unknown", shader: sampleProgram.name, source: .fbo("unpublished"), target: .scene, program: sampleProgram)
        #expect(pass.renderContract.shaderAlpha.unpremultipliedInputSlots == [0])
        #expect(pass.renderContract.inputs[0]?.semantics == .unknown)
        #expect(pass.renderContract.diagnostics.contains("unverified-input:0:fbo:unpublished"))
        #expect(pass.renderContract.attachment.alphaWritePolicy == .rgbOnly)
        #expect(pass.renderContract.attachment.clearAlpha == 1)
        let local = prepared("local", shader: "genericimage2", source: .asset("source"), target: .layerComposite(name: "a"))
        #expect(local.renderContract.attachment.alphaWritePolicy == .all)
        #expect(local.renderContract.attachment.clearAlpha == 0)
        #expect(local.replacingRenderContract(local.renderContract).renderContract == local.renderContract)
    }

    @Test("RG88 roles override ambiguous file names and preserve uploaded bytes", arguments: [WPETextureUsage.color, .mask, .flow, .normal, .lut])
    func rg88Roles(usage: WPETextureUsage) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let info = WPETexInfo(containerVersion: 5, infoVersion: 1, width: 1, height: 1,
                              textureFormatCode: WPETexFormat.rg88.rawValue, format: .rg88, mipmapCount: 1, flags: 0x80000)
        let payload = WPETexTexturePayload(info: info, mipmaps: [.init(index: 0, width: 1, height: 1, bytes: Data([200, 50]))], hasAnimationFrames: false)
        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "mask_glow", usage: usage)
        var bytes = [UInt8](repeating: 0, count: 2)
        texture.getBytes(&bytes, bytesPerRow: 2, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        #expect(bytes == [200, 50])
        #expect(texture.swizzle.alpha == (usage == .color || usage == .mask ? .green : .alpha))
        #expect(WPEMetalTextureMetadataRegistry.shared.semantics(for: texture).usage == usage)
        let executor = try WPEMetalRenderExecutor(device: device)
        let copy = prepared("sample", shader: "commands/copy", source: .asset("source"), target: .scene)
        let pipeline = graph([copy]).resolvingRenderContracts { _ in WPEMetalTextureMetadataRegistry.shared.semantics(for: texture) }
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: ["source": texture])
        let pixel = try rawPixels(output, coordinates: [[2, 2]], executor: executor)[0]
        let luminance = usage == .color || usage == .mask
        #expect(abs(pixel[1] - (luminance ? 200.0 : 50.0) / 255) < 1.0 / 255)
        #expect(abs(pixel[2] - (luminance ? 200.0 / 255 : 0)) < 1.0 / 255)
    }

    private var sampleProgram: WPEShaderProgram {
        WPEShaderProgram(name: "contract_sample", vertexSource: """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
        """, fragmentSource: """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texture2D(g_Texture0, v_TexCoord); }
        """, isBuiltin: false)
    }

    private func prepared(_ id: String, shader: String, source: WPETextureReference, target: WPERenderTarget,
                          alpha: WPEShaderAlphaContract? = nil, program: WPEShaderProgram? = nil) -> WPEPreparedRenderPass {
        let pass = WPERenderPass(id: id, phase: .material, shader: shader, source: source, target: target,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull",
                                 depthTest: "disabled", depthWrite: "disabled")
        return .init(pass: pass, shader: program, textureBindings: [0: source], comboValues: [:], uniformValues: [:], alphaContract: alpha)
    }

    private func graph(_ passes: [WPEPreparedRenderPass]) -> WPEPreparedRenderPipeline {
        let layer = WPERenderLayer(objectID: "contract", objectName: "contract", imagePath: "source", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: passes.map(\.pass))
        return .init(layers: [.init(graphLayer: layer, passes: passes)])
    }

    private func texture(_ device: MTLDevice, bytes: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        return texture
    }

    private func rawPixels(_ texture: MTLTexture, coordinates: [[Int]], executor: WPEMetalRenderExecutor) throws -> [[Double]] {
        let probe = try WPEOraclePixelProbe.sample(texture: texture, coordinates: coordinates, commandQueue: executor.commandQueue)
        let samples = try #require(probe["samples"] as? [[String: Any]])
        return try samples.map { try #require($0["storageRGBA"] as? [Double]) }
    }

    private func seed(_ executor: WPEMetalRenderExecutor, pass: WPEPreparedRenderPass) throws {
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try executor.shaderCompiler.compile(request)
        executor.seedCompiledShaderResultsByPassID([(passID: pass.id, result: result)])
    }
}
#endif
