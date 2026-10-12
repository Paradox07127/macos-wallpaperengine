import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite(.serialized)
@MainActor
struct WPESceneTimelineTests {
    private func document() throws -> WPESceneDocument {
        let json = """
        {"camera":{"center":"1920 1080 0","eye":"1920 1080 100","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":3840,"height":2160}},
         "objects":[
          {"id":1,"name":"Parent","origin":"1920 1080 0"},
          {"id":1733,"name":"Moon","parent":1,"image":"materials/moon.json",
           "origin":{"value":"-800 980 0","animation":{"relative":true,
             "c0":[{"frame":0,"value":0},{"frame":2700,"value":-300}],
             "c1":[{"frame":0,"value":0},{"frame":2700,"value":-1600}],
             "options":{"fps":30,"length":2700,"mode":"loop","parent":{"key":"alpha"}}}},
           "alpha":{"value":1,"animation":{
             "c0":[{"frame":0,"value":0},{"frame":1470,"value":0},{"frame":1800,"value":1},{"frame":2460,"value":0}],
             "options":{"name":"moon-cycle","fps":30,"length":2700,"mode":"loop"}}}}]}
        """
        return try WPESceneDocumentParser.parse(data: Data(json.utf8))
    }

    @Test("Moon origin preserves relative offsets and follows the linked alpha clock")
    func relativeOriginAndLinkedClock() throws {
        let document = try document()
        let image = try #require(document.imageObjects.first)
        let origin = try #require(image.originAnimation)
        let alpha = try #require(image.alphaAnimation)
        #expect(origin.relative)
        #expect(origin.parentKey == "alpha")
        #expect(origin.originVector(at: 0) == [-800, 980, 0])
        #expect(origin.originVector(at: 90) == [-800, 980, 0])
        for time in [0.0, 20, 49, 60, 82, 90] {
            #expect((alpha.scalar(at: time) ?? 1) == (time == 60 ? 1 : 0))
        }
        let store = WPESceneTimelineStore()
        store.configure(document: document)
        store.publishTime(10)
        store.command(objectID: "1733", property: "alpha", operation: "rate", value: 2)
        #expect(store.seconds(objectID: "1733", property: "origin", at: 20) == 30)
        #expect(store.seconds(objectID: "1733", property: "alpha", at: 20) == 30)
        #expect(store.alphaOverrides(at: 35)["1733"] == 1)
    }

    @Test("Rate changes keep the current pose; pause, frame seek and play share one timeline")
    func clockControlsPreserveContinuity() throws {
        let store = WPESceneTimelineStore()
        try store.configure(document: document())
        store.publishTime(20)
        store.command(objectID: "1733", property: "origin", operation: "pause", value: 0)
        #expect(store.seconds(objectID: "1733", property: "alpha", at: 50) == 20)
        store.publishTime(50)
        store.command(objectID: "1733", property: "origin", operation: "frame", value: 1800)
        #expect(store.alphaOverrides(at: 50)["1733"] == 1)
        store.command(objectID: "1733", property: "alpha", operation: "play", value: 0)
        #expect(store.seconds(objectID: "1733", property: "origin", at: 51) == 61)
        store.command(objectID: "1733", property: "alpha", operation: "rate", value: .nan)
        #expect(store.read(objectID: "1733", property: "alpha", field: "rate") == 1)
    }

