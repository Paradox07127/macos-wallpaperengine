#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@MainActor
@Suite("SceneScript renderer wiring", .serialized)
struct WPESceneScriptWiringTests {
    @Test("Orthographic hover hit-testing follows the camera zoom the quad is drawn with")
    func hoverFollowsCameraZoom() throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        let size = CGSize(width: 64, height: 64)
        renderer.sceneRenderSize = size
        renderer.cameraUniforms = WPEMetalCameraUniforms(
            orthogonalProjection: .init(width: 64, height: 64, auto: false), sceneCamera: .defaultCamera,
            sceneMotion: .init(origin: .zero, zoom: 2)
        )
        renderer.layerScriptInstances["probe"] = try WPELayerScriptInstance(
            script: "export function update(value) { return value; }",
            shared: WPESharedScriptState(layers: []), ownLayerName: "probe", ownObjectID: "probe",
            governor: WPESceneScriptExecutionGovernor(limit: 1)
        )
        // Authored 8 px right of centre, 4x4; drawn 16 px right of centre, 8x8.
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3(40, 32, 0), scale: SIMD3(repeating: 1), angles: .zero, alignment: .center,
            size: CGSize(width: 4, height: 4), alpha: 1, color: SIMD3(repeating: 1), brightness: 1
        )
        let layer = WPERenderLayer(objectID: "probe", objectName: "probe", imagePath: "image", materialPath: nil,
                                   geometry: geometry, compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [])])
        func hovered(_ x: Double) -> Bool {
            renderer.layerHoverStates.removeAll()
            renderer.dispatchLayerHoverEvents(
                pointer: SIMD2(x / 64, 0.5), pipeline: pipeline, pointerFrame: .neutral, deliver: { _, _, _ in }
            )
            return renderer.layerHoverStates["probe"] == true
        }
        #expect(hovered(48))
        #expect(!hovered(40))
    }

    @Test("A commit-time script failure rebuilds the camera from the stable script transforms")
    func commitFailureRollsCameraBack() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        try await renderer.load()
        renderer.cameraMotionPlayback = WPECameraMotionPlayback(
            definition: .init(objectID: "camera", origin: .zero, zoom: 3)
        )
        var stable = WPEMetalSceneRenderer.LiveScriptTransforms()
        stable.scales[WPECameraMotionPlayback.zoomScriptKey] = SIMD3(repeating: 1)
        renderer.lastStableScriptTransforms = stable
        let publication = renderer.captureSceneScriptFramePublication()
        let context = renderer.sampleFrameContext(inputs: renderer.makeFrameInputs())
        let sampled = renderer.cameraUniforms.sceneMotion
        renderer.cameraUniforms = renderer.baseCameraUniforms.applyingSceneMotion(.init(origin: .zero, zoom: 2))
        _ = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
            .failClosed(.executionTimedOut(operation: .tick))
        let submission = try renderer.executor.beginFrameSubmission()
        defer { submission.seal() }
        _ = try renderer.finishSceneScriptFrame(
            speculativeFrame: #require(renderer.outputTexture),
            failureBeforeFrame: nil,
            publicationBeforeFrame: publication,
            basePipeline: #require(renderer.renderPipeline),
            uniforms: context.uniforms,
            authoredTransforms: .init(),
            sampledCameraMotion: sampled,
            parallaxFrame: context.parallaxFrame,
            frameSubmission: submission,
            videoCommandsOutcome: false
        )
        #expect(renderer.cameraUniforms.sceneMotion.zoom == 1)
    }

    @Test("A layer alpha script's thisLayer is its own object when another layer shares the name")
    func alphaScriptOwnsItsObject() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["name"] = "Dup"
        objects[0]["origin"] = "10 10 0"
        var second = objects[0]
        second["id"] = "second"
        second["origin"] = "40 40 0"
        second["alpha"] = ["value": 1, "script": """
        export function init() { shared.ownX = thisLayer.origin.x; }
        export function update(value) { return value; }
        """]
        objects.append(second)
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        try await renderer.load()
        #expect(renderer.layerAlphaScriptInstances["second"] != nil)
        #expect(renderer.sharedScriptValueForTesting("ownX") as? Double == 40)
    }

    @Test("Text script writes addressed by object identity reach the duplicate-named layer")
    func textScriptIdentityKeysResolve() throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        let shared = WPESharedScriptState(layers: [
            .init(id: "A", name: "dup", size: .zero, origin: .zero, index: 0, parentName: nil),
            .init(id: "B", name: "dup", size: .zero, origin: .zero, index: 1, parentName: nil),
            .init(id: "T", name: "label", size: .zero, origin: .zero, index: 2, parentName: nil),
        ])
        renderer.sceneScriptSharedState = shared
        renderer.layerObjectIDByName["dup"] = "B"
        let instance = try WPELayerScriptInstance(
            script: "export function init() { thisScene.getLayer(0).visible = false; }",
            shared: shared, ownLayerName: "label", ownObjectID: "T",
            governor: WPESceneScriptExecutionGovernor(limit: 1)
        )
        renderer.applyTextScriptOutput(instance.initialOutput, ownObjectID: "T")
        #expect(renderer.liveLayerVisibility["A"] == false)
        #expect(renderer.liveLayerVisibility["B"] == nil)
    }

    @Test("Load-time rate/loop-only script control still starts playback; pause keeps it stopped",
          arguments: [true, false])
    func loadScriptLoopOnlyStartsPlayback(loopOnly: Bool) async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let key = "materials/clip.tex"
        let url = fixture.root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.videoTex().write(to: url)
        let renderer = try makeRenderer(fixture)
        let actor = WPEDisplayRenderActor(backing: .main)
        await actor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        renderer.oracleVideoDecoderAdmission = WPEVideoDecoderAdmission(limit: 4)
        // Load creates the source before init scripts and before the profile push.
        try await actor.loadVideoSourceForWiringTest(handoff: WPERendererHandoff(renderer: renderer), key: key)
        let source = try #require(renderer.dynamicTextureSources[key] as? WPEVideoTextureSource)
        renderer.layerVideoSourceKey["video"] = key
        let token = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
        renderer.beginSceneScriptVideoCommands()
        renderer.sceneScriptVideoCommandBuffer.enqueue(
            loopOnly ? [.setLoop(false)] : [.setLoop(false), .pause], objectID: "video"
        )
        var scriptsAreBaked = false
        try renderer.finishSceneScriptLoadVideoCommands(for: token, scriptsAreBaked: &scriptsAreBaked)
        source.applyPerformanceProfile(renderer.currentProfile)
        let snapshot = try #require(source.scriptPlaybackSnapshot)
        await actor.teardownRenderer()
        #expect(await actor.shutdown())
        #expect(snapshot.loop == false)
        #expect(snapshot.isPlaying == loopOnly)
    }

    private func makeRenderer(_ fixture: MetalSceneFixture) throws -> WPEMetalSceneRenderer {
        try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
    }

    /// A video `.tex` whose MP4 payload is only an `ftyp` box: enough for a live player, no frames needed.
    private static func videoTex() -> Data {
        var data = Data()
        func magic(_ value: String) {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        func int32(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let mp4 = Data("\u{0}\u{0}\u{0}\u{18}ftypmp42\u{0}\u{0}\u{0}\u{0}mp42isom".utf8)
        magic("TEXV0005")
        magic("TEXI0001")
        for value in [Int32(WPETexFormat.rgba8888.rawValue), 0, 4, 4, 4, 4, 0] {
            int32(value)
        }
        magic("TEXB0003")
        for value: Int32 in [1, -1, 1, 4, 4, 0, Int32(mp4.count), Int32(mp4.count)] {
            int32(value)
        }
        data.append(mp4)
        return data
    }
}

private extension WPEDisplayRenderActor {
    func loadVideoSourceForWiringTest(handoff: WPERendererHandoff, key: String) async throws {
        try await handoff.renderer.loadDynamicTextureOnActor(
            path: key, layerName: key, publicationAllowed: { true }, on: self
        )
    }
}
#endif
