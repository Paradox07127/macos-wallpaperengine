#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("WPE scene camera motion")
struct WPECameraMotionTests {
    @Test("Loading time does not consume the intro; the first draw retains the seed")
    func firstDrawClockAndSuspend() throws {
        let animated = try #require(WPEValueParser.animatedValue(["value": 4.5, "animation": ["c0": [["frame": 0, "value": 3], ["frame": 10, "value": 1]], "options": ["fps": 10, "length": 10, "mode": "single"]]]))
        var playback = WPECameraMotionPlayback(definition: .init(objectID: "cam", origin: .zero, zoom: 4.5, zoomAnimation: animated))
        #expect(playback.sample(sceneTime: 120).zoom == 4.5)
        #expect(playback.sample(sceneTime: 120.25).zoom == 3)
        #expect(playback.sample(sceneTime: 120.5).zoom == 2.5)
        playback.suspend()
        #expect(playback.sample(sceneTime: 900).zoom == 2)
        #expect(playback.sample(sceneTime: 900.25).zoom == 2)
        #expect(playback.sample(sceneTime: 900.5).zoom == 1.5)
        #expect(playback.sample(sceneTime: 900.75).zoom == 1)
        #expect(!playback.needsFrames)
    }

    @Test("Perspective zoom dollies the eye without changing focal scale")
    func capturedHinaPerspective() {
        // First Windows Hina frame: zoom 4.5, object MVP w=240 at z=0,
        // x/y focal terms 0.5625/1, unchanged through the opening.
        let camera = makeCamera().applyingSceneMotion(.init(origin: .zero, zoom: 4.5))
        let m = camera.objectPerspectiveViewProjectionMatrix
        #expect(abs(m[0] - 0.5625) < 1e-8)
        #expect(abs(m[5] - 1) < 1e-8)
        #expect(abs(m[15] - 240) < 1e-8)
        let panned = makeCamera().applyingSceneMotion(.init(origin: SIMD3(-100, -200, 0), zoom: 2))
        let matrix = panned.objectPerspectiveViewProjectionMatrix
        #expect(abs(matrix[12] - (-1080 + 100 * 0.5625)) < 1e-8)
        #expect(abs(matrix[13] - (-1080 + 200)) < 1e-8)
        #expect(abs(matrix[15] - 540) < 1e-8)
    }