    @Test("Control-only alpha scripts keep authored alpha and both VM bridges share animation state")
    func bothScriptBridgesShareClockWithoutAlphaClaim() throws {
        let document = try document()
        let shared = WPESharedScriptState(layers: WPEMetalSceneRenderer.scriptLayerTable(for: document))
        shared.timelineAnimations.configure(document: document)
        let layer = try WPELayerScriptInstance(
            script: "export function init(){ thisLayer.getAnimation().rate = 2; } export function update(){}",
            shared: shared, outputMode: .returnedAlpha(initialValue: 1),
            ownLayerName: "Moon", ownObjectID: "1733"
        )
        #expect(!layer.initialOutput.own.alphaAssigned)
        #expect(try #require(layer.tick(runtimeSeconds: 20)).own.alphaAssigned == false)
        #expect(shared.timelineAnimations.read(objectID: "1733", property: "origin", field: "rate") == 2)
        let transform = try WPEDynamicTransformScriptInstance(
            script: "export function init(){thisLayer.getAnimation('moon-cycle').rate = 0.5;} export function update(){return new Vec3(thisLayer.getAnimation().rate, 0, 0);}",
            seed: .zero, canvasSize: SIMD2(3840, 2160),
            ownLayerName: "Moon", ownObjectID: "1733", shared: shared
        )
        #expect(try #require(transform.tick(pointerPosition: .zero, runtimeSeconds: 20)).x == 0.5)
        #expect(shared.timelineAnimations.read(objectID: "1733", property: "alpha", field: "rate") == 0.5)
    }

    @Test("IAnimation exposes isPlaying and its authored fps, frameCount, duration and name (3798688689)")
    func animationHandleReportsPlaybackAndMetadata() throws {
        let document = try document()
        let shared = WPESharedScriptState(layers: WPEMetalSceneRenderer.scriptLayerTable(for: document))
        shared.timelineAnimations.configure(document: document)
        _ = try WPEDynamicTransformScriptInstance(
            script: """
            export function init(value) {
                const a = thisLayer.getAnimation('moon-cycle');
                shared.meta = [a.isPlaying(), a.fps, a.frameCount, a.duration, a.name].join(',');
                a.pause();
                shared.paused = a.isPlaying();
                a.play();
                shared.resumed = a.isPlaying();
                return value;
            }
            export function update(value) { return value; }
            """,
            seed: .zero, canvasSize: SIMD2(3840, 2160),
            ownLayerName: "Moon", ownObjectID: "1733", shared: shared
        )
        #expect(shared.get("meta") as? String == "true,30,2700,90,moon-cycle")
        #expect(shared.get("paused") as? Bool == false)
        #expect(shared.get("resumed") as? Bool == true)
    }

