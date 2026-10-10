#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import os
import Testing

@MainActor
@Suite("SceneScript renderer wiring", .serialized)
struct WPESceneScriptWiringTests {
    @Test("Renderer frame inputs retain above-one stereo audio before pooling")
    func rendererAudioPreservesAboveOne() async throws {
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        try await renderer.load()
        var left = [Float](repeating: 0, count: AudioSpectrumFrame.binCount)
        var right = left
        left[0] = 2; right[1] = 1.5
        let wasCapturing = SystemAudioCaptureManager.isCapturing
        SystemAudioCaptureManager.broker.attachAnalyzer(ClockRateSpectrum(
            frame: AudioSpectrumFrame(validatedLeft: left, validatedRight: right, timestampNanos: 1)
        ))
        SystemAudioCaptureManager.setCapturingForTesting(true)
        defer {
            SystemAudioCaptureManager.setCapturingForTesting(wasCapturing)
            SystemAudioCaptureManager.broker.attachAnalyzer(nil)
            SystemAudioCaptureManager.broker.resetToSilence()
        }
        let uniforms = renderer.sampleFrameContext(inputs: renderer.makeFrameInputs()).uniforms
        #expect(uniforms.audioSpectrumLeft[0] == 2)
        #expect(uniforms.audioSpectrumRight[1] == 1.5)
        #expect(uniforms.uniformValues["g_AudioSpectrum16Left"] == .vector([2] + [Double](repeating: 0, count: 15)))
        #expect(uniforms.audioSpectrum16Average[0] == 1)
        #expect(SystemAudioCaptureManager.broker.snapshot().left[0] == 1)
    }

    @Test("A particle rate envelope executes init and requests audio without emitter audio fields")
    func particleRateEnvelopeBootstraps() async throws {
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[1]["instanceoverride"] = ["alpha": 0.7, "rate": ["value": 0.1, "script": """
        const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        export function init(value) { shared.rateSeed = value; return value * 2; }
        """]]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        try await renderer.load()
        #expect(renderer.sceneSupportsAudioProcessing)
        #expect(renderer.sceneScriptSharedState?.get("rateSeed") as? Double == 0.1)
        let system = try #require(renderer.particleSystems.first)
        #expect(abs(system.instanceValues.rate - 0.2) < 0.000001)
        #expect(system.instanceValues.alpha == 0.7)
    }

