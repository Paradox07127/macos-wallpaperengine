import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import Testing

struct WPEAncestorVisibilityTests {
    @Test("Parser exposes parent + own-visibility for groups and layers")
    func parserExposesHierarchy() throws {
        let json: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [
                ["id": 1, "name": "group", "visible": ["user": "feat", "value": false]],
                ["id": 2, "name": "child", "parent": 1, "image": "models/util/solidlayer.json",
                 "visible": ["script": "export function update(){}", "value": true]],
                ["id": 3, "name": "top", "image": "models/util/solidlayer.json",
                 "visible": ["script": "export function update(){}", "value": true]],
            ],
        ]
        let doc = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json))
        #expect(doc.objectParentByID["2"] == "1")
        #expect(doc.objectParentByID["3"] == nil)
        #expect(doc.ownVisibilityByID["1"] == false)
        #expect(doc.ownVisibilityByID["2"] == true)

        let groupBinding = try #require(doc.propertyBindings["feat"]?.first)
        #expect(groupBinding.target == .groupObject(id: "1"))
        #expect(groupBinding.kind == .visible)
        #expect(groupBinding.action == .reload)
        #expect(WPEScenePropertyPatch(
            bindingsByProperty: doc.propertyBindings,
            oldValues: ["feat": .bool(false)],
            newValues: ["feat": .bool(true)]
        ).requiresReload)

        let visibleDoc = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json),
            userValues: ["feat": .bool(true)]
        )
        #expect(visibleDoc.ownVisibilityByID["1"] == true)
        #expect(visibleDoc.imageObjects.first { $0.id == "2" }?.visible == true)
    }

    @Test("Live ancestor chain: hidden group hides child; live toggle re-shows it")
    func liveChainFold() {
        let parents = ["2": "1", "3": "1", "top": "none-existent-skip"]
        let own = ["1": false, "2": true, "3": true]

        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "2", parentByID: parents, liveLayerVisibility: [:], liveTextVisibility: [:], ownVisibilityByID: own) == false)

        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "2", parentByID: parents, liveLayerVisibility: ["1": true], liveTextVisibility: [:], ownVisibilityByID: own) == true)

        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "nochild", parentByID: parents, liveLayerVisibility: [:], liveTextVisibility: [:], ownVisibilityByID: own) == true)
    }

    @Test("Live ancestor chain: cycle-safe")
    func chainCycleSafe() {
        let parents = ["a": "b", "b": "a"]
        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "a", parentByID: parents, liveLayerVisibility: [:], liveTextVisibility: [:], ownVisibilityByID: ["a": true, "b": true]) == true)
    }

    /// Workshop 3122339805 regression: the parsed `visible` flag is already
    /// ancestor-folded, so seeding live visibility from it pinned children of a
    /// hidden window hidden forever — the parent's script toggle woke the bar
    /// alone, leaving a floating strip. Live visibility must store own flags and
    /// fold ancestors when the frame overlay is built.
    @MainActor
    @Test("Parent shown by a visible-script re-shows its subtree")
    func parentScriptToggleRevealsChildren() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-vis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        export function applyUserProperties(property) {
            if (property.show === true) thisLayer.visible = true;
            if (property.show === false) thisLayer.visible = false;
        }
        """
        try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true]],
            "objects": [
                ["id": 1, "name": "win", "type": "image", "image": "models/util/solidlayer.json",
                 "color": "1 0 0", "origin": "32 60 0", "size": "64 8",
                 "visible": ["script": script, "value": false]],
                ["id": 2, "name": "body", "type": "image", "parent": 1,
                 "image": "models/util/solidlayer.json", "color": "0 1 0",
                 "origin": "0 -24 0", "size": "64 40"],
            ],
        ]).write(to: root.appendingPathComponent("scene.json"))
        try JSONSerialization.data(withJSONObject: [
            "workshopid": "wpe-vis", "type": "scene", "file": "scene.json",
            "general": ["properties": ["show": ["type": "bool", "value": true]]],
        ]).write(to: root.appendingPathComponent("project.json"))

        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: SceneDescriptor(
                workshopID: "wpe-vis",
                cacheRelativePath: "wpe-cache/wpe-vis",
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
        renderer.executor.synchronizeFrameCompletion = true
        let frame = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())

        #expect(renderer.liveLayerVisibility["1"] == true)
        #expect(renderer.liveLayerVisibility["2"] == true)
        #expect(renderer.liveLayerVisibilityIncludingText["2"] == true)

        // The child's green body must actually reach the framebuffer.
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(frame))
        let bytesPerRow = staged.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * staged.height)
        staged.getBytes(
            &bytes, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, staged.width, staged.height), mipmapLevel: 0
        )
        var colors: [String: Int] = [:]
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let key = "\(bytes[i]),\(bytes[i + 1]),\(bytes[i + 2]),\(bytes[i + 3])"
            colors[key, default: 0] += 1
        }
        #expect(colors.contains { $0.key.hasPrefix("0,255,0") || $0.key.hasPrefix("0,25") })
    }
}
