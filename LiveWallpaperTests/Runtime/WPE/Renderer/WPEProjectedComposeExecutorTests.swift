#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Projected composelayer executor", .serialized)
struct WPEProjectedComposeExecutorTests {
    private static let width = 64, height = 36
    private static let size = CGSize(width: width, height: height)
    private static let angles = SIMD3<Double>(8, -8, 0) * .pi / 180
    private static let compositeA = "_rt_imageLayerComposite_compose_a"
    private static let compositeB = "_rt_imageLayerComposite_compose_b"
    private static let tolerance = 2

    private static func geometry(size: CGSize = size, angles: SIMD3<Double> = angles) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: SIMD3(32, 18, 0), scale: SIMD3(1, 1, 1), angles: angles, alignment: .center,
            size: size, alpha: 1, color: SIMD3(1, 1, 1), brightness: 1
        )
    }

    private static func camera(
        fov: Double, overrides: [String: Bool] = [:], motion: WPESceneCameraMotionSample = .identity
    ) -> WPEMetalCameraUniforms {
        WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: Double(width), height: Double(height), auto: true),
            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: fov,
            livePerspectiveOverrides: overrides, sceneMotion: motion
        )
    }

    /// R = 2·column, G = 3·row, B = 40, so an additive draw-back doubles each channel without saturating.
    private static func seedBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let index = (row * width + column) * 4
                bytes[index] = UInt8(column * 2)
                bytes[index + 1] = UInt8(row * 3)
                bytes[index + 2] = 40
                bytes[index + 3] = 255
            }
        }
        return bytes
    }

    private static func seedTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: seedBytes(), bytesPerRow: width * 4)
        return texture
    }

    private static func pass(
        _ id: String, phase: WPERenderPassPhase, shader: String, source: WPETextureReference,
        target: WPERenderTarget, blending: String = "disabled"
    ) -> WPEPreparedRenderPass {
        let raw = WPERenderPass(
            id: id, phase: phase, shader: shader, source: source, target: target, textures: [0: source],
            binds: [:], constants: [:], combos: [:], blending: blending, cullMode: "nocull",
            depthTest: "disabled", depthWrite: "disabled"
        )
        return WPEPreparedRenderPass(
            pass: raw, shader: WPEShaderProgram(name: shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
            textureBindings: [0: source], comboValues: [:], uniformValues: [:]
        )
    }

    private static let copyPhase = WPERenderPassPhase.command(file: "effects/copy/effect.json")

    private static func composeLayer(
        geometry: WPERenderLayerGeometry = geometry(), sceneCopyFinal: Bool = true
    ) -> WPEPreparedRenderLayer {
        let capture = pass("compose.0", phase: .material, shader: "compose",
                           source: .fbo("_rt_FullFrameBuffer"), target: .layerComposite(name: compositeA))
        let effect = pass("compose.1", phase: copyPhase, shader: "commands/copy",
                          source: .fbo(compositeA), target: .layerComposite(name: compositeB))
        let drawBack = sceneCopyFinal
            ? pass("compose.2", phase: .command(file: WPERenderPassPhase.sceneCopyCommandFile),
                   shader: WPERenderPassPhase.sceneCopyCommandFile, source: .fbo(compositeB), target: .scene,
                   blending: "additive")
            : pass("compose.2", phase: copyPhase, shader: "commands/copy", source: .fbo(compositeB), target: .scene,
                   blending: "additive")
        let passes = [capture, effect, drawBack]
        let layer = WPERenderLayer(
            objectID: "compose", objectName: "Compose", imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer.json", geometry: geometry,
            compositeA: compositeA, compositeB: compositeB, localFBOs: [], passes: passes.map(\.pass)
        )
        return WPEPreparedRenderLayer(graphLayer: layer, passes: passes)
    }

    private static func seedLayer() -> WPEPreparedRenderLayer {
        let seed = pass("seed.0", phase: copyPhase, shader: "commands/copy", source: .image("seed"), target: .scene)
        let layer = WPERenderLayer(
            objectID: "seed", objectName: "Seed", imagePath: "seed", materialPath: nil, geometry: .identity,
            compositeA: "_rt_imageLayerComposite_seed_a", compositeB: "_rt_imageLayerComposite_seed_b",
            localFBOs: [], passes: [seed.pass]
        )
        return WPEPreparedRenderLayer(graphLayer: layer, passes: [seed])
    }

    private static func pipeline(compose: WPEPreparedRenderLayer? = composeLayer()) -> WPEPreparedRenderPipeline {
        WPEPreparedRenderPipeline(layers: [seedLayer()] + (compose.map { [$0] } ?? []))
    }

    private static func render(
        _ executor: WPEMetalRenderExecutor, _ pipeline: WPEPreparedRenderPipeline,
        seed: MTLTexture, camera: WPEMetalCameraUniforms
    ) throws -> [UInt8] {
        let output = try executor.render(pipeline: pipeline, size: size, textures: ["seed": seed], cameraUniforms: camera)
        #expect(output.pixelFormat == .rgba8Unorm)
        let staging = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            staging.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    private static func doubled(_ bytes: [UInt8]) -> [UInt8] {
        bytes.enumerated().map { index, byte in index % 4 == 3 ? byte : UInt8(min(255, Int(byte) * 2)) }
    }

    @Test("A perspective composelayer draws back only inside its projected quad")
    func projectedDrawBackMatchesCPUQuad() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let seed = try Self.seedTexture(device: device)
        let compose = Self.composeLayer()
        let bytes = try Self.render(executor, Self.pipeline(compose: compose), seed: seed,
                                    camera: Self.camera(fov: 90, overrides: ["compose": true]))
        #expect(executor.sceneCaptureUtilityOutputGeometry(for: compose.graphLayer) == .projected)

        let quad = try #require(WPEProjectedComposeQuad(
            origin: SIMD3(32, 18, 0), scale: SIMD3(1, 1, 1), angles: Self.angles,
            size: Self.size, sceneSize: Self.size, fovDegrees: 90
        ))
        func inside(_ column: Int, _ row: Int) -> Bool {
            quad.contains(screenPixel: SIMD2(Double(column) + 0.5, Double(row) + 0.5))
        }
        let seedBytes = Self.seedBytes()
        var insideCount = 0, outsideCount = 0, worst = 0
        // Interior pixels whose 3×3 neighbourhood agrees on inside/outside; borders sample clamped edges.
        for row in 1 ..< Self.height - 1 {
            for column in 1 ..< Self.width - 1 {
                let isInside = inside(column, row)
                let neighbours = (-1 ... 1).flatMap { dy in (-1 ... 1).map { dx in inside(column + dx, row + dy) } }
                guard neighbours.allSatisfy({ $0 == isInside }) else { continue }
                let index = (row * Self.width + column) * 4
                let factor = isInside ? 2 : 1
                for channel in 0 ..< 3 {
                    let error = abs(Int(bytes[index + channel]) - Int(seedBytes[index + channel]) * factor)
                    worst = max(worst, error)
                    #expect(error <= Self.tolerance, "pixel (\(column), \(row)) channel \(channel) inside=\(isInside)")
                }
                insideCount += isInside ? 1 : 0
                outsideCount += isInside ? 0 : 1
            }
        }
        #expect(insideCount > 200 && outsideCount > 50, "inside \(insideCount) outside \(outsideCount)")
        print("WPEProjectedComposeExecutorTests draw-back worst error \(worst), inside \(insideCount), outside \(outsideCount)")
    }

    @Test("Without a live perspective bit the frame is today's fullscreen passthrough")
    func overridesOffKeepFullscreenPath() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let seed = try Self.seedTexture(device: device)
        let compose = Self.composeLayer()
        let pipeline = Self.pipeline(compose: compose)
        let expected = Self.doubled(Self.seedBytes())
        for camera in [Self.camera(fov: 0), Self.camera(fov: 90), Self.camera(fov: 90, overrides: ["compose": false])] {
            #expect(try Self.render(executor, pipeline, seed: seed, camera: camera) == expected)
            #expect(executor.sceneCaptureUtilityOutputGeometry(for: compose.graphLayer) == .fullscreen)
            #expect(executor.targetPool.projectedComposeObjectIDs.isEmpty)
        }
    }

    @Test("Camera motion or a non scene-copy final pass keeps today's route")
    func admissionFallsBack() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let seed = try Self.seedTexture(device: device)
        let rotating = Self.camera(fov: 90, overrides: ["compose": true],
                                   motion: WPESceneCameraMotionSample(origin: .zero, zoom: 1, angles: SIMD3(0, 0, 0.1)))
        _ = try Self.render(executor, Self.pipeline(), seed: seed, camera: rotating)
        #expect(executor.targetPool.projectedComposeObjectIDs.isEmpty)
        let zooming = Self.camera(fov: 90, overrides: ["compose": true],
                                  motion: WPESceneCameraMotionSample(origin: .zero, zoom: 1.2, angles: .zero))
        _ = try Self.render(executor, Self.pipeline(), seed: seed, camera: zooming)
        #expect(executor.targetPool.projectedComposeObjectIDs.isEmpty)
        let plainCopy = Self.composeLayer(sceneCopyFinal: false)
        _ = try Self.render(executor, Self.pipeline(compose: plainCopy), seed: seed,
                            camera: Self.camera(fov: 90, overrides: ["compose": true]))
        #expect(executor.targetPool.projectedComposeObjectIDs.isEmpty)
        #expect(executor.sceneCaptureUtilityOutputGeometry(for: plainCopy.graphLayer) == .fullscreen)
    }

    @Test("Repeat frames resolve no new pass pipelines, with or without projection")
    func repeatFramesReuseCachedPipelines() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let seed = try Self.seedTexture(device: device)
        for camera in [Self.camera(fov: 0), Self.camera(fov: 90, overrides: ["compose": true])] {
            let executor = try WPEMetalRenderExecutor(device: device)
            _ = try Self.render(executor, Self.pipeline(), seed: seed, camera: camera)
            let resolved = executor.passPipelineResolveCount
            #expect(resolved > 0)
            _ = try Self.render(executor, Self.pipeline(), seed: seed, camera: camera)
            #expect(executor.passPipelineResolveCount == resolved)
        }
    }

    @Test("A projected layer composite is the authored size times the pixel scale")
    func projectedLayerCompositeUsesAuthoredSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        pool.pixelScale = 0.5
        let scene = CGSize(width: 3840, height: 2160)
        let layer = Self.composeLayer(geometry: WPERenderLayerGeometry(
            origin: SIMD3(1920, 1080, 0), scale: SIMD3(1.3, 1.3, 1.5), angles: SIMD3(2.5, -2.5, 0) * .pi / 180,
            alignment: .center, size: CGSize(width: 3000, height: 1700), alpha: 1, color: SIMD3(1, 1, 1), brightness: 1
        )).graphLayer
        func key() -> WPEMetalRenderTargetKey {
            pool.diagnosticKey(for: .layerComposite(name: Self.compositeA), layer: layer, sceneSize: scene, declaredFBOs: [:])
        }
        #expect(key().width == 1920 && key().height == 1080)
        pool.projectedComposeObjectIDs = ["compose"]
        #expect(key().width == 1500 && key().height == 850)
        pool.projectedComposeObjectIDs = []
        #expect(key().width == 1920 && key().height == 1080)
    }
}
#endif
