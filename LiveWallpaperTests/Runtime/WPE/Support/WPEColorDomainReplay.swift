#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

/// Isolates view decoding, authored shader math, alpha injection, blending and RT encoding.
enum WPEColorDomainReplay {
    struct Image {
        let width: Int
        let bytes: [UInt8]
        let format: MTLPixelFormat
    }

    struct Output {
        let values: [Float]
        let contract: WPEPassColorContract
    }

    static func run(
        images: [Image], body: String, declarations: String = "",
        values: [String: WPESceneShaderConstantValue] = [:], outputFormat: MTLPixelFormat,
        blend: String = "disabled", clear: SIMD4<Double> = .zero,
        pmaInputs: Set<Int> = [], pmaOutput: Bool = false
    ) throws -> Output {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let compiler = WPESwiftShaderCompiler(device: device, translationCache: WPEShaderTranslationCache(rootURL: cacheRoot))
        let samplers = images.indices.map { "uniform sampler2D g_Texture\($0);" }.joined(separator: "\n")
        let fragment = samplers + "\n" + declarations + "\nvarying vec2 v_TexCoord;\nvoid main() {\n" + body + "\n}"
        let request = try WPEShaderPreprocessor().process(
            shaderName: "color_domain_probe",
            vertexSource: "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }",
            fragmentSource: fragment, comboValues: [:], materialTextureBindings: [:]
        ).replacingPremultipliedAlphaSettings(inputSlots: pmaInputs, output: pmaOutput)
        let result = try compiler.compile(request)
        let pass = WPEPreparedRenderPass(
            pass: WPERenderPass(id: "color.probe", phase: .effect(file: "probe"), shader: "color_domain_probe",
                                source: .image("probe"), target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                                blending: blend, cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"),
            shader: nil, textureBindings: [:], comboValues: [:], uniformValues: values
        )
        let slots = try executor.packTranslatedUniforms(for: pass, layout: result.uniformLayout)
        let pipeline = try executor.translatedPipelineState(for: result, blendMode: blend, alphaWritePolicy: .all,
                                                            colorPixelFormat: outputFormat, depthPixelFormat: .invalid)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: outputFormat, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(clear.x, clear.y, clear.z, clear.w)
        renderPass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: renderPass))
        encoder.setRenderPipelineState(pipeline)
        if !slots.isEmpty {
            slots.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        let sampler = try #require(device.makeSamplerState(descriptor: samplerDescriptor))
        var bindings: [WPECanonicalTraceRecorder.TextureBindingInput] = []
        var keepAlive: [MTLTexture] = []
        for (slot, image) in images.enumerated() {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: image.format, width: image.width, height: 1, mipmapped: false)
            td.storageMode = .shared
            td.usage = [.shaderRead]
            let texture = try #require(device.makeTexture(descriptor: td))
            let rowBytes = image.format == .r8Unorm ? image.width : image.width * 4
            #expect(image.bytes.count == rowBytes)
            image.bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, image.width, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rowBytes)
            }
            encoder.setFragmentTexture(texture, index: slot)
            encoder.setFragmentSamplerState(sampler, index: slot)
            keepAlive.append(texture)
            bindings.append(.init(slot: slot, name: "g_Texture\(slot)", reference: .image("probe\(slot)"),
                                  texture: texture, fallbackToPrimary: false))
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed && command.error == nil)
        withExtendedLifetime(keepAlive) {}
        let contract = WPEPassColorContract(textureBindings: bindings, alpha: result.alphaContract, target: target,
                                            nativeState: .scenePass(blendMode: blend, alphaWritePolicy: .all, cullMode: "nocull",
                                                                    depthAttached: false, depthTest: "disabled", depthWrite: "disabled", reversedZ: false))
        let pixels: [Float]
        if outputFormat == .rgba32Float {
            var raw = [Float](repeating: 0, count: 4)
            raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
            pixels = raw
        } else {
            var raw = [UInt8](repeating: 0, count: 4)
            raw.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
            pixels = raw.map { Float($0) / 255 }
        }
        let record: [String: Any] = [
            "schema": "wpe.color-probe.v1", "shaderSourceHash": request.sourceHash,
            "inputFormats": images.map(\.format.rawValue), "inputWidths": images.map(\.width),
            "packedUniformSlots": slots.map { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] },
            "unpremultipliedInputSlots": pmaInputs.sorted(), "premultipliedOutput": pmaOutput,
            "inputSHA256": images.map { image in SHA256.hash(data: Data(image.bytes)).map { String(format: "%02x", $0) }.joined() },
            "targetFormat": outputFormat.rawValue, "blend": blend,
            "clear": [clear.x, clear.y, clear.z, clear.w], "rgba": pixels.map(Double.init),
            "colorContract": contract.jsonObject(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
           let text = String(data: data, encoding: .utf8) {
            print("[wpe-color-probe] " + text)
        }
        return Output(values: pixels, contract: contract)
    }
}
#endif
