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
    @Test("Composite camera angles reproduce captured Windows XY and orthographic cursor coordinates")
    func capturedCompositeOrientation() throws {
        let motion = WPESceneCameraMotionSample(origin: SIMD3(40, 20, 10), zoom: 1, angles: SIMD3(0.2, 0.3, 0.4))
        let matrix = WPECameraMotionProjection.canvasMatrix(motion: motion, size: CGSize(width: 256, height: 128))
        let projected = matrix * SIMD4<Double>(0, 0, 0, 1)
        #expect(abs(projected.x + 0.2440814971923828) < 0.000001)
        #expect(abs(projected.y + 0.8437523245811462) < 0.000001)
        let cursor = try #require(WPECameraMotionProjection.cursor(pointer: SIMD2(2234.0 / 256, -133.0 / 128), size: SIMD2(256, 128), motion: motion))
        #expect(abs(cursor.x - 1231.987476348877) < 0.003)
        #expect(abs(cursor.y - 1233.077049255371) < 0.003)
        #expect(cursor.z == 0)
        let legacy = WPECameraMotionProjection.canvasMatrix(motion: .init(origin: SIMD3(40, 20, 0), zoom: 1), size: CGSize(width: 256, height: 128))
        let correction = WPECameraMotionProjection.correction(motion: motion, size: CGSize(width: 256, height: 128))
        let native = correction * SIMD4<Float>(legacy * SIMD4<Double>(0, 0, 0, 1))
        #expect(abs(Double(native.x) - projected.x) < 0.000001)
        #expect(abs(Double(native.y) - projected.y) < 0.000001)
    }

    @Test("Sprite camera orientation matches the real GS's normalized projected UP axis")
    func capturedSpriteOrientation() {
        let rotation = WPECameraMotionProjection.spriteRotation(modelAngle: 0, cameraAngles: SIMD3(0.2, 0.3, 0.4))
        let center = SIMD2<Float>(-0.2440814971923828, -0.8437523245811462)
        let local = SIMD2<Float>(-2, 2)
        let corner = SIMD2(rotation.x * local.x - rotation.y * local.y, rotation.y * local.x + rotation.x * local.y)
        let point = center + corner / SIMD2<Float>(128, 64)
        #expect(abs(point.x + 0.2527519166469574) < 0.000001)
        #expect(abs(point.y + 0.8031023740768433) < 0.000001)
    }

    @Test("Camera origin consumes current bound script properties without losing the authored seed",
          arguments: [SIMD2<Double>(0, 0), SIMD2<Double>(-0.25, 0.125)])
    func scriptResolvedCameraOrigin(properties: SIMD2<Double>) throws {
        let seed = SIMD3<Double>(2434.38477, 725.25116, 500)
        let script = """
        export var scriptProperties = createScriptProperties()
            .addSlider({name: 'x', value: 0.5, min: -1, max: 1})
            .addSlider({name: 'y', value: 0.5, min: -1, max: 1}).finish();
        export function update(value) {
            value.x = scriptProperties.x * engine.canvasSize.x;
            value.y = scriptProperties.y * engine.canvasSize.y;
            return value;
        }
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160]],
            "objects": [["id": 1_297_271, "camera": "default", "zoom": 1,
                         "origin": ["value": "2434.38477 725.25116 500", "script": script,
                                    "scriptproperties": ["x": ["user": "cameraX", "value": 0.5],
                                                         "y": ["user": "cameraY", "value": 0.5]]]]],
        ])
        let document = try WPESceneDocumentParser.parse(data: data, userValues: ["cameraX": .number(properties.x), "cameraY": .number(properties.y)])
        let expected = SIMD3<Double>(properties.x * 3840, properties.y * 2160, 500)
        #expect(document.camera.eye == expected)
        #expect(document.camera.center == expected + SIMD3(0, 0, -1))
        let motion = try #require(document.cameraMotion)
        #expect(motion.origin == expected)
        #expect(motion.seed.origin == expected)
        #expect(document.authoredCameraObjects.first?.origin == .value(seed))
        #expect(document.authoredCameraObjects.first?.sourceJSON["origin"]?["script"] == .string(script))

        // An image centred on that camera must still fill the scene. This catches
        // the black rectangle even when compilation and frame production succeed.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let layer = makeLayer(geometry: geometry(origin: SIMD3(1920 + expected.x, 1080 + expected.y, 0),
                                                 size: CGSize(width: 3840, height: 2160)), passes: [])
        let draw = WPERenderPass(id: "background", phase: .material, shader: "solidlayer", source: .asset("white"), target: .scene,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [.init(pass: draw, shader: nil,
                                                                                                  textureBindings: [:], comboValues: [:], uniformValues: ["g_Color": .vector([1, 0, 0, 1])])])])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection,
                                            sceneCamera: document.camera, sceneMotion: motion.seed)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let white = try #require(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [255, 255, 255, 255]
        bytes.withUnsafeBytes { white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 64, height: 36), textures: ["white": white], cameraUniforms: camera)
        for point in [SIMD2(2, 2), SIMD2(61, 2), SIMD2(2, 33), SIMD2(61, 33)] {
            #expect(try red(output, at: point, executor: executor) > 200)
        }
    }

    @Test("A dynamic camera origin script keeps its authored seed during static parsing")
    func dynamicCameraOriginRemainsUnresolved() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160]],
            "objects": [["id": 2, "camera": "default", "origin": ["value": "12 34 500",
                                                                  "script": "export function update(value) { value.x += engine.frametime; return value; }"]]],
        ])
        let document = try WPESceneDocumentParser.parse(data: data)
        #expect(document.camera.eye == SIMD3<Double>(12, 34, 500))
        #expect(document.cameraMotion?.origin == SIMD3<Double>(12, 34, 500))
    }

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
        let sceneURL = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects.append(["id": "cam", "camera": "default", "zoom": 1,
                        "origin": ["value": "0 0 0", "animation": [
                            "c0": [["frame": 0, "value": 0], ["frame": 10, "value": 40]],
                            "c1": [["frame": 0, "value": 0], ["frame": 10, "value": 20]],
                            "c2": [["frame": 0, "value": 0], ["frame": 10, "value": 0]],
                            "options": ["fps": 10, "length": 10, "mode": "single"],
                        ]]])
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.load()
        #expect(stack.renderer.cameraMotionPlayback?.definition.objectID == "cam")
        #expect(stack.renderer.dynamicOriginAnimations["cam"] == nil)
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

    @Test("A missing camera path asset leaves the static camera and the scene still loads")
    @MainActor
    func missingCameraPathAssetDoesNotFailLoad() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let sceneURL = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var camera = scene["camera"] as? [String: Any] ?? [:]
        camera["paths"] = ["camera/missing.json"]
        scene["camera"] = camera
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.load()
        #expect(stack.renderer.cameraPathPlayback == nil)
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

    @Test("The real native quad consumes the captured XYZ camera projection")
    func gpuCompositeCameraOrientation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let graph = makeLayer(geometry: geometry(origin: SIMD3(128, 64, 0), size: CGSize(width: 48, height: 96)), passes: [])
        let draw = WPERenderPass(id: "solid", phase: .material, shader: "solidlayer", source: .asset("white"), target: .scene,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: [.init(pass: draw, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: ["g_Color": .vector([1, 0, 0, 1])])])])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let white = try #require(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [255, 255, 255, 255]
        bytes.withUnsafeBytes { white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 256, height: 128, auto: false), sceneCamera: .defaultCamera,
                                            sceneMotion: .init(origin: SIMD3(40, 20, 10), zoom: 1, angles: SIMD3(0.2, 0.3, 0.4)))
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 256, height: 128), textures: ["white": white], cameraUniforms: camera)
        // Captured Windows post-VS centre is (-.244081497, -.843752325).
        #expect(try red(output, at: SIMD2(97, 118), executor: executor) == 255)
        #expect(try red(output, at: SIMD2(128, 64), executor: executor) == 0)
        let identity = makeLayer(geometry: .identity, passes: [])
        #expect(executor.usesObjectQuadGeometry(for: draw, layer: identity, cameraUniforms: camera))
        #expect(!executor.usesObjectQuadGeometry(for: draw, layer: identity))
    }

    @Test("Static camera getter returns detached transforms and setters publish only accepted callbacks")
    func cameraScriptTransactions() throws {
        let shared = WPESharedScriptState()
        shared.seedStaticCamera(.init(center: SIMD3(0, 0, -1), eye: .zero, up: SIMD3(0, 1, 0), nearZ: 0.01, farZ: 10000, fov: 50))
        let instance = try WPELayerScriptInstance(script: """
        export function update() {
            var camera = thisScene.getCameraTransforms();
            camera.eye = new Vec3(80,20,10);
            camera.center = new Vec3(80,20,9);
            camera.zoom = 2;
            thisScene.setCameraTransforms(camera);
            if (thisScene.getCameraTransforms().eye.x !== 80) throw new Error('read own write');
            camera.eye.x = 999;
        }
        """, shared: shared)
        #expect(!shared.staticCameraSnapshot().hasOverride)
        _ = instance.tick()
        #expect(shared.staticCameraSnapshot().transforms.eye == SIMD3<Double>(80, 20, 10))
        #expect(shared.staticCameraSnapshot().transforms.zoom == 2)
        let before = shared.staticCameraSnapshot()
        let failing = try WPELayerScriptInstance(script: """
        export function update() {
            var camera = thisScene.getCameraTransforms();
            camera.eye.x = 120;
            camera.center.x = 120;
            thisScene.setCameraTransforms(camera);
            throw new Error('rollback');
        }
        """, shared: shared)
        _ = failing.tick()
        #expect(shared.staticCameraSnapshot() == before)
        let detached = try WPELayerScriptInstance(script: "export function update(){thisScene.getCameraTransforms().eye.x=12345;}", shared: shared)
        _ = detached.tick()
        #expect(shared.staticCameraSnapshot() == before)
    }

    @Test("Perspective mutation rejects the callback rather than storing an unapplied camera")
    func perspectiveCameraMutationIsNotAdmitted() throws {
        let shared = WPESharedScriptState()
        shared.seedStaticCamera(.defaultCamera, allowsMutation: false)
        let before = shared.staticCameraSnapshot()
        let instance = try WPELayerScriptInstance(script: """
        export function update() {
            var camera = thisScene.getCameraTransforms();
            camera.eye.x = 80;
            camera.center.x = 80;
            thisScene.setCameraTransforms(camera);
            shared.afterUnsupportedCameraSetter = true;
        }
        """, shared: shared)
        _ = instance.tick()
        #expect(shared.get("afterUnsupportedCameraSetter") == nil)
        #expect(shared.staticCameraSnapshot() == before)
    }

    @Test("Static up and forward map to the measured 2D camera basis")
    func cameraTransformsOrientation() {
        let roll = WPEScriptCameraTransforms(up: SIMD3(-sin(0.2), cos(0.2), 0)).motion
        #expect(abs(roll.angles.z - 0.2) < 1e-12)
        let yaw = WPEScriptCameraTransforms(center: SIMD3(sin(0.3), 0, -cos(0.3))).motion
        #expect(abs(yaw.angles.y + 0.3) < 1e-12)
        let matrix = WPECameraMotionProjection.canvasMatrix(motion: yaw, size: CGSize(width: 256, height: 128))
        #expect(abs(matrix.columns.3.x + 0.04466348886489868) < 1e-6)
        #expect(abs(matrix.columns.0.x / 128 - 0.007463566493242979) < 1e-7)
    }

    @Test("Root queue clamps at an endpoint, switches in order, excludes pause time and resets on reload")
    func rootPathQueueClock() throws {
        let data = Data(#"{"paths":[{"duration":2,"name":"first","transforms":[{"timestamp":0,"eye":"0 0 0","center":"0 0 -1","up":"0 1 0","zoom":1},{"timestamp":1,"eye":"80 0 0","center":"80 0 -1","up":"0 1 0","zoom":2}]},{"duration":2,"name":"second","transforms":[{"timestamp":0,"eye":"160 0 0","center":"160 0 -1","up":"0 1 0","zoom":1},{"timestamp":1,"eye":"240 0 0","center":"240 0 -1","up":"0 1 0","zoom":1}]}]}"#.utf8)
        let paths = try WPESceneCameraPath.parse(data: data)
        var playback = try #require(WPECameraPathPlayback(paths: paths))
        #expect(playback.sample(sceneTime: 100)?.origin.x == 0)
        #expect(playback.sample(sceneTime: 100.5)?.origin.x == 0)
        #expect(playback.sample(sceneTime: 101)?.origin.x == 40)
        #expect(playback.sample(sceneTime: 101.5)?.origin.x == 80)
        #expect(playback.index == 1)
        #expect(playback.sample(sceneTime: 102)?.origin.x == 160)
        playback.suspend()
        #expect(playback.sample(sceneTime: 900)?.origin.x == 200)
        #expect(playback.sample(sceneTime: 900.5)?.origin.x == 200)
        let reset = try #require(WPECameraPathPlayback(paths: paths))
        #expect(reset.index == 0)
        #expect(reset.elapsed == 0)
    }

    @Test("Path rotation follows independent captured zoom and post-VS basis values")
    func capturedPathRotation() {
        let cases: [(Double, Double, Double, Double, Double)] = [
            (0.5934039261390014, 0.008670948445796967, -0.006725611165165901, 0.004501167219132185, 0.023212401196360588),
            (0.8047218903164588, 0.007088508456945419, -0.005894737783819437, 0.005413175094872713, 0.026037689298391342),
        ]
        for (f, xx, xy, yx, yy) in cases {
            let pose = WPEScriptCameraTransforms(center: SIMD3(sin(1.2) * f, 0, -1 + (1 - cos(1.2)) * f),
                                                 up: SIMD3(-sin(0.8) * f, 1 + (cos(0.8) - 1) * f, 0), zoom: 1 + f)
            let matrix = WPECameraMotionProjection.canvasMatrix(motion: pose.motion, size: CGSize(width: 256, height: 128))
            #expect(abs(matrix.columns.0.x / 128 - xx) < 1e-7)
            #expect(abs(matrix.columns.0.y / 128 - xy) < 1e-7)
            #expect(abs(matrix.columns.1.x / 64 - yx) < 1e-7)
            #expect(abs(matrix.columns.1.y / 64 - yy) < 1e-7)
        }
    }

    @Test("Actually consumed orthographic eye, basis and VP match Windows rather than declaration garbage")
    func consumedOrthographicGlobals() throws {
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 256, height: 128, auto: false), sceneCamera: .defaultCamera,
                                            sceneMotion: .init(origin: SIMD3(40, 20, 10), zoom: 1, angles: SIMD3(0.2, 0.3, 0.4)))
        let values = camera.uniformValues
        #expect(values["g_EyePosition"]?.vectorValue == [168, 84, 2000])
        let right = try #require(values["g_ViewRight"]?.vectorValue)
        let up = try #require(values["g_ViewUp"]?.vectorValue)
        let forward = try #require(values["g_ViewForward"]?.vectorValue)
        for (actual, expected) in zip(right, [0.8799233436584473, 0.3720255196094513, -0.2955196499824524]) {
            #expect(abs(actual - expected) < 1e-6)
        }
        for (actual, expected) in zip(up, [-0.3275796175003052, 0.9255641102790833, 0.18979626893997192]) {
            #expect(abs(actual - expected) < 1e-6)
        }
        for (actual, expected) in zip(forward, [-0.3441314399242401, 0.07019995898008347, -0.9362934827804565]) {
            #expect(abs(actual - expected) < 1e-6)
        }
        let matrix = try #require(values["g_ViewProjectionMatrix"]?.vectorValue)
        #expect(abs(matrix[12] + 1.3100175857543945) < 1e-6)
        #expect(abs(matrix[13] + 1.1141571998596191) < 1e-6)
        #expect(abs(matrix[14] - 0.49456894397735596) < 1e-6)
    }

    @Test("Camera commands reject a degenerate or unrepresentable GPU projection")
    func cameraProjectionValidation() {
        #expect(!WPEScriptCameraTransforms(eye: SIMD3(1e99, 0, 0)).isValid)
        #expect(!WPEScriptCameraTransforms(center: .zero).isValid)
        #expect(!WPEScriptCameraTransforms(up: SIMD3(0, 0, 1)).isValid)
        #expect(!WPEScriptCameraTransforms(zoom: 1e-99).isValid)
        #expect(!WPEScriptCameraTransforms(zoom: -1).isValid)
        #expect(WPEScriptCameraTransforms(eye: SIMD3(40, 20, 10), center: SIMD3(40, 20, 9), zoom: 2).isValid)
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
