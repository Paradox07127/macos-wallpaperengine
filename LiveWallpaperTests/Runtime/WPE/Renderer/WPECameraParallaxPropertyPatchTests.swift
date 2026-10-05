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
@Suite("WPE camera-parallax property patches", .serialized)
struct WPECameraParallaxPropertyPatchTests {
    /// The workshop 3810519013 shape: sliders declared in project.json, dropped
    /// {"user"} envelopes repaired by inference, parallaxDepth init() script.
    @Test("Inferred slider bindings patch cameraParallaxSettings in place")
    func inferredSliderPatchAppliesLive() async throws {
        let fixture = try ParallaxPatchFixture.make()
        defer { fixture.cleanup() }
        let stack = try Self.makeRenderer(fixture)
        defer { stack.renderer.cleanup() }
        await stack.actor.adopt(WPERendererHandoff(renderer: stack.renderer).renderer)
        try await stack.actor.load()

        // Slider defaults (0.8 / 0.4) flowed through the inferred envelopes.
        #expect(abs(stack.renderer.cameraParallaxSettings.amount - 0.8) < 1e-9)
        #expect(abs(stack.renderer.cameraParallaxSettings.mouseInfluence - 0.4) < 1e-9)

        let patch = WPEScenePropertyPatch(
            bindingsByProperty: stack.renderer.scenePropertyBindings,
            oldValues: ["newproperty": .number(0.8)],
            newValues: ["newproperty": .number(0.2)]
        )
        #expect(!patch.requiresReload)
        #expect(stack.renderer.canApplyScenePropertyPatch(patch))
        #expect(stack.renderer.applyScenePropertyPatch(patch))
        #expect(abs(stack.renderer.cameraParallaxSettings.amount - 0.2) < 1e-9)
        #expect(abs(stack.renderer.cameraParallaxSettings.mouseInfluence - 0.4) < 1e-9)
        #expect(stack.renderer.sceneScriptSharedState?.get("patchedAmount") as? Double == 0.2)
    }

    @Test("Script camera writes reach frame sampling and failure rollback")
    func scriptCameraWritesReachRenderer() async throws {
        let fixture = try ParallaxPatchFixture.make()
        defer { fixture.cleanup() }
        let stack = try Self.makeRenderer(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.renderer.load()
        let shared = try #require(stack.renderer.sceneScriptSharedState)
        let snapshot = stack.renderer.captureSceneScriptPresentation()
        _ = try WPEDynamicTransformScriptInstance(script: """
        export function init(value) {
            thisScene.cameraparallaxamount = 0.23;
            thisScene.cameraparallaxmouseinfluence = 0.67;
            return value;
        }
        """, seed: .zero, canvasSize: SIMD2(64, 64), shared: shared)
        _ = stack.renderer.sampleFrameContext(inputs: stack.renderer.makeFrameInputs())
        #expect(stack.renderer.cameraParallaxSettings.amount == 0.23)
        #expect(stack.renderer.cameraParallaxSettings.mouseInfluence == 0.67)
        stack.renderer.restoreSceneScriptPresentation(snapshot)
        #expect(shared.cameraParallaxSnapshot().amount == snapshot.cameraParallax.amount)
        #expect(stack.renderer.cameraParallaxSettings.amount == snapshot.cameraParallax.amount)
    }

    private static func makeRenderer(
        _ fixture: ParallaxPatchFixture
    ) throws -> (renderer: WPEMetalSceneRenderer, surface: WPERenderSurface, actor: WPEDisplayRenderActor) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            projectManifestRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        return (renderer, surface, WPEDisplayRenderActor(backing: .main))
    }
}

private struct ParallaxPatchFixture {
    let root: URL
    let descriptor: SceneDescriptor

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-parallax-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "32 32 0"],
            "general": [
                "orthogonalprojection": ["width": 64, "height": 64, "auto": true],
                "cameraparallax": true,
                "cameraparallaxamount": 1,
                "cameraparallaxmouseinfluence": 1,
            ],
            "objects": [[
                "id": "solid", "name": "Solid", "type": "image",
                "image": "models/util/solidlayer.json", "visible": true,
                "parallaxDepth": [
                    "value": "0.5 0",
                    "script": """
                    export function init(value) {
                        var amount = Math.max(thisScene.cameraparallaxamount, 0.0001);
                        var influence = Math.max(Math.abs(thisScene.cameraparallaxmouseinfluence), 0.0001);
                        return new Vec2(amount * influence, 0);
                    }
                    export function applyUserProperties(properties) {
                        shared.patchedAmount = thisScene.cameraparallaxamount;
                    }
                    """,
                ],
            ]],
        ], options: [.sortedKeys])
        try scene.write(to: root.appendingPathComponent("scene.json"))
        let project = try JSONSerialization.data(withJSONObject: [
            "workshopid": "parallax-patch-fixture",
            "type": "scene",
            "file": "scene.json",
            "general": [
                "properties": [
                    "newproperty": ["type": "slider", "text": "镜头视差", "value": 0.8, "min": 0, "max": 1, "order": 0],
                    "newproperty1": ["type": "slider", "text": "鼠标影响", "value": 0.4, "min": 0, "max": 1, "order": 1],
                ],
            ],
        ], options: [.sortedKeys])
        try project.write(to: root.appendingPathComponent("project.json"))
        return Self(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: "parallax-patch-fixture",
                cacheRelativePath: "wpe-cache/parallax-patch-fixture",
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
