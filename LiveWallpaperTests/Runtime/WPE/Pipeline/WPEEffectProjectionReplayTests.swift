#if !LITE_BUILD
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Effect projection isolated GPU replay", .serialized)
struct WPEEffectProjectionReplayTests {
    private static let matrixName = "g_EffectTextureProjectionMatrixInverse"
    private static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    @Test
    func missingInputMatchesExplicitZeroBeforeNormalization() throws {
        let missing = try replay(matrix: nil, normalized: false)
        let zero = try replay(matrix: [Double](repeating: 0, count: 16), normalized: false)
        #expect(missing == zero)
        #expect(missing == [0, 0, 0, 0])
        #expect(try replay(matrix: Self.identity, normalized: false) == [1, 0, 0, 1])
    }

    @Test
    func nonSymmetricColumnsSurviveCastAndUpload() throws {
        // Column-major, with translation and out-of-plane entries that CAST3X3/xy must discard.
        let matrix: [Double] = [2, 3, 11, 0, 5, 7, 13, 0, 17, 19, 23, 0, 29, 31, 37, 1]
        let first = try replay(matrix: matrix, normalized: false)
        let second = try replay(matrix: matrix, normalized: false)
        #expect(first == [2, 3, 5, 7])
        #expect(first.map(\.bitPattern) == second.map(\.bitPattern))
    }

    @Test
    func normalizedBasisRespondsToRotationMirrorAndShear() throws {
        let fixtures: [(name: String, matrix: [Double], expected: [Float])] = [
            ("identity", Self.identity, [0.75, 0.25, 0, 1]),
            ("positive-scale", [2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0, 9, 8, 7, 1], [0.75, 0.25, 0, 1]),
            ("quarter-turn", [0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], [0.75, 0.75, 0, 1]),
            ("mirror-x", [-2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], [0.25, 0.25, 0, 1]),
            ("shear", [2, 3, 0, 0, 5, 7, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
             [Float(0.5 + 0.25 * (2 / sqrt(13.0) - 5 / sqrt(74.0))),
              Float(0.5 + 0.25 * (3 / sqrt(13.0) - 7 / sqrt(74.0))), 0, 1]),
        ]
        for fixture in fixtures {
            let actual = try replay(matrix: fixture.matrix, normalized: true)
            for (value, expected) in zip(actual, fixture.expected) {
                #expect(value.isFinite && abs(value - expected) < 0.00001, "\(fixture.name)")
            }
        }
    }

    @Test
    func matrixConstructorsPreserveGLSLComponents() throws {
        let matrix: [Double] = [2, 3, 11, 0, 5, 7, 13, 0, 17, 19, 23, 0, 29, 31, 37, 1]
        let fixtures: [(body: String, expected: [Float])] = [
            ("mat2 m = mat2(g_EffectTextureProjectionMatrixInverse); vec4 probe = vec4(m[0], m[1]);", [2, 3, 5, 7]),
            ("mat2 m = mat2(mat3(g_EffectTextureProjectionMatrixInverse)); vec4 probe = vec4(m[0], m[1]);", [2, 3, 5, 7]),
            ("mat4 m = mat4(mat2(g_EffectTextureProjectionMatrixInverse)); vec4 probe = vec4(m[0][0], m[1][1], m[2][2], m[3][3]);", [2, 7, 1, 1]),
            ("mat4 m = mat4(mat3(g_EffectTextureProjectionMatrixInverse)); vec4 probe = vec4(m[0][0], m[1][1], m[2][2], m[3][3]);", [2, 7, 23, 1]),
            ("mat3 m = mat3(mat2(g_EffectTextureProjectionMatrixInverse)); vec4 probe = vec4(m[0][0], m[1][1], m[2][2], m[2][0]);", [2, 7, 1, 0]),
            ("mat3 m = mat3(2.0); vec4 probe = vec4(m[0][0], m[0][1], m[1][0], m[1][1]);", [2, 0, 0, 2]),
            ("mat2 m = mat2(vec4(2.0, 3.0, 5.0, 7.0)); vec4 probe = vec4(m[0], m[1]);", [2, 3, 5, 7]),
            ("mat2 m = mat2(vec2(2.0, 3.0), vec2(5.0, 7.0)); vec4 probe = vec4(m[0], m[1]);", [2, 3, 5, 7]),
        ]
        for fixture in fixtures {
            #expect(try replay(matrix: matrix, normalized: false, bodyOverride: fixture.body) == fixture.expected)
        }
    }

    private func replay(matrix: [Double]?, normalized: Bool, bodyOverride: String? = nil) throws -> [Float] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let request = request(normalized: normalized, bodyOverride: bodyOverride)
        defer { WPEShaderTranslationCache.shared.remove(request.translationCacheKey) }
        let result = try WPESwiftShaderCompiler(device: device).compile(request)
        let pass = pass(matrix: matrix)
        let slots = try executor.packTranslatedUniforms(for: pass, layout: result.uniformLayout)
        let matrixSlot = try #require(result.uniformLayout.first { $0.name == Self.matrixName })
        #expect(matrixSlot.slotCount == 4)
        let uploaded = slots[matrixSlot.slot ..< matrixSlot.slot + 4].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        #expect(uploaded == (matrix ?? [Double](repeating: 0, count: 16)).map(Float.init))

        let pipeline = try executor.translatedPipelineState(
            for: result, blendMode: "disabled", alphaWritePolicy: .all,
            colorPixelFormat: .rgba32Float, depthPixelFormat: .invalid
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(-99, -99, -99, -99)
        renderPass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: renderPass))
        encoder.setRenderPipelineState(pipeline)
        slots.withUnsafeBytes {
            if let base = $0.baseAddress {
                encoder.setVertexBytes(base, length: $0.count, index: 0)
                encoder.setFragmentBytes(base, length: $0.count, index: 0)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)
        var pixels = [Float](repeating: 0, count: 16)
        pixels.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        let first = Array(pixels.prefix(4))
        for offset in stride(from: 4, to: 16, by: 4) {
            #expect(Array(pixels[offset ..< offset + 4]) == first)
        }
        return first
    }

