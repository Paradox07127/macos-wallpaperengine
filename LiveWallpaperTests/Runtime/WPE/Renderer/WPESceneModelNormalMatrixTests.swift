#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

/// Drives the production scene-model path end to end (executor `sceneModelMeshUniforms` fill →
/// `wpe_scene_model_mesh_vertex` → `wpe_scene_model_generic4_fragment`) and reads `worldNormal.y`
/// back out of the lit pixel: skylight (1,1,1) over ambient (0,0,0) makes the hemisphere term
/// `0.5 - 0.5 * worldNormal.y`, so the pixel is a direct readout of the transformed normal.
@Suite("WPE scene model normal matrix", .serialized)
struct WPESceneModelNormalMatrixTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let scale: SIMD3<Double>
        /// Rotation about Z in radians (static geometry angles are radians).
        let angleZ: Double
        let localNormal: SIMD3<Float>
        /// True when the plain model 3×3 and the inverse-transpose agree, so the case must pass before and after the fix.
        let isControl: Bool
        var testDescription: String {
            name
        }

        /// `normalize(Rz · (n / scale))` — the closed form of `transpose(inverse(Rz · S)) · n`.
        /// A (near-)singular scale takes the producer's identity fallback: `normalize(n)`.
        var expectedWorldNormal: SIMD3<Float> {
            let determinant = scale.x * scale.y * scale.z
            guard abs(determinant) >= 1e-8 else { return simd_normalize(localNormal) }
            let scaled = SIMD3<Double>(localNormal) / scale
            return simd_normalize(SIMD3<Float>(rotateZ(scaled)))
        }

        /// What the unfixed vertex (`mat3(model) · n`) produces; kept so each case proves it can tell the two apart.
        var plainWorldNormal: SIMD3<Float> {
            let scaled = SIMD3<Double>(localNormal) * scale
            return simd_normalize(SIMD3<Float>(rotateZ(scaled)))
        }

        private func rotateZ(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let c = cos(angleZ), s = sin(angleZ)
            return SIMD3<Double>(v.x * c - v.y * s, v.x * s + v.y * c, v.z)
        }
    }

    private static let cases: [Case] = [
        Case(name: "uniform scale 2,2,2 (control)", scale: SIMD3<Double>(2, 2, 2), angleZ: 0,
             localNormal: SIMD3<Float>(0, 1, 1), isControl: true),
        Case(name: "non-uniform scale 1,2,1", scale: SIMD3<Double>(1, 2, 1), angleZ: 0,
             localNormal: SIMD3<Float>(0, 1, 1), isControl: false),
        // Mirror: WPE's g_NormalModelMatrix is the bare inverse-transpose, no det-sign flip.
        Case(name: "negative scale -2,1,1", scale: SIMD3<Double>(-2, 1, 1), angleZ: 0,
             localNormal: SIMD3<Float>(1, 1, 0), isControl: false),
        Case(name: "rotate Z 90° + scale 2,1,1", scale: SIMD3<Double>(2, 1, 1), angleZ: .pi / 2,
             localNormal: SIMD3<Float>(1, 1, 0), isControl: false),
        // Singular axis is Z so the quad keeps its screen coverage; det = 1e-9 < 1e-8 → identity fallback.
        Case(name: "near-singular scale 1,1,1e-9", scale: SIMD3<Double>(1, 1, 1e-9), angleZ: 0,
             localNormal: SIMD3<Float>(0, 1, 1), isControl: false),
    ]

    private let size = CGSize(width: 16, height: 16)

    @Test("Lit pixel encodes the inverse-transpose world normal", arguments: Self.cases)
    func worldNormalUsesInverseTranspose(testCase: Case) throws {
        let expected = testCase.expectedWorldNormal
        let plain = testCase.plainWorldNormal
        if testCase.isControl {
            #expect(abs(expected.y - plain.y) < 0.001)
        } else {
            #expect(abs(expected.y - plain.y) > 0.2, "case cannot tell inverse-transpose from the plain 3×3")
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let white = try whiteTexture(device: device)
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 16, height: 16, auto: true),
            sceneCamera: .defaultCamera,
            lightAmbientColor: SIMD3<Double>(0, 0, 0),
            lightSkylightColor: SIMD3<Double>(1, 1, 1)
        )
        let output = try executor.render(
            pipeline: pipeline(testCase), size: size, textures: ["white": white], cameraUniforms: camera
        )
        #expect(output.pixelFormat == .rgba8Unorm_srgb)
        let center = try centerPixel(output)
        #expect(center.a == 255, "mesh did not cover the centre pixel")

        // Fragment wrote linear `0.5 - 0.5·n.y`; the target is sRGB-encoded.
        let lit = srgbToLinear(Double(center.r) / 255)
        let worldNormalY = Float(1 - 2 * lit)
        #expect(
            abs(worldNormalY - expected.y) <= 0.03,
            "worldNormal.y \(worldNormalY) expected \(expected.y) (plain 3×3 would give \(plain.y))"
        )
    }

    private func pipeline(_ testCase: Case) -> WPEPreparedRenderPipeline {
        let pass = WPERenderPass(
            id: "normal.material", phase: .material, shader: "generic4", source: .asset("white"),
            target: .scene, textures: [0: .asset("white")], binds: [:], constants: [:], combos: [:],
            blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: WPEShaderProgram(name: pass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
            textureBindings: [0: .asset("white")], comboValues: [:], uniformValues: [:]
        )
        let normal = testCase.localNormal
        let model = WPEPuppetModel(version: 23, meshes: [WPEPuppetMesh(
            materialPath: "white",
            vertices: [
                WPEPuppetVertex(position: SIMD3<Float>(-4, -4, 0), uv: SIMD2<Float>(0, 1), normal: normal),
                WPEPuppetVertex(position: SIMD3<Float>(4, -4, 0), uv: SIMD2<Float>(1, 1), normal: normal),
                WPEPuppetVertex(position: SIMD3<Float>(-4, 4, 0), uv: SIMD2<Float>(0, 0), normal: normal),
                WPEPuppetVertex(position: SIMD3<Float>(4, 4, 0), uv: SIMD2<Float>(1, 0), normal: normal),
            ], indices: [0, 1, 2, 2, 1, 3], parts: []
        )])
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 8, -1), scale: testCase.scale, angles: SIMD3<Double>(0, 0, testCase.angleZ),
            alignment: .center, size: CGSize(width: 8, height: 8), alpha: 1,
            color: SIMD3<Double>(1, 1, 1), brightness: 1
        )
        let layer = WPERenderLayer(
            objectID: "normal", objectName: "Normal matrix mesh", imagePath: "normal.mdl", materialPath: nil,
            puppetPath: "normal.mdl", geometry: geometry, compositeA: "a", compositeB: "b",
            localFBOs: [], passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, puppetModel: model, passes: [prepared]),
        ])
    }

    private func whiteTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 255, count: 16)
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 8)
        return texture
    }

    private func centerPixel(_ output: MTLTexture) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let staging = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var pixel = [UInt8](repeating: 0, count: 4)
        staging.getBytes(
            &pixel, bytesPerRow: 4,
            from: MTLRegionMake2D(output.width / 2, output.height / 2, 1, 1), mipmapLevel: 0
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
#endif
