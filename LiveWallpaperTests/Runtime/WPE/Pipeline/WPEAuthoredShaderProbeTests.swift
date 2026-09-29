#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Authored vertex semantic GPU probes", .serialized)
struct WPEAuthoredShaderProbeTests {
    @Test func nonlinearVertexCalculationIsInterpolatedBeforeFragment() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_Value;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_Value = a_TexCoord * a_TexCoord;
        }
        """
        let fragment = "varying vec2 v_Value; void main() { gl_FragColor = vec4(v_Value, 0.0, 1.0); }"
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let uv = SIMD2<Float>((Float(x) + 0.5) / 4, (Float(y) + 0.5) / 4)
                let pixel = pixels[y * 4 + x]
                // Squaring corner values leaves 0/1 corners; raster interpolation yields UV.
                #expect(abs(pixel.x - uv.x) < 0.00001)
                #expect(abs(pixel.y - uv.y) < 0.00001)
                #expect(abs(pixel.x - uv.x * uv.x) > 0.05)
            }
        }
    }

    @Test func depthParallaxBasisUsesVertexMatrixAndIndependentFragmentBinding() throws {
        let vertex = """
        attribute vec3 a_Position;
        uniform mat4 shared;
        uniform vec2 u_Pointer;
        varying vec2 v_Parallax;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            vec2 dirX = normalize(shared[0].xy);
            vec2 dirY = normalize(shared[1].xy);
            vec2 pointer = u_Pointer * 2.0 - 1.0;
            v_Parallax = 0.5 + 0.5 * (pointer.x * dirX + pointer.y * dirY);
        }
        """
        let fragment = """
        varying vec2 v_Parallax;
        uniform float shared;
        void main() { gl_FragColor = vec4(v_Parallax, shared, 1.0); }
        """
        let fixtures: [([Double], SIMD2<Float>)] = [
            // Actual captured positive axes: normalization cancels the non-unit scale.
            ([0.914285660, 0, 0, 0, 0, 0.863999963, 0, 0, 0, 0, 3999.999756, 0, -0.000359072, -0.045459863, -1499.999878, 1], .init(0.75, 0.25)),
            ([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], .init(0.75, 0.25)),
            ([0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], .init(0.75, 0.75)),
            ([-2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], .init(0.25, 0.25)),
        ]
        for (matrix, expected) in fixtures {
            let pixels = try replay(vertex: vertex, fragment: fragment,
                                    vertexValues: ["shared": .vector(matrix), "u_Pointer": .vector([0.75, 0.25])],
                                    fragmentValues: ["shared": .number(0.375)])
            for pixel in pixels {
                #expect(abs(pixel.x - expected.x) < 0.00001)
                #expect(abs(pixel.y - expected.y) < 0.00001)
                #expect(pixel.z == 0.375 && pixel.w == 1)
            }
        }
    }

    @Test func prototypeRejectsUnsupportedResourcesInsteadOfDeletingTheirContract() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let vertex = "attribute vec3 a_Position; varying vec2 uv; void main() { gl_Position = vec4(a_Position, 1.0); uv = vec2(0.5); }"
        #expect(throws: WPEAuthoredShaderProbe.Failure.self) {
            try WPEAuthoredShaderProbe.compile(vertex: vertex,
                                               fragment: "uniform sampler2D g_Texture0; varying vec2 uv; void main() { gl_FragColor = texture(g_Texture0, uv); }", device: device)
        }
        #expect(throws: WPEAuthoredShaderProbe.Failure.self) {
            try WPEAuthoredShaderProbe.compile(vertex: vertex,
                                               fragment: "varying vec3 uv; void main() { gl_FragColor = vec4(uv, 1.0); }", device: device)
        }
    }

    @Test func coldDiskAndMemoryReplayRetainAuthoredInterfaceWithoutChangingMSL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = WPEShaderTranslationCache(rootURL: root)
        let compiler = WPESwiftShaderCompiler(device: device, translationCache: cache)
        let request = WPEShaderCompileRequest(
            shaderName: "stage-inventory", processedVertexSource: "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }",
            processedFragmentSource: "void main() { gl_FragColor = vec4(0.5); }",
            sourceHash: "stage-inventory-fixture", comboValues: [:], textureBindings: [:]
        )
        let cold = try compiler.compile(request)
        #expect(cold.shaderInterface?.variables(stage: .vertex, kind: .attribute).count == 1)
        cache.dropMemoryForTesting()
        let disk = try compiler.compile(request)
        let memory = try compiler.compile(request)
        #expect(disk.shaderInterface == cold.shaderInterface && memory.shaderInterface == cold.shaderInterface)
        #expect(disk.mslSource == cold.mslSource && memory.mslSource == cold.mslSource)
        #expect(cache.diskHitCountForTesting == 1 && cache.memoryHitCountForTesting == 1)
    }

    private func replay(
        vertex: String, fragment: String,
        vertexValues: [String: WPESceneShaderConstantValue] = [:],
        fragmentValues: [String: WPESceneShaderConstantValue] = [:]
    ) throws -> [SIMD4<Float>] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let result = try WPEAuthoredShaderProbe.compile(vertex: vertex, fragment: fragment, device: device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = result.library.makeFunction(name: "wpe_probe_vertex")
        descriptor.fragmentFunction = result.library.makeFunction(name: "wpe_probe_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false)
        td.storageMode = .shared
        td.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor: td))
        let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(-99, -99, -99, -99)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        let vs = try packed(result.vertexUniforms, vertexValues)
        let fs = try packed(result.fragmentUniforms, fragmentValues)
        vs.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        fs.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed && command.error == nil)
        var pixels = [SIMD4<Float>](repeating: .zero, count: 16)
        pixels.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: 64, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        }
        return pixels
    }

    private func packed(_ layout: [WPEUniformSlot], _ values: [String: WPESceneShaderConstantValue]) throws -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: .zero, count: max(1, layout.reduce(0) { $0 + $1.slotCount }))
        try slots.withUnsafeMutableBufferPointer { storage in
            for uniform in layout {
                try WPEUniformPacking.pack(values[uniform.name], uniform: uniform, into: storage)
            }
        }
        return slots
    }
}
#endif