    @Test("Clock pulse rate consumes live low-frequency audio through frame commits",
          arguments: [Float(0), Float(0.125), Float(1)])
    func clockPulseRateFollowsAudio(level: Float) async throws {
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        // The 3811154012 rate template: declared defaults differ from its bound overrides.
        let script = """
        export var scriptProperties = createScriptProperties()
            .addSlider({name:'frequency', value:0}).addSlider({name:'smoothing', value:15})
            .addSlider({name:'minvalue', value:0.8}).addSlider({name:'maxvalue', value:1.2}).finish();
        const audioBuffer = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        let smoothValue = 0; let initialValue;
        export function init(value) { initialValue = (typeof value === 'number') ? value : value.x; }
        export function update() {
            const valueDelta = scriptProperties.maxvalue - scriptProperties.minvalue;
            const audioDelta = audioBuffer.average[scriptProperties.frequency] - smoothValue;
            smoothValue += audioDelta * Math.min(1.0, engine.frametime * scriptProperties.smoothing);
            smoothValue = Math.min(1.0, smoothValue);
            if (shared.throwRate) { thisObject.instance.rate = 99; throw new Error('rate rollback'); }
            return initialValue * (smoothValue * valueDelta + scriptProperties.minvalue);
        }
        """
        objects[1]["instanceoverride"] = ["alpha": 0.7, "rate": [
            "value": 0.1, "script": script,
            "scriptproperties": ["frequency": 0, "smoothing": 15, "minvalue": 1, "maxvalue": 20],
        ]]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        let now = OSAllocatedUnfairLock(initialState: 0.0)
        renderer.frameClock = WPEMetalFrameClock(loadTime: 0, currentMediaTime: { now.withLock { $0 } })
        try await renderer.load()
        let system = try #require(renderer.particleSystems.first)
        #expect(renderer.particleRateScriptInstances.count == 1)
        let capturingBefore = SystemAudioCaptureManager.isCapturing
        let bins = [Float](repeating: level, count: AudioSpectrumFrame.binCount)
        SystemAudioCaptureManager.broker.attachAnalyzer(ClockRateSpectrum(
            frame: AudioSpectrumFrame(left: bins, right: bins, timestampNanos: 1)
        ))
        SystemAudioCaptureManager.setCapturingForTesting(true)
        defer {
            SystemAudioCaptureManager.setCapturingForTesting(capturingBefore)
            SystemAudioCaptureManager.broker.attachAnalyzer(nil)
            SystemAudioCaptureManager.broker.resetToSilence()
        }
        for frame in 1 ... 40 {
            now.withLock { $0 = Double(frame) / 30 }
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            try await Task.sleep(for: .milliseconds(5))
        }
        let expected = 0.1 * (1 + 19 * Double(level))
        #expect(abs(system.instanceValues.rate - expected) < 0.00001)
        #expect(system.instanceValues.alpha == 0.7)
        // A thrown callback discards its instance mutation and retains the last good rate.
        renderer.sceneScriptSharedState?.set("throwRate", true)
        for frame in 41 ... 44 {
            now.withLock { $0 = Double(frame) / 30 }
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(abs(system.instanceValues.rate - expected) < 0.00001)
        renderer.cleanup()
        #expect(renderer.particleRateScriptInstances.isEmpty)
    }

    @Test("Alpha families retain their own entry side effects without applying own alpha twice",
          arguments: ["layer", "hidden-layer", "text", "particle"])
    func alphaEntrySideEffects(family: String) async throws {
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["name"] = "target"
        objects.append([
            "id": "owner", "name": "owner", "image": "models/util/solidlayer.json",
            "origin": "32 32 0", "alpha": 1,
        ])
        for stage in 1 ... 7 {
            var target = objects[0]
            target["id"] = "target\(stage)"
            target["name"] = "target\(stage)"
            objects.append(target)
        }
        let script = """
        function write(stage, command) {
            shared['stage' + stage] = (shared['stage' + stage] || 0) + 1;
            let target = thisScene.getLayer('target' + stage);
            target.alpha = stage / 10; target.scale = new Vec3(stage + 10, stage + 10, 1);
            target.getVideoTexture()[command]();
        }
        write(1, 'play');
        export function init(value) { write(2, 'pause'); return 0.25; }
        export function applyUserProperties(p) { write(p.stage || 3, 'stop'); }
        export function update(value) { if (shared.runAlphaTick) { shared.runAlphaTick = false; write(4, 'play'); } return value; }
        export function applyGeneralSettings() { if (shared.runAlphaGeneral) { write(5, 'pause'); } }
        export function resizeScreen() { write(6, 'stop'); }
        """
        let alpha: [String: Any] = ["value": 1, "script": script]
        let ownerID: String
        switch family {
        case "text":
            ownerID = "label"
            objects.append([
                "id": ownerID, "name": ownerID, "text": "seed", "font": "Arial",
                "pointsize": 12, "origin": "32 32 0", "alpha": alpha,
            ])
        case "particle":
            ownerID = "pfx"
            objects[1]["instanceoverride"] = ["alpha": alpha]
        default:
            ownerID = "owner"
            objects[2]["alpha"] = alpha
            if family == "hidden-layer" {
                objects[2]["visible"] = false
            }
        }
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        try JSONSerialization.data(withJSONObject: ["general": ["properties": ["trigger": ["type": "bool", "value": true, "text": "Trigger"]]]])
            .write(to: fixture.root.appendingPathComponent("project.json"))
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        try await renderer.load()
        let store = try #require(renderer.sceneScriptSharedState)
        let instance: WPELayerScriptInstance
        let publish: (WPELayerScriptOutput) -> Void
        switch family {
        case "text":
            instance = try #require(renderer.textAlphaScriptInstances[ownerID])
            publish = { renderer.applyTextAlphaScriptOutput($0, ownObjectID: ownerID) }
        case "particle":
            instance = try #require(renderer.particleAlphaScriptInstances[ownerID])
            publish = { renderer.applyParticleAlphaScriptOutput($0, ownObjectID: ownerID) }
        default:
            instance = try #require(renderer.layerAlphaScriptInstances[ownerID])
            publish = { renderer.applyLayerAlphaScriptOutput($0, ownObjectID: ownerID) }
        }
        func check(stage: Int) {
            #expect(store.get("stage\(stage)") as? Double == 1)
            #expect(renderer.liveLayerAlpha["target\(stage)"] == Double(stage) / 10)
            #expect(renderer.layerTransformMutationJournal.entries[
                .init(objectID: "target\(stage)", generation: renderer.loadGeneration)
            ]?.scale == SIMD3(Double(stage + 10), Double(stage + 10), 1))
            // Load seeds image objects (text included, via its synthetic layer) with authored `visible`; alpha scripts must leave it.
            #expect(renderer.liveLayerVisibility[ownerID] == ["layer": true, "hidden-layer": false, "text": true][family])
            switch family {
            case "text":
                #expect(renderer.liveTextAlpha[ownerID] == 0.25)
                #expect(renderer.liveLayerAlpha[ownerID] == nil)
                #expect(renderer.liveTextVisibility[ownerID] == true)
            case "particle":
                #expect(renderer.liveParticleInstanceAlpha[ownerID] == 0.25)
                #expect(renderer.liveLayerAlpha[ownerID] == nil)
            default:
                #expect(renderer.liveLayerAlpha[ownerID] == 0.25)
            }
        }
        check(stage: 3)
        check(stage: 1)
        check(stage: 2)
        #expect(instance.initialOutput.videoCalls.map(\.command) == [.play, .pause])