    @Test("Orthographic objects pan about the authored camera centre and scale their extent")
    func nativeQuadPlacement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 32, mipmapped: false)
        let texture = try #require(device.makeTexture(descriptor: desc))
        let layer = makeLayer(geometry: geometry(origin: SIMD3(2020, 1180, 0), size: CGSize(width: 32, height: 32)), passes: [])
        let camera = makeCamera().applyingSceneMotion(.init(origin: SIMD3(100, 100, 0), zoom: 2))
        let quad = executor.objectQuadUniforms(for: layer, sceneSize: camera.renderSize, sourceTexture: texture, cameraUniforms: camera)
        #expect(quad.centerAndSize == SIMD4(0, 0, 64, 64))
    }

    @Test("Local effect VP stays unchanged while the scene MVP consumes camera motion")
    func localCameraScope() {
        let local = pass("local", target: .fbo(name: "local"))
        let scene = pass("scene", target: .scene)
        let graph = makeLayer(geometry: geometry(origin: SIMD3(100, 200, 0)), passes: [local, scene])
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: [local, scene].map {
            WPEPreparedRenderPass(pass: $0, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:])
        })])
        let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(0.5, 0.5))
        let base = makeCamera()
        let still = pipeline.addingMetalRuntimeUniforms(runtime, camera: base).frameUniforms
        let moving = pipeline.addingMetalRuntimeUniforms(runtime, camera: base.applyingSceneMotion(.init(origin: SIMD3(-100, -200, 0), zoom: 2))).frameUniforms
        #expect(still.value(named: "g_ModelViewProjectionMatrix", passID: "local") == moving.value(named: "g_ModelViewProjectionMatrix", passID: "local"))
        #expect(still.value(named: "g_ModelViewProjectionMatrix", passID: "scene") != moving.value(named: "g_ModelViewProjectionMatrix", passID: "scene"))
    }

    @Test("A camera-only scene keeps producing frames until its single intro completes")
    @MainActor
    func cameraDemand() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.load()
        let animation = try #require(WPEValueParser.animatedValue(["value": 3, "animation": ["c0": [["frame": 0, "value": 3], ["frame": 10, "value": 1]], "options": ["fps": 10, "length": 10, "mode": "single"]]]))
        stack.renderer.cameraMotionPlayback = .init(definition: .init(objectID: "cam", origin: .zero, zoom: 3, zoomAnimation: animation))
        stack.renderer.synchronizeFrameDemand()
        #expect(stack.renderer.frameDemand.contains(.animations))
        #expect(!stack.surface.mtkView.isPaused)
        for time in [100.0, 100.5, 101.0, 101.5] {
            _ = stack.renderer.cameraMotionPlayback?.sample(sceneTime: time)
        }
        stack.renderer.synchronizeFrameDemand()
        #expect(!stack.renderer.frameDemand.contains(.animations))
        #expect(stack.surface.mtkView.isPaused)
    }

    @Test("The actual GPU quad moves and grows through the scene camera")
    func gpuCameraPlacement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let graph = makeLayer(geometry: geometry(origin: SIMD3(32, 32, 0), size: CGSize(width: 8, height: 8)), passes: [])
        let renderPass = WPERenderPass(id: "solid", phase: .material, shader: "solidlayer", source: .asset("white"), target: .scene,
                                       textures: [:], binds: [:], constants: [:], combos: [:], blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: [.init(pass: renderPass,
                                                                                                  shader: nil, textureBindings: [:], comboValues: [:], uniformValues: ["g_Color": .vector([1, 0, 0, 1])])])])
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.storageMode = .shared
        let white = try #require(device.makeTexture(descriptor: desc))
        var bytes: [UInt8] = [255, 255, 255, 255]
        bytes.withUnsafeBytes { white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 64, height: 64, auto: false), sceneCamera: .defaultCamera,
                                            sceneMotion: .init(origin: SIMD3(-8, 4, 0), zoom: 2))
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 64, height: 64), textures: ["white": white], cameraUniforms: camera)
        #expect(try red(output, at: SIMD2(48, 40), executor: executor) > 200)
        #expect(try red(output, at: SIMD2(32, 32), executor: executor) < 20)
    }

    private func red(_ texture: MTLTexture, at position: SIMD2<Int>, executor: WPEMetalRenderExecutor) throws -> UInt8 {
        let buffer = try #require(executor.device.makeBuffer(length: 256, options: .storageModeShared))
        let command = try #require(executor.commandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: position.x, y: position.y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        return buffer.contents().load(as: UInt8.self)
    }

    private func geometry(origin: SIMD3<Double>, size: CGSize? = nil) -> WPERenderLayerGeometry {
        .init(origin: origin, scale: SIMD3(repeating: 1), angles: .zero, alignment: .center, size: size,
              alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
    }

    private func makeLayer(geometry: WPERenderLayerGeometry, passes: [WPERenderPass]) -> WPERenderLayer {
        .init(objectID: "layer", objectName: "layer", imagePath: "image", materialPath: nil, geometry: geometry,
              compositeA: "a", compositeB: "b", localFBOs: [], passes: passes)
    }

    private func pass(_ id: String, target: WPERenderTarget) -> WPERenderPass {
        .init(id: id, phase: .material, shader: "image", source: .asset("white"), target: target,
              textures: [:], binds: [:], constants: [:], combos: [:], blending: "normal", cullMode: "nocull",
              depthTest: "disabled", depthWrite: "disabled")
    }

    private func makeCamera() -> WPEMetalCameraUniforms {
        .init(orthogonalProjection: .init(width: 3840, height: 2160, auto: false), sceneCamera: .defaultCamera,
              perspectiveOverrideFOVDegrees: 90, perspectiveObjectIDs: ["model"])
    }
}
#endif
