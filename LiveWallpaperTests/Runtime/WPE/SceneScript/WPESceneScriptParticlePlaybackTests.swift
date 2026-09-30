#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("Real SceneScript particle playback bridge", .serialized)
@MainActor
struct WPESceneScriptParticlePlaybackTests {
    private func shared(token: WPESceneScriptInstanceLimitToken? = nil) -> WPESharedScriptState {
        let state = WPESharedScriptState(sceneScriptLoadToken: token, layers: [
            .init(id: "particleA", name: "snow", size: .zero, origin: .zero, index: 0, parentName: nil, isParticleSystem: true),
            .init(id: "particleB", name: "", size: .zero, origin: .zero, index: 1, parentName: nil, isParticleSystem: true),
            .init(id: "particleC", name: "", size: .zero, origin: .zero, index: 2, parentName: nil, isParticleSystem: true),
        ])
        state.publishParticlePlayback(["particleA": .init(liveParticleCount: 2, isEmitting: true)])
        return state
    }

    @Test func rendererLayerTableIncludesRealParticleIdentityAndParent() {
        let parent = WPESceneParticleObject(id: "p", name: "parent", particleRelativePath: "p.json",
                                            origin: .zero, scale: SIMD3(repeating: 1), angles: .zero, visible: true,
                                            alpha: 1, color: SIMD3(repeating: 1), parallaxDepth: .zero)
        let child = WPESceneParticleObject(id: "c", name: "child", parentObjectID: "p", particleRelativePath: "c.json",
                                           origin: SIMD3(3, 4, 5), scale: SIMD3(repeating: 1), angles: .zero, visible: true,
                                           alpha: 1, color: SIMD3(repeating: 1), parallaxDepth: .zero)
        let document = WPESceneDocument(camera: .defaultCamera, general: .defaultGeneral, imageObjects: [],
                                        particleObjects: [parent, child], diagnostics: [])
        let table = WPEMetalSceneRenderer.scriptLayerTable(for: document)
        #expect(table.map(\.id) == ["p", "c"])
        let allAreParticleSystems = table.allSatisfy(\.isParticleSystem)
        #expect(allAreParticleSystems)
        #expect(table.last?.parentName == "parent")
        #expect(table.last?.originZ == 5)
    }

    @Test func directLayerMethodsPreserveOrderAndDoNotSendSoundCommands() throws {
        let state = shared()
        let instance = try WPELayerScriptInstance(script: """
        export function init(value) {
            thisLayer.pause(); shared.paused = thisLayer.isPlaying();
            thisLayer.stop(); shared.stopped = thisLayer.isPlaying();
            thisLayer.emitParticles(3); shared.forced = thisLayer.isPlaying();
            thisLayer.play(); return value;
        }
        """, shared: state, ownLayerName: "snow", ownObjectID: "particleA")
        #expect(instance.initialOutput.own.visible)
        #expect(state.get("paused") as? Bool == true)
        #expect(state.get("stopped") as? Bool == false)
        #expect(state.get("forced") as? Bool == true)
        #expect(state.drainParticleCommands() == [.init(objectID: "particleA", command: .pause),
                                                  .init(objectID: "particleA", command: .stop),
                                                  .init(objectID: "particleA", command: .emit(3)),
                                                  .init(objectID: "particleA", command: .play)])
        #expect(state.drainSoundCommands().isEmpty)
    }

    @Test func objectIdentityResolvesUnnamedOwnLayerAndNamedOtherLayer() throws {
        let state = shared()
        _ = try WPELayerScriptInstance(script: """
        export function init(value) {
            thisLayer.stop(); thisScene.getLayer('snow').emitParticles(2); return value;
        }
        """, shared: state, ownLayerName: "", ownObjectID: "particleC")
        #expect(state.drainParticleCommands() == [.init(objectID: "particleC", command: .stop),
                                                  .init(objectID: "particleA", command: .emit(2))])
    }

    @Test func propertyScriptsUseTheSameRealParticleInterface() throws {
        let state = shared()
        let instance = try WPEDynamicTransformScriptInstance(script: """
        export function init(value) { thisLayer.pause(); return value; }
        export function update(value) { thisScene.getLayer('snow').emitParticles(2); return value; }
        """, seed: SIMD3(repeating: 1), valueShape: .scalar, canvasSize: SIMD2(1920, 1080), ownLayerName: "", ownObjectID: "particleC", shared: state)
        #expect(state.drainParticleCommands() == [.init(objectID: "particleC", command: .pause)])
        #expect(instance.tick(pointerPosition: SIMD2(repeating: 0.5), runtimeSeconds: 1) != nil)
        #expect(state.drainParticleCommands() == [.init(objectID: "particleA", command: .emit(2))])
    }

    @Test func exceptionsAndUnknownOptionalDefaultDoNotCommitPartialPlayback() throws {
        let state = shared()
        let instance = try WPELayerScriptInstance(script: """
        export function update(value) { thisLayer.stop(); throw new Error('after stop'); }
        """, shared: state, ownLayerName: "snow", ownObjectID: "particleA")
        _ = instance.tick(runtimeSeconds: 1)
        #expect(state.drainParticleCommands().isEmpty)
        _ = try WPELayerScriptInstance(script: """
        export function init(value) { thisLayer.pause(); thisLayer.emitParticles(); return value; }
        """, shared: state, ownLayerName: "snow", ownObjectID: "particleA")
        #expect(state.drainParticleCommands().isEmpty)
        #expect(state.particlePlaybackSnapshot(objectID: "particleA")?.isEmitting == true)
    }

    @Test func commandBudgetRejectsEntireCallbackAndRetirementRejectsLateBatches() throws {
        let token = WPESceneScriptInstanceLimitToken(generation: 4)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        let state = shared(token: token)
        _ = try WPELayerScriptInstance(script: """
        export function init(value) { for (let i = 0; i < 257; i++) thisLayer.play(); return value; }
        """, shared: state, ownLayerName: "snow", ownObjectID: "particleA")
        #expect(token.failureReason == .particleCommandLimitExceeded(limit: 256))
        #expect(state.drainParticleCommands().isEmpty)
        let retired = WPESceneScriptInstanceLimitToken(generation: 5)
        let retiredState = shared(token: retired)
        retired.retire()
        retiredState.enqueueParticleCommands([.init(objectID: "particleA", command: .stop)])
        #expect(retiredState.drainParticleCommands().isEmpty)
    }

    @Test func sharedValuesAndParticlePublicationUseIndependentLockOrders() {
        let token = WPESceneScriptInstanceLimitToken(generation: 7)
        let state = shared(token: token)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for index in 0 ..< 1000 {
                state.set("changing", index)
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0 ..< 1000 {
                state.enqueueParticleCommands([.init(objectID: "particleA", command: .pause)])
            }
            group.leave()
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(state.drainParticleCommands().count == 1000)
        #expect(token.failureReason == nil)
    }

    @Test func sceneQueueOverflowIsBoundedAndDoesNotPartiallyAppend() {
        let token = WPESceneScriptInstanceLimitToken(generation: 6)
        let state = shared(token: token)
        let commands = Array(repeating: WPESceneScriptParticleCommand(objectID: "particleA", command: .pause), count: 4096)
        state.enqueueParticleCommands(commands)
        state.enqueueParticleCommands([.init(objectID: "particleA", command: .stop)])
        #expect(token.failureReason == .particleCommandLimitExceeded(limit: 4096))
        #expect(state.drainParticleCommands() == commands)
    }
}
#endif
