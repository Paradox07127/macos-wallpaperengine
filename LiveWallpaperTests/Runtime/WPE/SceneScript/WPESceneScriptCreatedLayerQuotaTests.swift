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
        let rejected = try WPELayerScriptInstance(
            script: Self.repeatedDestroyScript,
            shared: WPESharedScriptState(sceneScriptLoadToken: repeatToken),
            createdLayerBridge: bridge
        )
        #expect(repeatToken.failureReason == .createdLayerLimitExceeded(
            limit: WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene
        ))
        #expect(repeatToken.resourceSnapshot.createdLayers == 0)
        #expect(rejected.initialOutput.created.isEmpty)
    }

    @Test("Visualizer and music-player bars leave clock and player controls active")
    @MainActor
    func visualizerAndMusicPlayerShareQuota() throws {
        let token = WPESceneScriptInstanceLimitToken(generation: 19)
        #expect(token.prepare(.init(text: 1, layer: 3, transform: 0)))
        let shared = WPESharedScriptState(sceneScriptLoadToken: token)
        let bridge = WPECreatedLayerBridgeConfiguration(
            imagePaths: ["models/bar.json"], orderedLayerNames: [], allowsSorting: false
        )
        let visualizer = try WPELayerScriptInstance(script: """
        export function init() {
            for (let i = 1; i < 64; i++) thisScene.createLayer('models/bar.json');
        }
        export function update() {}
        """, shared: shared, createdLayerBridge: bridge)
        let playerBars = try WPELayerScriptInstance(script: """
        export function init() {
            for (let i = 1; i < 8; i++) thisScene.createLayer('models/bar.json');
        }
        export function update() {}
        """, shared: shared, createdLayerBridge: bridge)
        #expect(visualizer.initialOutput.created.count == 63)
        #expect(playerBars.initialOutput.created.count == 7)
        #expect(token.resourceSnapshot.createdLayers == 70)
        #expect(token.failureReason == nil)

        let clock = try WPESceneScriptInstance(script: """
        export function update() {
            let time = new Date(2026, 9, 5, 18, 45);
            return time.getHours() + ':' + time.getMinutes();
        }
        """, initialValue: "12:34", shared: shared)
        #expect(clock.tickString() == "18:45")
        let player = try WPELayerScriptInstance(script: """
        export function applyUserProperties(properties) { shared.enablePlayer = properties.musicplayer; }
        export function update() { return shared.enablePlayer; }
        """, shared: shared)
        _ = player.applyUserProperties(["musicplayer": .bool(false)])
        #expect(try #require(player.tick()).own.visible == false)
        _ = player.applyUserProperties(["musicplayer": .bool(true)])
        #expect(try #require(player.tick()).own.visible == true)
        #expect(token.failureReason == nil)
        withExtendedLifetime((visualizer, playerBars)) {}
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
        for (let index = 0; index < \(WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene); index++) made.push(thisScene.createLayer('models/bar.json'));
        thisScene.destroyLayer(made[0]);
        thisScene.destroyLayer(made[0]);
        thisScene.createLayer('models/bar.json');
        thisScene.createLayer('models/bar.json');
    }
    export function update() {}
    """
}
#endif
