import Foundation
import Testing
@testable import LiveWallpaper

struct WPEStaticCacheExclusionTests {
    @Test("Alpha-script layers are excluded from static caching")
    func alphaScriptLayersExcluded() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            colorScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: [],
            alphaScriptIDs: ["7", "9"],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids == ["7", "9"])
    }

    @Test("General layer scripts are excluded (they can drive own alpha/visibility)")
    func layerScriptLayersExcluded() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            colorScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: ["intro"],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids.contains("intro"))
    }

    @Test("Cross-layer alpha writes exclude the TARGET layer once written")
    func crossLayerAlphaWriteExcludesTarget() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            colorScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: ["controller"],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: ["victim"]
        )
        #expect(ids.contains("victim"))
    }

    @Test("Geometry-script and live-created exclusions still union in")
    func geometryExclusionsRetained() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: ["o"],
            scaleScriptIDs: ["s"],
            anglesScriptIDs: ["a"],
            colorScriptIDs: [],
            liveCreatedLayerIDs: ["c"],
            layerScriptIDs: [],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids == ["o", "s", "a", "c"])
    }

    @Test("Color-script layers are excluded (the tint is baked before classification)")
    func colorScriptLayersExcluded() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            colorScriptIDs: ["tinted"],
            liveCreatedLayerIDs: [],
            layerScriptIDs: [],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids == ["tinted"])
    }

    @Test("No script sources → no exclusions")
    func emptySourcesYieldEmptySet() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            colorScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: [],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids.isEmpty)
    }
}
