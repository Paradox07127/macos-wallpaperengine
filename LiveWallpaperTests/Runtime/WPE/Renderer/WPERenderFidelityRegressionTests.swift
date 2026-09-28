#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE attachment, blur and transparent multiply regressions")
struct WPERenderFidelityRegressionTests {
    private func geometry(_ x: Double, _ y: Double) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(origin: SIMD3(x, y, 0), scale: SIMD3(repeating: 1), angles: .zero,
                               alignment: .center, size: CGSize(width: 100, height: 100),
                               alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
    }

    private func layer(_ id: String, parent: String? = nil, local: SIMD2<Double>,
                       world: SIMD2<Double>, anchor: SIMD3<Double> = .zero) -> WPEPreparedRenderLayer {
        WPEPreparedRenderLayer(graphLayer: WPERenderLayer(
            objectID: id, objectName: id, imagePath: "models/test.json", materialPath: nil,
            parentObjectID: parent, attachment: anchor == .zero ? nil : "head",
            attachmentOriginOffset: anchor, geometry: geometry(world.x, world.y),
            localGeometry: geometry(local.x, local.y), compositeA: "a_" + id,
            compositeB: "b_" + id, localFBOs: [], passes: []
        ).nativized(), passes: [])
    }

    private var attachmentPipeline: WPEPreparedRenderPipeline {
        WPEPreparedRenderPipeline(layers: [
            layer("body", local: SIMD2(1000, 500), world: SIMD2(1000, 500)),
            layer("face", parent: "body", local: SIMD2(50, 30), world: SIMD2(850, 630),
                  anchor: SIMD3(-200, 100, 0)),
            layer("jewel", parent: "face", local: SIMD2(5, 6), world: SIMD2(855, 636)),
        ])
    }

    @Test("An unrelated script does not erase bind anchors or their grandchild displacement")
    func unrelatedScriptKeepsAttachments() {
        let original = attachmentPipeline
        let result = original.applyingLayerTransforms(
            origins: [:], scales: [:], angles: ["ring": .zero],
            parentByID: ["face": "body", "jewel": "face"]
        )
        #expect(result == original)
    }

    @Test("Local script origins remain relative to the anchor, and ancestors rotate both together")
    func scriptedOriginAndAncestorTransform() {
        let result = attachmentPipeline.applyingLayerTransforms(
            origins: ["face": SIMD3(80, 40, 0)],
            scales: ["body": SIMD3(2, 2, 1)], angles: ["body": SIMD3(0, 0, Double.pi / 2)],
            parentByID: ["face": "body", "jewel": "face"]
        )
        let face = result.layers[1].graphLayer
        let jewel = result.layers[2].graphLayer
        #expect(abs(face.geometry.origin.x - 720) < 0.0001)
        #expect(abs(face.geometry.origin.y - 260) < 0.0001)
        #expect(abs(jewel.geometry.origin.x - 708) < 0.0001)
        #expect(abs(jewel.geometry.origin.y - 270) < 0.0001)
        #expect(face.localGeometry?.origin == SIMD3(50, 30, 0))
        #expect(face.attachmentOriginOffset == SIMD3(-200, 100, 0))
    }

    @Test("Premultiplied multiply preserves the background at alpha zero", arguments: [0.0, 0.5, 1.0])
    func transparentMultiply(alpha: Double) throws {
        let source = SIMD4<Float>(Float(0.2 * alpha), Float(0.4 * alpha), Float(0.6 * alpha), Float(alpha))
        let result = try render(
            source: "uniform vec4 g_Color;\nvoid main() { gl_FragColor = g_Color; }",
            name: "multiply-probe", width: 1, height: 1,
            uniforms: ["g_Color": source], blend: "premultipliedmultiply"
        )
        let background = [0.8, 0.6, 0.4]
        let foreground = [0.2, 0.4, 0.6]
        for channel in 0 ..< 3 {
            let expected = background[channel] * (1 - alpha + alpha * foreground[channel]) * 255
            #expect(abs(Double(result[channel]) - expected) < 2)
        }
        #expect(abs(Int(result[3]) - 179) <= 1)
    }

    @Test("Straight multiply keeps its separate historical blend contract")
    func straightMultiplyIsUnchanged() throws {
        let result = try render(
            source: "uniform vec4 g_Color;\nvoid main() { gl_FragColor = g_Color; }",
            name: "multiply-probe", width: 1, height: 1,
            uniforms: ["g_Color": SIMD4(0.2, 0.4, 0.6, 0)], blend: "multiply"
        )
        for (channel, expected) in [40.8, 61.2, 61.2].enumerated() {
            #expect(abs(Double(result[channel]) - expected) < 2)
        }
    }

