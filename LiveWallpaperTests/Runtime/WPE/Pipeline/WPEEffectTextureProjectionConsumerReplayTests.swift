#if !LITE_BUILD
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

/// Replays the fragment-only reconstructions of `v_TexCoordIris` (FOLLOWCURSOR) and `v_ParallaxOffset`
/// on the GPU; every rule input is declared only in the vertex source, so injection is exercised too.
@Suite("Effect texture projection consumers GPU replay", .serialized)
struct WPEEffectTextureProjectionConsumerReplayTests {
    private static let matrixName = "g_EffectTextureProjectionMatrixInverse"

    @Test
    func irisFollowCursorMatchesCapturedFrame() throws {
        let inverse: [Double] = [
            0.94426, 0, 0, 0,
            0, 0.94426, 0, 0,
            0, 0, 3777.0415, 0,
            0.03726, -0.03833, -1888.52075, 1,
        ]
        let actual = try replay(
            shaderName: "workshop/2973943998/effects/iris_movement__",
            vertexUniforms: """
            uniform vec2 g_PointerPosition;
            uniform vec2 g_CursorScale;
            uniform vec2 g_CursorScaleMultiplier;
            uniform vec2 g_CursorScaleLimit;
            """,
            varying: "v_TexCoordIris",
            values: [
                "g_PointerPosition": .vector([0.99479, 0.94907]),
                "g_CursorScale": .vector([1.55, 1.55]),
                "g_CursorScaleMultiplier": .vector([1.23, 1.23]),
                "g_CursorScaleLimit": .vector([1, 1]),
            ],
            matrix: inverse
        )
        #expect(abs(actual[0] - -0.00185251) <= 1e-6, "\(actual)")
        #expect(abs(actual[1] - -0.00168994) <= 1e-6, "\(actual)")
    }

    @Test
    func depthParallaxFollowsRotation() throws {
        let (a, b, c, d) = (0.4330125, 0.4444454, -0.1406253, 0.4330124)
        let det = a * d - c * b
        let inverse: [Double] = [
            d / det, -b / det, 0, 0,
            -c / det, a / det, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        let actual = try replayParallax(matrix: inverse)
        #expect(abs(actual[0] - 0.60867884) <= 1e-4, "\(actual)")
        #expect(abs(actual[1] - 0.26163802) <= 1e-4, "\(actual)")
    }

    @Test
    func depthParallaxFollowsMirror() throws {
        let inverse: [Double] = [-0.5, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let actual = try replayParallax(matrix: inverse)
        #expect(abs(actual[0] - 0.3) <= 1e-5, "\(actual)")
        #expect(abs(actual[1] - 0.4) <= 1e-5, "\(actual)")
    }

    @Test
    func depthParallaxWithZeroMatrixFallsBackToParallaxPosition() throws {
        let actual = try replayParallax(matrix: [Double](repeating: 0, count: 16))
        #expect(actual[0].isFinite && actual[1].isFinite, "\(actual)")
        #expect(abs(actual[0] - 0.7) <= 1e-5, "\(actual)")
        #expect(abs(actual[1] - 0.4) <= 1e-5, "\(actual)")
    }

    private func replayParallax(matrix: [Double]) throws -> [Float] {
        try replay(
            shaderName: "effects/depthparallax",
            vertexUniforms: "uniform vec2 g_ParallaxPosition;",
            varying: "v_ParallaxOffset",
            values: ["g_ParallaxPosition": .vector([0.7, 0.4])],
            matrix: matrix
        )
    }

    private func replay(
        shaderName: String,
        vertexUniforms: String,
        varying: String,
        values: [String: WPESceneShaderConstantValue],
        matrix: [Double]
    ) throws -> [Float] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let request = request(shaderName: shaderName, vertexUniforms: vertexUniforms, varying: varying)
        defer { WPEShaderTranslationCache.shared.remove(request.translationCacheKey) }
        let result = try WPESwiftShaderCompiler(device: device).compile(request)
        var uniformValues = values
        uniformValues[Self.matrixName] = .vector(matrix)
        let pass = WPEPreparedRenderPass(
            pass: WPERenderPass(id: "projection.consumer", phase: .effect(file: "probe"), shader: shaderName,
                                source: .image("unused"), target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                                blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"),
            shader: nil, textureBindings: [:], comboValues: [:], uniformValues: uniformValues
        )
        let slots = try executor.packTranslatedUniforms(for: pass, layout: result.uniformLayout)
        let matrixSlot = try #require(result.uniformLayout.first { $0.name == Self.matrixName })
        let uploaded = slots[matrixSlot.slot ..< matrixSlot.slot + 4].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        #expect(uploaded == matrix.map(Float.init))

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

    private func request(shaderName: String, vertexUniforms: String, varying: String) -> WPEShaderCompileRequest {
        let vertex = """
        uniform mat4 \(Self.matrixName);
        \(vertexUniforms)
        attribute vec3 a_Position;
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """
        let fragment = """
        varying vec2 \(varying);
        void main() { gl_FragColor = vec4(\(varying), 0.0, 1.0); }
        """
        let hash = SHA256.hash(data: Data((shaderName + "\u{0}" + vertex + "\u{0}" + fragment).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return WPEShaderCompileRequest(shaderName: shaderName, processedVertexSource: vertex,
                                       processedFragmentSource: fragment, sourceHash: hash, comboValues: [:], textureBindings: [:])
    }
}
#endif
