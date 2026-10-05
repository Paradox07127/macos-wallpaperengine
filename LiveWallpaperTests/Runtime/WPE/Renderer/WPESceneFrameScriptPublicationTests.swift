#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@MainActor
@Suite("WPE scene frame script publication", .serialized)
struct WPESceneFrameScriptPublicationTests {
    @Test("A particle rate script is the only script and its layer alpha write reaches the frame pipeline")
    func rateOnlyLayerWriteReachesFrame() async throws {
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["name"] = "target"
        objects[1]["instanceoverride"] = ["rate": ["value": 0.1, "script": """
        export function init(value) { thisScene.getLayer('target').alpha = 0; return value; }
        """]]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        #expect(renderer.particleRateScriptInstances.count == 1)
        #expect(renderer.layerScriptInstances.isEmpty && renderer.layerAlphaScriptInstances.isEmpty)
        #expect(renderer.liveLayerAlpha["solid"] == 0)
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        let solid = try #require(renderer.lastFramePipeline?.layers.first { $0.graphLayer.objectID == "solid" })
        #expect(solid.graphLayer.geometry.alpha == 0)
    }

    private func layer(id: String, parentObjectID: String? = nil, attachment: String? = nil) -> WPEPreparedRenderLayer {
        WPEPreparedRenderLayer(
            graphLayer: WPERenderLayer(
                objectID: id, objectName: id, imagePath: "models/\(id).json", materialPath: nil, puppetPath: nil,
                parentObjectID: parentObjectID, attachment: attachment,
                geometry: WPERenderLayerGeometry(
                    origin: .zero, scale: SIMD3(1, 1, 1), angles: .zero, alignment: .center,
                    size: CGSize(width: 10, height: 10), alpha: 1, color: SIMD3(1, 1, 1), brightness: 1
                ),
                compositeA: "_rt_imageLayerComposite_\(id)_a", compositeB: "_rt_imageLayerComposite_\(id)_b",
                localFBOs: [], passes: []
            ),
            passes: []
        )
    }

    @Test("A scripted child of an attached layer enables attachment-aware cursor geometry")
    func ancestorAttachmentEnablesCursorGeometry() {
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(id: "rig"),
            layer(id: "face", parentObjectID: "rig", attachment: "head"),
            layer(id: "button", parentObjectID: "face"),
        ])
        let buttonID = pipeline.layers[2].id
        #expect(WPEMetalSceneRenderer.scriptedLayerFollowsAttachment(
            in: pipeline, isScripted: { $0 == buttonID }, objectParentByID: [:]
        ))
    }

    @Test("The attachment walk crosses a non-rendered host through the scene parent map")
    func ancestorAttachmentAcrossHost() {
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(id: "rig"),
            layer(id: "face", parentObjectID: "rig", attachment: "head"),
            layer(id: "button", parentObjectID: "host"),
        ])
        let buttonID = pipeline.layers[2].id
        #expect(WPEMetalSceneRenderer.scriptedLayerFollowsAttachment(
            in: pipeline, isScripted: { $0 == buttonID }, objectParentByID: ["host": "face"]
        ))
    }

    @Test("A scripted layer with no attachment anywhere up its chain keeps plain cursor geometry")
    func unattachedChainStaysDisabled() {
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(id: "rig"),
            layer(id: "face", parentObjectID: "rig", attachment: "head"),
            layer(id: "button", parentObjectID: "loop"),
        ])
        let buttonID = pipeline.layers[2].id
        #expect(!WPEMetalSceneRenderer.scriptedLayerFollowsAttachment(
            in: pipeline, isScripted: { $0 == buttonID }, objectParentByID: ["loop": "button"]
        ))
    }
}
#endif
