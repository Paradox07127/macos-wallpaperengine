#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@MainActor
@Suite("Transform-script layer presentation reaches the frame", .serialized)
struct WPETransformScriptLayerPresentationTests {
    @Test("A dynamic origin script's writes to another layer's visible/alpha reach the rendered pipeline")
    func originScriptPresentationWritesReachFrame() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        var target = objects[0]
        target["id"] = "target"
        target["name"] = "target"
        target["origin"] = "32 32 0"
        objects[0]["name"] = "producer"
        objects[0]["origin"] = ["value": "32 32 0", "script": """
        export function update(value) {
            thisScene.getLayer('target').visible = false;
            thisScene.getLayer('target').alpha = 0.3;
            return value;
        }
        """]
        objects.append(target)
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        #expect(renderer.dynamicOriginScriptInstances.count == 1)
        #expect(renderer.layerScriptInstances.isEmpty && renderer.layerAlphaScriptInstances.isEmpty)
        renderer.executor.synchronizeFrameCompletion = true
        for _ in 0 ..< 4 {
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        }
        #expect(renderer.liveLayerVisibility["target"] == false)
        #expect(renderer.liveLayerAlpha["target"] == 0.3)
        let layer = try #require(renderer.lastFramePipeline?.layers.first { $0.graphLayer.objectID == "target" })
        #expect(layer.graphLayer.visible == false, "the script's visible write never reached the frame pipeline")
        #expect(layer.graphLayer.geometry.alpha == 0.3, "the script's alpha write never reached the frame pipeline")
    }
}
#endif