    @Test("Gaussian taps spread an impulse on the requested axis", arguments: [0, 1, 2], [false, true])
    func gaussianImpulse(kernel: Int, vertical: Bool) throws {
        let weights: [[Double]] = [
            [0.006299, 0.017298, 0.039533, 0.075189, 0.119007, 0.156756, 0.171834,
             0.156756, 0.119007, 0.075189, 0.039533, 0.017298, 0.006299],
            [0.071303, 0.131514, 0.189879, 0.214607, 0.189879, 0.131514, 0.071303],
            [0.25, 0.5, 0.25],
        ]
        let taps = weights[kernel]
        let expression = taps.enumerated().map {
            "texSample2D(g_Texture0, v_TexCoord[\($0.offset)]) * \($0.element)"
        }.joined(separator: " + ")
        let source = """
        uniform sampler2D g_Texture0;
        uniform vec2 g_Scale;
        uniform vec4 g_Texture0Resolution;
        varying vec2 v_TexCoord[\(taps.count)];
        void main() { gl_FragColor = \(expression); }
        """
        let width = 31, height = 23, cx = 15, cy = 11
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0 ..< (width * height) {
            pixels[pixel * 4 + 3] = 255
        }
        pixels[(cy * width + cx) * 4] = 255
        let uniforms = ["g_Scale": SIMD4<Float>(1, 1, 0, 0),
                        "g_Texture0Resolution": SIMD4(Float(width), Float(height), Float(width), Float(height))]
        let result = try render(source: source, name: "effects/blur_gaussian", width: width, height: height,
                                uniforms: uniforms, pixels: pixels,
                                combos: ["KERNEL": kernel, "VERTICAL": vertical ? 1 : 0])
        for (index, weight) in taps.enumerated() {
            let offset = index - taps.count / 2
            let x = cx + (vertical ? 0 : offset), y = cy + (vertical ? offset : 0)
            #expect(abs(Double(result[(y * width + x) * 4]) - weight * 255) < 2)
        }
        let offAxis = ((cy + (vertical ? 0 : 1)) * width + cx + (vertical ? 1 : 0)) * 4
        #expect(result[offAxis] == 0)
        // A different shader using the same varying array must not acquire Gaussian semantics.
        let control = try render(source: source, name: "effects/unrelated", width: width, height: height,
                                 uniforms: uniforms, pixels: pixels, combos: ["KERNEL": kernel])
        #expect(control[(cy * width + cx) * 4] >= 254)
    }

    private func render(
        source: String, name: String, width: Int, height: Int,
        uniforms: [String: SIMD4<Float>], pixels: [UInt8]? = nil,
        blend: String = "disabled", combos: [String: Int] = [:]
    ) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let translated = try WPEShaderTranspiler.translateFragment(
            shaderName: name, preprocessedSource: source, comboValues: combos
        )
        let vertex = """
        vertex WPEStageIn fidelity_vertex(uint id [[vertex_id]]) {
            float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
            WPEStageIn out;
            out.position = float4(p[id], 0, 1);
            out.uv = float2(p[id].x * 0.5 + 0.5, 0.5 - p[id].y * 0.5);
            return out;
        }
        """
        let library = try device.makeLibrary(source: translated.mslSource + "\n" + vertex, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fidelity_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "wpe_translated_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        WPEMetalPipelineCache.applyBlendMode(blend, to: descriptor.colorAttachments[0])
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        td.storageMode = .shared
        td.usage = [.shaderRead, .renderTarget]
        let target = try #require(device.makeTexture(descriptor: td))
        let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.8, green: 0.6, blue: 0.4, alpha: 0.7)
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(state)
        var slots = [SIMD4<Float>](repeating: .zero, count: 16)
        for slot in translated.uniformLayout {
            slots[slot.slot] = uniforms[slot.name] ?? .zero
        }
        slots.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        if let pixels {
            let input = try #require(device.makeTexture(descriptor: td))
            pixels.withUnsafeBytes {
                input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                              withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
            encoder.setFragmentTexture(input, index: 0)
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .nearest
            sd.magFilter = .nearest
            sd.sAddressMode = .clampToEdge
            sd.tAddressMode = .clampToEdge
            try encoder.setFragmentSamplerState(#require(device.makeSamplerState(descriptor: sd)), index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var result = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&result, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return result
    }
}
#endif
