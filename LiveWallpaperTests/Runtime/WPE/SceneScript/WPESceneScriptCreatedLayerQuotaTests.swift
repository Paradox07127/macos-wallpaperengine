#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("SceneScript created-layer quota")
struct WPESceneScriptCreatedLayerQuotaTests {
    @Test("Destroyed created layers return their quota exactly once")
    @MainActor
    func destroyedCreatedLayersReturnQuota() throws {
        let bridge = WPECreatedLayerBridgeConfiguration(
            imagePaths: ["models/bar.json"], orderedLayerNames: ["MAIN"], allowsSorting: false
        )
        let churnToken = preparedToken(generation: 17)
        let churn = try WPELayerScriptInstance(
            script: Self.createDestroyChurnScript,
            shared: WPESharedScriptState(sceneScriptLoadToken: churnToken),
            createdLayerBridge: bridge
        )
        #expect(churnToken.failureReason == nil)
        #expect(churnToken.resourceSnapshot.createdLayers == 1)
        #expect(churn.initialOutput.created.count == 1)

        let repeatToken = preparedToken(generation: 18)
        _ = try WPELayerScriptInstance(
            script: Self.repeatedDestroyScript,
            shared: WPESharedScriptState(sceneScriptLoadToken: repeatToken),
            createdLayerBridge: bridge
        )
        #expect(repeatToken.failureReason == .createdLayerLimitExceeded(limit: 64))
        #expect(repeatToken.resourceSnapshot.createdLayers == 64)
    }

    private func preparedToken(generation: Int) -> WPESceneScriptInstanceLimitToken {
        let token = WPESceneScriptInstanceLimitToken(generation: generation)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        return token
    }

    private static let createDestroyChurnScript = """
    export function init() {
        let layer = thisScene.createLayer('models/bar.json');
        for (let index = 0; index < 100; index++) {
            thisScene.destroyLayer(layer);
            layer = thisScene.createLayer('models/bar.json');
        }
    }
    export function update() {}
    """

    /// The second destroy of the same layer must not return a second slot.
    private static let repeatedDestroyScript = """
    export function init() {
        const made = [];
        for (let index = 0; index < 64; index++) made.push(thisScene.createLayer('models/bar.json'));
        thisScene.destroyLayer(made[0]);
        thisScene.destroyLayer(made[0]);
        thisScene.createLayer('models/bar.json');
        thisScene.createLayer('models/bar.json');
    }
    export function update() {}
    """
}
#endif