    @Test("Host angles and scale animations resolve by authored name and obey play, pause and setFrame (3798688689)")
    func hostAnglesAndScaleAnimationsAreControllable() throws {
        let json = """
        {"camera":{"center":"0 0 0"},
         "general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
          {"id":1037,"name":"[037] package_014",
           "angles":{"value":"0 0 -0.0013","animation":{"relative":true,
             "c0":[{"frame":0,"value":0}],"c1":[{"frame":0,"value":0}],
             "c2":[{"frame":0,"value":-0.0125},{"frame":600,"value":0.0125}],
             "options":{"fps":60,"length":1200,"mode":"loop","name":"loop_kv2_character__1037_angles"}}}},
          {"id":1122,"name":"[122] paper",
           "angles":{"value":"0 0 -1.05242","animation":{"relative":true,
             "c0":[{"frame":0,"value":0}],"c1":[{"frame":0,"value":0}],
             "c2":[{"frame":0,"value":0},{"frame":2600,"value":1.05242}],
             "options":{"fps":1200,"length":2600,"mode":"single","startpaused":true,"name":"信封_root_1_angles"}}},
           "scale":{"value":"1 1 1","animation":{"relative":true,
             "c0":[{"frame":0,"value":-1},{"frame":2600,"value":0}],
             "c1":[{"frame":0,"value":-1},{"frame":2600,"value":0}],
             "c2":[{"frame":0,"value":0}],
             "options":{"fps":1200,"length":2600,"mode":"single","startpaused":true,"name":"信封_root_1_scale"}}}}]}
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let shared = WPESharedScriptState(layers: WPEMetalSceneRenderer.scriptLayerTable(for: document))
        shared.timelineAnimations.configure(document: document)
        shared.timelineAnimations.publishTime(2)
        _ = try WPEDynamicTransformScriptInstance(
            script: """
            export function init(value) {
                const loop = thisScene.getLayer('[037] package_014').getAnimation('loop_kv2_character__1037_angles');
                const angles = thisLayer.getAnimation('信封_root_1_angles');
                const scale = thisLayer.getAnimation('信封_root_1_scale');
                shared.initial = [loop.isPlaying(), angles.isPlaying(), scale.isPlaying()].join(',');
                loop.pause();
                angles.play();
                scale.setFrame(1300);
                shared.after = [loop.isPlaying(), angles.isPlaying(), scale.isPlaying(), scale.getFrame()].join(',');
                return value;
            }
            export function update(value) { return value; }
            """,
            seed: .zero, canvasSize: SIMD2(1920, 1080),
            ownLayerName: "[122] paper", ownObjectID: "1122", shared: shared
        )
        #expect(shared.get("initial") as? String == "true,false,false")
        #expect(shared.get("after") as? String == "false,true,false,1300")
        #expect(shared.timelineAnimations.seconds(objectID: "1037", property: "angles", at: 5) == 2)
    }

    private func linkedDocument(startPaused: Bool) throws -> WPESceneDocument {
        let json = """
        {"camera":{"center":"1920 1080 0","eye":"1920 1080 100","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":3840,"height":2160}},
         "objects":[
          {"id":7,"name":"Sun","image":"materials/sun.json",
           "origin":{"value":"0 0 0","animation":{"relative":true,
             "c0":[{"frame":0,"value":0},{"frame":30,"value":100}],
             "c1":[{"frame":0,"value":0},{"frame":30,"value":0}],
             "options":{"fps":30,"length":60,"mode":"loop","parent":{"key":"alpha"}}}},
           "alpha":{"value":1,"animation":{
             "c0":[{"frame":0,"value":0.25},{"frame":30,"value":1},{"frame":60,"value":0.25}],
             "options":{"fps":30,"length":60,"mode":"loop","startpaused":\(startPaused)}}}}]}
        """
        return try WPESceneDocumentParser.parse(data: Data(json.utf8))
    }

    @Test("A startpaused alpha track holds frame 0 with its linked origin until play() advances both")
    func startPausedAlphaFollowsLinkedClock() throws {
        let document = try linkedDocument(startPaused: true)
        let alpha = try #require(document.imageObjects.first?.alphaAnimation)
        let store = WPESceneTimelineStore()
        store.configure(document: document)
        store.publishTime(1)
        #expect(store.seconds(objectID: "7", property: "origin", at: 1) == 0)
        #expect(store.alphaOverrides(at: 1)["7"] == alpha.scalar(at: 0))
        #expect(store.alphaOverrides(at: 1)["7"] == 0.25)
        #expect(store.read(objectID: "7", property: "alpha", field: "frame") == 0)

        store.command(objectID: "7", property: "alpha", operation: "play", value: 0)
        #expect(store.seconds(objectID: "7", property: "origin", at: 1.5) == 0.5)
        #expect(store.alphaOverrides(at: 1.5)["7"] == alpha.scalar(at: 0.5))
        #expect((store.alphaOverrides(at: 1.5)["7"] ?? 0) > 0.25)
    }

    @Test("A free-running, uncommanded alpha track stays on the ordinary sampler")
    func freeRunningAlphaHasNoOverride() throws {
        let store = WPESceneTimelineStore()
        try store.configure(document: linkedDocument(startPaused: false))
        store.publishTime(1)
        #expect(store.alphaOverrides(at: 1).isEmpty)
        #expect(store.seconds(objectID: "7", property: "origin", at: 1) == 1)
    }

    @Test("Explicit alpha assignments retain their claim")
    func explicitAlphaAssignmentStillOverrides() throws {
        let layer = try WPELayerScriptInstance(
            script: "export function init(){thisLayer.alpha=0.3;}",
            outputMode: .returnedAlpha(initialValue: 1)
        )
        #expect(layer.initialOutput.own.alphaAssigned)
        #expect(abs(layer.initialOutput.own.alpha - 0.3) < 0.0001)
    }
}