    private func request(normalized: Bool, bodyOverride: String?) -> WPEShaderCompileRequest {
        // Reduced depthparallax basis calculation; no textures, time, audio, scripts or RNG.
        let declarations = """
        uniform mat4 g_EffectTextureProjectionMatrixInverse;
        uniform vec2 u_ProbePointer;
        """
        let basisBody = """
        mat3 rot = mat3(g_EffectTextureProjectionMatrixInverse);
        vec2 projectedDirX = (rot * vec3(1.0, 0.0, 0.0)).xy;
        vec2 projectedDirY = (rot * vec3(0.0, 1.0, 0.0)).xy;
        """ + (normalized ? """

        vec2 prlxInput = u_ProbePointer * 2.0 - 1.0;
        vec2 offset = normalize(projectedDirX) * prlxInput.x + normalize(projectedDirY) * prlxInput.y;
        vec4 probe = vec4(offset * 0.5 + 0.5, 0.0, 1.0);
        """ : "\nvec4 probe = vec4(projectedDirX, projectedDirY);")
        let body = bodyOverride ?? basisBody
        let position = "attribute vec3 a_Position;\n"
        let vertex = position + "void main() { gl_Position = vec4(a_Position, 1.0); }"
        let fragment = declarations + "\nvoid main() {\n" + body + "\ngl_FragColor = probe; }"
        let hash = SHA256.hash(data: Data((vertex + "\u{0}" + fragment).utf8)).map { String(format: "%02x", $0) }.joined()
        return WPEShaderCompileRequest(shaderName: "effect_projection_probe", processedVertexSource: vertex,
                                       processedFragmentSource: fragment, sourceHash: hash, comboValues: [:], textureBindings: [:])
    }

    private func pass(matrix: [Double]?) -> WPEPreparedRenderPass {
        var values: [String: WPESceneShaderConstantValue] = ["u_ProbePointer": .vector([0.75, 0.25])]
        if let matrix {
            values[Self.matrixName] = .vector(matrix)
        }
        return WPEPreparedRenderPass(
            pass: WPERenderPass(id: "projection.probe", phase: .effect(file: "probe"), shader: "effect_projection_probe",
                                source: .image("unused"), target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                                blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"),
            shader: nil, textureBindings: [:], comboValues: [:], uniformValues: values
        )
    }
}
#endif
