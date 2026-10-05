import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("WPE scene camera-parallax script bridge")
struct WPESceneCameraParallaxScriptTests {
    private func sharedState(
        parallax: WPESceneCameraParallaxSettings,
        layers: [WPESceneScriptLayerInfo] = []
    ) -> WPESharedScriptState {
        let state = WPESharedScriptState(layers: layers)
        state.seedCameraParallax(parallax)
        return state
    }

    @Test("thisScene.cameraparallax* read the seeded settings, never undefined")
    func cameraParallaxGlobalsReadSeededValues() throws {
        let shared = sharedState(parallax: .init(
            enabled: true, amount: 0.8, delay: 0.2, mouseInfluence: 0.4
        ))
        let instance = try WPEDynamicTransformScriptInstance(
            script: """
            export function init(value) {
                shared.amount = thisScene.cameraparallaxamount;
                shared.delay = thisScene.cameraparallaxdelay;
                shared.influence = thisScene.cameraparallaxmouseinfluence;
                shared.enabled = thisScene.cameraparallax;
                return value;
            }
            """,
            seed: .zero, canvasSize: SIMD2(64, 64),
            ownLayerName: "P", ownObjectID: "p", shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 2)
        )
        #expect(shared.get("amount") as? Double == 0.8)
        #expect(shared.get("delay") as? Double == 0.2)
        #expect(shared.get("influence") as? Double == 0.4)
        #expect(shared.get("enabled") as? Bool == true)
        withExtendedLifetime(instance) {}
    }

    @Test("Writes through thisScene.cameraparallax* update the shared snapshot")
    func cameraParallaxGlobalsWriteThrough() throws {
        let shared = sharedState(parallax: .init(
            enabled: false, amount: 0.5, delay: 0.1, mouseInfluence: 0.5
        ))
        let instance = try WPEDynamicTransformScriptInstance(
            script: """
            export function init(value) {
                thisScene.cameraparallaxamount = 0.25;
                thisScene.cameraparallax = true;
                return value;
            }
            """,
            seed: .zero, canvasSize: SIMD2(64, 64),
            ownLayerName: "P", ownObjectID: "p", shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 2)
        )
        let snapshot = shared.cameraParallaxSnapshot()
        #expect(snapshot.amount == 0.25)
        #expect(snapshot.enabled == true)
        // Non-finite writes are ignored.
        let other = try WPEDynamicTransformScriptInstance(
            script: "export function init(value) { thisScene.cameraparallaxamount = NaN; return value; }",
            seed: .zero, canvasSize: SIMD2(64, 64),
            shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 2)
        )
        #expect(shared.cameraParallaxSnapshot().amount == 0.25)
        withExtendedLifetime(instance) {}
        withExtendedLifetime(other) {}
    }

    /// Workshop 3810519013 / 3811736073: init() sizes the horizontal depth so the
    /// cursor can sweep exactly the image's padded width.
    @Test("parallaxDepth init() computes depth from thisScene + thisLayer + canvas")
    func parallaxDepthInitComputesPaddedDepth() throws {
        let shared = sharedState(
            parallax: .init(enabled: true, amount: 0.8, delay: 0, mouseInfluence: 0.4),
            layers: [.init(
                id: "img", name: "img",
                size: SIMD2(5911.5791, 1080), origin: .zero, index: 0, parentName: nil
            )]
        )
        let instance = try WPEDynamicTransformScriptInstance(
            script: """
            export function init(value) {
                var amount = Math.max(thisScene.cameraparallaxamount, 0.0001);
                var influence = Math.max(Math.abs(thisScene.cameraparallaxmouseinfluence), 0.0001);
                var padX = thisLayer.size.x * thisLayer.scale.x - engine.canvasSize.x;
                var depthX = padX > 1 ? padX / (engine.canvasSize.x * amount * influence) : 0;
                return new Vec2(depthX, 0);
            }
            """,
            seed: SIMD3(0.8, 0, 0), canvasSize: SIMD2(2560, 1440),
            ownLayerName: "img", ownObjectID: "img", shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 2)
        )
        // init-only scripts re-publish the init result on tick.
        let ticked = try #require(instance.tick(pointerPosition: .zero))
        let expected = (5911.5791 - 2560) / (2560 * 0.8 * 0.4)
        #expect(abs(ticked.x - expected) < 0.001)
        #expect(ticked.y == 0)
    }
}