        renderer.beginSceneScriptVideoCommands()
        try publish(#require(renderer.applyScriptUserProperties(instance, ["stage": .number(7)])))
        check(stage: 7)
        #expect(renderer.sceneScriptVideoCommandBuffer.pending.map(\.command) == [.stop])
        renderer.discardSceneScriptVideoCommands()

        renderer.beginSceneScriptVideoCommands()
        store.set("runAlphaTick", true)
        try publish(#require(instance.tick(runtimeSeconds: 1, pointerFrame: .neutral)))
        check(stage: 4)
        #expect(renderer.sceneScriptVideoCommandBuffer.pending.map(\.command) == [.play])
        renderer.consumeSceneScriptLayerOutputs()
        #expect(renderer.sceneScriptVideoCommandBuffer.pending.map(\.command) == [.play])
        renderer.discardSceneScriptVideoCommands()

        renderer.beginSceneScriptVideoCommands()
        store.set("runAlphaGeneral", true)
        renderer.setSceneScriptLanguage(renderer.sceneScriptGeneralSettings.language == "de-de" ? "en-us" : "de-de")
        check(stage: 5)
        #expect(renderer.sceneScriptVideoCommandBuffer.pending.map(\.command) == [.pause])
        renderer.discardSceneScriptVideoCommands()

        renderer.beginSceneScriptVideoCommands()
        // Non-square, so it never equals the 64x64-point frame's drawable at any backing scale (an unchanged size skips resizeScreen).
        renderer.dispatchSceneScriptResizeScreen(SIMD2(160, 90))
        check(stage: 6)
        #expect(renderer.sceneScriptVideoCommandBuffer.pending.map(\.command) == [.stop])
        renderer.discardSceneScriptVideoCommands()
    }

    @Test("Actual scene bootstrap prepares later and same-owner modules before init and delivers initial properties once")
    func sceneBootstrapModuleBarrierAndProperties() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        func script(module: String = "", initBody: String = "", properties: String = "") -> String {
            """
            shared.modules = (shared.modules || 0) + 1;
            \(module)
            export function init(value) { shared.inits = (shared.inits || 0) + 1; \(initBody); return value; }
            export function applyUserProperties(p) { shared.properties = (shared.properties || 0) + 1; \(properties); }
            export function update(value) { return value; }
            """
        }
        objects[0]["name"] = "consumer"
        objects[0]["origin"] = ["value": "787 -31 0", "script": script(initBody: """
        shared.sawLaterModule = typeof shared.copyVec3 === 'function';
        shared.laterInitWasAbsent = shared.laterInitialized !== true;
        shared.sawSameOwnerModule = shared.sameOwnerModule === true;
        let initial = shared.copyVec3(value); shared.originSeed = initial.x + ':' + initial.y;
        shared.playTrack = function() { shared.playCalls = (shared.playCalls || 0) + 1; };
        """)]
        objects[0]["scale"] = ["value": "0.35 0.35 1", "script": script(initBody: """
        let initial = shared.copyVec3(value); shared.scaleSeed = initial.x;
        """)]
        objects[0]["color"] = ["value": "1 1 1", "script": script()]
        objects[0]["visible"] = ["value": true, "script": script(module: "shared.sameOwnerModule = true;", properties: "shared.playTrack();")]
        var publisher = objects[0]
        publisher["id"] = "publisher"
        publisher["name"] = "publisher"
        publisher["origin"] = "32 32 0"
        publisher["scale"] = "1 1 1"
        publisher["color"] = "1 1 1"
        publisher["visible"] = ["value": true, "script": """
        shared.copyVec3 = value => new Vec3(value.x, value.y, value.z);
        export function init(value) { shared.laterInitialized = true; return value; }
        """]
        objects.append(publisher)
        objects.append([
            "id": "label", "name": "label", "text": ["value": "seed", "script": """
            let label = 'seed';
            export function init(value) { shared.textInits = (shared.textInits || 0) + 1; return value; }
            export function applyUserProperties(p) { shared.textProperties = (shared.textProperties || 0) + 1; label = p.trigger ? 'initial' : 'hot'; }
            export function update() { return label; }
            """],
            "font": "Arial", "pointsize": 12, "origin": "32 32 0", "scale": "1 1 1", "angles": "0 0 0",
        ])
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        try JSONSerialization.data(withJSONObject: ["general": ["properties": ["trigger": ["type": "bool", "value": true, "text": "Trigger"]]]])
            .write(to: fixture.root.appendingPathComponent("project.json"))
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        try await renderer.load()
        #expect(renderer.didLoad)
        let shared = try #require(renderer.sceneScriptSharedState)
        for key in ["sawLaterModule", "laterInitWasAbsent", "sawSameOwnerModule"] {
            #expect(shared.get(key) as? Bool == true)
        }
        for key in ["modules", "inits", "properties"] {
            #expect(shared.get(key) as? Double == 4)
        }
        #expect(shared.get("originSeed") as? String == "787:-31")
        #expect(shared.get("scaleSeed") as? Double == 0.35)
        #expect(shared.get("playCalls") as? Double == 1)
        #expect(shared.get("textInits") as? Double == 1)
        #expect(shared.get("textProperties") as? Double == 1)
        #expect(renderer.textScriptInstances["label"]?.tickString() == "initial")
        renderer.dispatchTransformScriptUserProperties(["trigger": .bool(false)])
        #expect(renderer.textScriptInstances["label"]?.tickString() == "hot")
        #expect(shared.get("textProperties") as? Double == 2)
    }

