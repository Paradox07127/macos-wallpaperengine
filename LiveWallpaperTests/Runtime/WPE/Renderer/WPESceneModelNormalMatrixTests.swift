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
        #expect(output.pixelFormat == .rgba8Unorm)
        let center = try centerPixel(output)
        #expect(center.a == 255, "mesh did not cover the centre pixel")

        // Fragment wrote `0.5 - 0.5·n.y` into an identity-transfer work target.
        let lit = Double(center.r) / 255
        let worldNormalY = Float(1 - 2 * lit)
        #expect(
            abs(worldNormalY - expected.y) <= 0.03,
            "worldNormal.y \(worldNormalY) expected \(expected.y) (plain 3×3 would give \(plain.y))"
        )
    }

    @Test("Model reflection reads the prior complete scene including late draws, and resets on reload")
    func reflectionUsesPriorSceneBeforeBloom() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let white = try whiteTexture(device: device)
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 16, height: 16, auto: true),
            sceneCamera: .defaultCamera, sceneHDR: true
        )
        let control = Case(name: "reflection", scale: SIMD3(repeating: 1), angleZ: 0,
                           localNormal: SIMD3(0, 0, 1), isControl: true)
        let template = pipeline(control).layers[0]
        let reflecting = WPERenderPass(
            id: "normal.reflection", phase: .material, shader: "generic4", source: .asset("white"), target: .scene,
            textures: [0: .asset("white")], binds: [:], constants: ["color": .vector([0, 0, 0]), "brightness": .number(4), "roughness": .number(0)],
            combos: ["REFLECTION": 1, "LIGHTING": 0], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let model = WPEPreparedRenderLayer(graphLayer: template.graphLayer, puppetModel: template.puppetModel, passes: [
            .init(pass: reflecting, shader: .init(name: "generic4", vertexSource: "", fragmentSource: "", isBuiltin: true),
                  textureBindings: reflecting.textures, comboValues: reflecting.combos, uniformValues: [:]),
        ])
        let latePass = WPERenderPass(
            id: "late.blue", phase: .material, shader: WPEBuiltinShaderKind.solidLayer.rawValue, source: .asset("white"), target: .scene,
            textures: [:], binds: [:], constants: ["g_Color": .vector([0, 0, 1, 1])], combos: [:],
            blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let lateLayer = WPERenderLayer(objectID: "late", objectName: "late", imagePath: "late", materialPath: nil,
                                       geometry: .init(origin: SIMD3(8, 8, 0), scale: SIMD3(repeating: 1), angles: .zero, alignment: .center,
                                                       size: size, alpha: 1, color: SIMD3(repeating: 1), brightness: 1),
                                       compositeA: "late.a", compositeB: "late.b", localFBOs: [], passes: [latePass])
        let late = WPEPreparedRenderLayer(graphLayer: lateLayer, passes: [
            .init(pass: latePass, shader: .init(name: WPEBuiltinShaderKind.solidLayer.rawValue, vertexSource: "", fragmentSource: "", isBuiltin: true),
                  textureBindings: [:], comboValues: [:], uniformValues: latePass.constants),
        ])
        let first = try executor.render(pipeline: .init(layers: [model, late]), size: size, textures: ["white": white], cameraUniforms: camera)
        #expect(try hdrCenter(first).z > 0.9)
        let published = try #require(executor.reflectionHistoryTexture)
        let publishedScene = try #require(executor.previousFrameHistory?.sceneTexture)
        executor.synchronizeFrameCompletion = false
        _ = try executor.render(pipeline: .init(layers: [model]), size: size, textures: ["white": white], cameraUniforms: camera,
                                deferredPresent: { _, _ in false })
        #expect(executor.reflectionHistoryTexture === published, "a rejected speculative frame must not publish its candidate")
        #expect(executor.previousFrameHistory?.sceneTexture === publishedScene, "a rejected speculative frame must retain ordinary scene history too")
        executor.synchronizeFrameCompletion = true
        // The next frame has no blue draw. The model can only get blue from the
        // previous frame's late layer, which the old current-half-scene copy lost.
        let next = try executor.render(pipeline: .init(layers: [model]), size: size, textures: ["white": white], cameraUniforms: camera)
        #expect(try hdrCenter(next).z > 1)
        executor.releaseRenderScaleDependentResources()
        #expect(executor.reflectionHistoryTexture == nil)
        let fresh = try executor.render(pipeline: .init(layers: [model]), size: size, textures: ["white": white], cameraUniforms: camera)
        #expect(try hdrCenter(fresh).z < 0.05)
    }

    @Test("Directional generic4 matches official GGX diffuse and specular with zero ambient")
    func directionalPBRMatchesOfficialFormula() throws {
        let actual = try renderDirectionalPBR(roughness: 1)
        // N=L=V gives G=1, D=1/pi, F=f0. Expected PBR is
        // ((1-m)*(1-f0)*albedo + f0/4) * lightColor / pi.
        // This differentiates the captured PBR from a Lambert-only brightening.
        let expected = SIMD3<Float>(0.654473, 0.207630, 0.036573)
        #expect(abs(actual.x - expected.x) < 0.005)
        #expect(abs(actual.y - expected.y) < 0.005)
        #expect(abs(actual.z - expected.z) < 0.005)
        #expect(actual.w > 0.99)
    }

    @Test("Zero roughness at the aligned GGX singularity remains finite")
    func zeroRoughnessDirectionalLightingRemainsFinite() throws {
        let actual = try renderDirectionalPBR(roughness: 0)
        #expect(actual.x.isFinite && actual.y.isFinite && actual.z.isFinite && actual.w.isFinite)
        #expect(actual.w > 0.99)
        // Our explicit zero-NDF singular fallback keeps the finite diffuse term;
        // it does not assert that native WPE defines this singular input likewise.
        #expect(actual.x > 0.1 && actual.y > 0.1 && actual.z > 0.01)
    }

    private func renderDirectionalPBR(roughness: Double) throws -> SIMD4<Float> {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let white = try whiteTexture(device: device)
        let testCase = Case(name: "directional PBR", scale: SIMD3(repeating: 1), angleZ: 0,
                            localNormal: SIMD3(0, 0, 1), isControl: true)
        let template = pipeline(testCase).layers[0]
        let pass = WPERenderPass(
            id: "pbr.material", phase: .material, shader: "generic4", source: .asset("white"), target: .scene,
            textures: [0: .asset("white")], binds: [:],
            constants: ["color": .vector([0.5, 0.25, 0.125]), "roughness": .number(roughness), "metallic": .number(0.14)],
            combos: ["LIGHTING": 1, "REFLECTION": 0], blending: "disabled", cullMode: "nocull",
            depthTest: "disabled", depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderLayer(graphLayer: template.graphLayer, puppetModel: template.puppetModel,
                                              passes: [.init(pass: pass, shader: .init(name: "generic4", vertexSource: "", fragmentSource: "", isBuiltin: true),
                                                             textureBindings: pass.textures, comboValues: pass.combos, uniformValues: [:])])
        let lighting = WPESceneDirectionalLightingSnapshot(lights: [.init(objectID: "pbr-light",
                                                                          uniforms: .init(direction: SIMD4(0, 0, 1, 0), radiance: SIMD4(5, 3, 1, 0)), castShadow: false)])
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 16, height: 16, auto: true),
            sceneCamera: WPESceneCamera(center: SIMD3(8.5, 8.5, -1), eye: SIMD3(8.5, 8.5, 1000),
                                        up: SIMD3(0, 1, 0), nearZ: 0.01, farZ: 10000, fov: 50), lightAmbientColor: .zero, lightSkylightColor: .zero, sceneHDR: true
        )
        let output = try executor.render(pipeline: .init(layers: [prepared]), size: size, textures: ["white": white],
                                         cameraUniforms: camera, directionalLighting: lighting)
        return try hdrCenter(output)
    }

    private func hdrCenter(_ texture: MTLTexture) throws -> SIMD4<Float> {
        #expect(texture.pixelFormat == .rgba16Float)
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(texture))
        var pixel = [UInt16](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            staged.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1), mipmapLevel: 0)
        }
        return SIMD4(Float(Float16(bitPattern: pixel[0])), Float(Float16(bitPattern: pixel[1])),
                     Float(Float16(bitPattern: pixel[2])), Float(Float16(bitPattern: pixel[3])))
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
}
#endif
