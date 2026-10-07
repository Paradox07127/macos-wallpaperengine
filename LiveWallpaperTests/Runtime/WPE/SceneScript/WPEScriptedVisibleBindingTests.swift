#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import Testing

@MainActor
@Suite("Scripted visible bound to a user property", .serialized)
struct WPEScriptedVisibleBindingTests {
    @Test("update(value) receives the bound property's current value, also after a live patch")
    func updateReceivesBoundValueAcrossPatch() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-bound-visible-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true]],
            "objects": [[
                "id": "bound", "name": "bound", "type": "image",
                "image": "models/util/solidlayer.json", "origin": "32 32 0", "size": "64 64",
                "visible": [
                    "script": "export function update(value) { shared.seen = value; return value; }",
                    "user": "_3d",
                    "value": false,
                ] as [String: Any],
            ]],
        ]).write(to: root.appendingPathComponent("scene.json"))
        try JSONSerialization.data(withJSONObject: [
            "workshopid": "wpe-bound-visible", "type": "scene", "file": "scene.json",
            "general": ["properties": ["_3d": ["type": "bool", "value": true]]],
        ]).write(to: root.appendingPathComponent("project.json"))

        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: SceneDescriptor(
                workshopID: "wpe-bound-visible",
                cacheRelativePath: "wpe-cache/wpe-bound-visible",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            cacheRootURL: root,
            projectManifestRootURL: root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        let instance = try #require(renderer.layerScriptInstances["bound"])
        let shared = try #require(renderer.sceneScriptSharedState)

        _ = instance.tick()
        #expect(shared.get("seen") as? Bool == true, "the authored false would win over the bound true")

        let patch = WPEScenePropertyPatch(
            bindingsByProperty: renderer.scenePropertyBindings,
            oldValues: ["_3d": .bool(true)],
            newValues: ["_3d": .bool(false)]
        )
        #expect(!patch.requiresReload)
        #expect(renderer.applyScenePropertyPatch(patch))
        #expect(renderer.liveLayerVisibility["bound"] == false)

        let output = instance.tick()
        #expect(shared.get("seen") as? Bool == false, "update would still receive the pre-patch value")
        #expect(output?.own.visible == false, "the returned stale value would re-show the layer every frame")
    }
}
#endif