    @Test("An origin publisher without update commits cross-context layer writes during the consumer callback",
          arguments: [false, true])
    func sharedCallableLayerWritesAreTransactional(throwsAfterWriting: Bool) async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["name"] = "producer"
        objects[0]["origin"] = ["value": "32 32 0", "script": """
        export function init(value) {
            shared.writeLayers = function() {
                thisScene.getLayer('label').text = 'published';
                thisScene.getLayer('consumer').alpha = 0.25;
                thisScene.getLayer('consumer').scale = new Vec3(2, 2, 1);
                \(throwsAfterWriting ? "throw new Error('rollback');" : "")
            };
            return value;
        }
        """]
        var consumer = objects[0]
        consumer["id"] = "consumer"
        consumer["name"] = "consumer"
        consumer["origin"] = "32 32 0"
        consumer["visible"] = ["value": true, "script": """
        export function applyUserProperties(properties) { shared.called = true; shared.writeLayers(); }
        export function update(value) { return value; }
        """]
        objects.append(consumer)
        objects.append([
            "id": "label", "name": "label", "text": "seed", "font": "Arial",
            "pointsize": 12, "origin": "32 32 0", "scale": "1 1 1", "angles": "0 0 0",
        ])
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let project: [String: Any] = [
            "general": ["properties": ["trigger": ["type": "bool", "value": true, "text": "Trigger"]]],
        ]
        try JSONSerialization.data(withJSONObject: project).write(to: fixture.root.appendingPathComponent("project.json"))
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        #expect(renderer.currentSceneScriptUserProperties()["trigger"] == .bool(true))
        try await renderer.load()
        #expect(renderer.dynamicOriginScriptInstances.count == 1)
        #expect(renderer.didLoad)
        #expect(renderer.sceneScriptSharedState?.get("called") as? Bool == true)
        if throwsAfterWriting {
            #expect(renderer.liveScriptAssignedText["label"] == nil)
            #expect(renderer.liveLayerAlpha["consumer"] != 0.25)
            #expect(renderer.layerTransformMutationJournal.entries.values.allSatisfy { $0.scale == nil })
        } else {
            #expect(renderer.liveScriptAssignedText["label"] == "published")
            #expect(renderer.liveLayerAlpha["consumer"] == 0.25)
            #expect(renderer.layerTransformMutationJournal.entries[
                .init(objectID: "consumer", generation: renderer.loadGeneration)
            ]?.scale == SIMD3(2, 2, 1))
        }
    }

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

    @Test("A denied frame commit restores the camera and refuses the speculative texture")
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
        let speculativeDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        let speculative = try #require(renderer.outputTexture?.device.makeTexture(descriptor: speculativeDescriptor))
        let committedFrame = try renderer.finishSceneScriptFrame(
            speculativeFrame: speculative,
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
        #expect(committedFrame !== speculative)
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
        let staleToken = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
        let token = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
        renderer.beginSceneScriptVideoCommands()
        renderer.sceneScriptVideoCommandBuffer.enqueue(
            loopOnly ? [.setLoop(false)] : [.setLoop(false), .pause], objectID: "video"
        )
        var scriptsAreBaked = false
        try renderer.finishSceneScriptLoadVideoCommands(for: token, scriptsAreBaked: &scriptsAreBaked)
        source.applyPerformanceProfile(renderer.currentProfile)
        let snapshot = try #require(source.scriptPlaybackSnapshot)
        renderer.beginSceneScriptVideoCommands()
        renderer.sceneScriptVideoCommandBuffer.enqueue([.setLoop(true), .play], objectID: "video")
        #expect(throws: CancellationError.self) {
            try renderer.finishSceneScriptLoadVideoCommands(for: staleToken, scriptsAreBaked: &scriptsAreBaked)
        }
        let afterStaleCommit = try #require(source.scriptPlaybackSnapshot)
        #expect(afterStaleCommit.loop == false)
        #expect(afterStaleCommit.isPlaying == loopOnly)

        let stalePhase = renderer.introPhaseToken
        renderer.invalidateIntroPhaseAlign()
        #expect(renderer.introLoopOffset == nil)
        await actor.applyIntroLoopOffset(17, token: stalePhase, scriptLoadToken: token)
        #expect(renderer.introLoopOffset == nil)
        await actor.applyIntroLoopOffset(23, token: renderer.introPhaseToken, scriptLoadToken: token)
        #expect(renderer.introLoopOffset == 23)
        await actor.applyIntroLoopOffset(99, token: renderer.introPhaseToken, scriptLoadToken: staleToken)
        #expect(renderer.introLoopOffset == 23)
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

private final class ClockRateSpectrum: AudioSpectrumAnalyzing, Sendable {
    let frame: AudioSpectrumFrame

    init(frame: AudioSpectrumFrame) {
        self.frame = frame
    }

    func analyzeIfDue(nowNanos _: UInt64) -> AudioSpectrumFrame? {
        frame
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
