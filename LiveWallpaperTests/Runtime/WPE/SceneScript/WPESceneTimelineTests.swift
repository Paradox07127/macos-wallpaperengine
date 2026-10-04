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
