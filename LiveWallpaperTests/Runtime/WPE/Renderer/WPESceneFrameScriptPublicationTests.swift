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

    private func loadParticleScene(
        editing edit: (inout [[String: Any]]) -> Void
    ) async throws -> (MetalSceneFixture, WPEMetalSceneRenderer) {
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        edit(&objects)
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        try await renderer.load()
        return (fixture, renderer)
    }

    @Test("A parallaxDepth script is the only script and its layer alpha write reaches the frame pipeline")
    func parallaxOnlyLayerWriteReachesFrame() async throws {
        let (fixture, renderer) = try await loadParticleScene { objects in
            objects[0]["name"] = "target"
            objects[0]["parallaxDepth"] = ["value": "1 1", "script": """
            export function init(value) { thisScene.getLayer('target').alpha = 0; return value; }
            """]
        }
        defer { fixture.cleanup() }
        defer { renderer.cleanup() }
        #expect(renderer.dynamicParallaxDepthScriptInstances.count == 1)
        for _ in 0 ..< 2 {
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        }
        let solid = try #require(renderer.lastFramePipeline?.layers.first { $0.graphLayer.objectID == "solid" })
        #expect(solid.graphLayer.geometry.alpha == 0)
    }

    @Test("A parallaxDepth script receives its value as a Vec2")
    func parallaxDepthScriptValueIsVec2() async throws {
        let (fixture, renderer) = try await loadParticleScene { objects in
            objects[0]["parallaxDepth"] = ["value": "1 1", "script": """
            export function init(value) { value.x = value instanceof Vec2 ? 2 : 9; value.y = 3; return value; }
            """]
        }
        defer { fixture.cleanup() }
        defer { renderer.cleanup() }
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        #expect(renderer.parallaxAuthoredDepthByObjectID["solid"] == SIMD2<Double>(2, 3))
    }

    @Test("A root's scripted depth carries its child layers and particles; a child's own script only updates the table")
    func scriptedRootDepthReachesDescendants() async throws {
        let (fixture, renderer) = try await loadParticleScene { objects in
            objects[0]["parallaxDepth"] = ["value": "1 1", "script": """
            export function init(value) { value.x = 2; value.y = 3; return value; }
            """]
            objects[1]["parent"] = "solid"
            objects.append([
                "id": "kid", "name": "Kid", "type": "image", "image": "models/util/solidlayer.json",
                "parent": "solid", "parallaxDepth": "0.5 0.5",
            ])
            objects.append([
                "id": "scriptedKid", "name": "Scripted Kid", "type": "image", "image": "models/util/solidlayer.json",
                "parent": "solid", "parallaxDepth": ["value": "0.5 0.5", "script": """
                export function init(value) { value.x = 7; value.y = 7; return value; }
                """],
            ])
        }
        defer { fixture.cleanup() }
        defer { renderer.cleanup() }
        for _ in 0 ..< 2 {
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        }
        let rootDepth = SIMD2<Double>(2, 3)
        let layers = try #require(renderer.lastFramePipeline?.layers)
        for id in ["solid", "kid", "scriptedKid"] {
            let layer = try #require(layers.first { $0.graphLayer.objectID == id })
            #expect(layer.graphLayer.parallaxDepth == rootDepth, "\(id) does not move with its root")
        }
        #expect(renderer.parallaxAuthoredDepthByObjectID["scriptedKid"] == SIMD2<Double>(7, 7))
        let particles = try #require(renderer.particleSystems.first { $0.scriptParticleObjectID == "pfx" })
        #expect(particles.parallaxDepth == rootDepth)
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
