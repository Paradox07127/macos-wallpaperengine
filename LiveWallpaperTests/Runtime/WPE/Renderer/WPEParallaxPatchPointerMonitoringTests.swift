#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import Testing

@MainActor
@Suite("WPE parallax patch pointer monitoring", .serialized)
struct WPEParallaxPatchPointerMonitoringTests {
    @Test("Enabling camera parallax through a bound property turns pointer monitoring on")
    func parallaxPatchRefreshesPointerMonitoring() async throws {
        let fixture = try PointerMonitoringFixture.make(parallaxDepth: nil)
        defer { fixture.cleanup() }
        let stack = try Self.makeRenderer(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.renderer.load()
        #expect(!stack.renderer.cameraParallaxSettings.enabled)
        #expect(stack.spy.lastPointerEventsEnabled == false)

        let patch = WPEScenePropertyPatch(
            bindingsByProperty: stack.renderer.scenePropertyBindings,
            oldValues: ["parallaxon": .bool(false)],
            newValues: ["parallaxon": .bool(true)]
        )
        #expect(!patch.requiresReload)
        #expect(stack.renderer.applyScenePropertyPatch(patch))
        #expect(stack.renderer.cameraParallaxSettings.enabled)
        #expect(stack.spy.lastPointerEventsEnabled == true)
    }

    @Test("An update-only parallaxDepth script is seeded at load")
    func updateOnlyDepthScriptSeedsAtLoad() async throws {
        let fixture = try PointerMonitoringFixture.make(parallaxDepth: [
            "value": "0.5 0",
            "script": "export function update(value) { return new Vec2(3, 0); }",
        ])
        defer { fixture.cleanup() }
        let stack = try Self.makeRenderer(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.renderer.load()
        let instance = try #require(stack.renderer.dynamicParallaxDepthScriptInstances["solid"])
        let value = instance.batchTick(pointerPosition: SIMD2(0.5, 0.5)).value
        #expect(value?.x == 3)
    }

    private static func makeRenderer(
        _ fixture: PointerMonitoringFixture
    ) throws -> (renderer: WPEMetalSceneRenderer, surface: WPERenderSurface, spy: PacingSpySurfaceControl) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let spy = PacingSpySurfaceControl()
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            projectManifestRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: spy,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        return (renderer, surface, spy)
    }
}

private final class PacingSpySurfaceControl: WPESurfaceControl {
    private let pointerEvents = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// nil = the renderer never pushed a pointer-monitoring gate.
    var lastPointerEventsEnabled: Bool? {
        pointerEvents.withLock { $0 }
    }

    func applyPacing(_ update: WPERenderPacingUpdate) {
        if let enabled = update.pointerEventsEnabled {
            pointerEvents.withLock { $0 = enabled }
        }
    }

    func setNeedsRedraw() {}
    func drawImmediately() {}
    func releaseDrawables() {}
    func detach() {}
    func setClickCaptureEnabled(_: Bool) {}
}

private struct PointerMonitoringFixture {
    let root: URL
    let descriptor: SceneDescriptor

    static func make(parallaxDepth: [String: Any]?) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-parallax-pointer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "id": "solid", "name": "Solid", "type": "image",
            "image": "models/util/solidlayer.json", "visible": true,
        ]
        object["parallaxDepth"] = parallaxDepth
        let scene = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "32 32 0"],
            "general": [
                "orthogonalprojection": ["width": 64, "height": 64, "auto": true],
                "cameraparallax": ["user": "parallaxon", "value": false],
                "cameraparallaxamount": 1,
                "cameraparallaxmouseinfluence": 1,
            ],
            "objects": [object],
        ], options: [.sortedKeys])
        try scene.write(to: root.appendingPathComponent("scene.json"))
        let project = try JSONSerialization.data(withJSONObject: [
            "workshopid": "parallax-pointer-fixture",
            "type": "scene",
            "file": "scene.json",
            "general": [
                "properties": [
                    "parallaxon": ["type": "bool", "text": "Parallax", "value": false, "order": 0],
                ],
            ],
        ], options: [.sortedKeys])
        try project.write(to: root.appendingPathComponent("project.json"))
        return Self(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: "parallax-pointer-fixture",
                cacheRelativePath: "wpe-cache/parallax-pointer-fixture",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
