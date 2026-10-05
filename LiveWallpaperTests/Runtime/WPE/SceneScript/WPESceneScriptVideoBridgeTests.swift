#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@Suite("SceneScript detached video bridge")
struct WPESceneScriptVideoBridgeTests {
    private func layer(_ id: String, _ name: String, index: Int = 0) -> WPESceneScriptLayerInfo {
        .init(id: id, name: name, size: SIMD2(256, 128), origin: .zero,
              index: index, parentName: nil)
    }

    private func snapshot(_ generation: UUID, time: Double = 1.5) -> WPEVideoPlaybackSnapshot {
        .init(sourceGeneration: generation, currentTime: time, duration: 2,
              isPlaying: false, rate: 1, loop: true, hasPresentedFrame: true)
    }

    @Test("Getters read source values, including times beyond duration")
    func readsDetachedSource() throws {
        let generation = UUID()
        let shared = WPESharedScriptState(layers: [layer("video", "video")])
        shared.publishVideoPlayback(["video": snapshot(generation, time: 2.005)])
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            const video = thisLayer.getVideoTexture();
            shared.time = video.getCurrentTime(); shared.duration = video.duration;
            shared.playing = video.isPlaying(); shared.rate = video.rate; shared.loop = video.loop;
        }
        """, shared: shared, ownLayerName: "video", ownObjectID: "video", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(instance.initialOutput.own.videoCommands.isEmpty)
        #expect(shared.get("time") as? Double == 2.005)
        #expect(shared.get("duration") as? Double == 2)
        #expect(shared.get("playing") as? Bool == false)
        #expect(shared.get("rate") as? Double == 1)
        #expect(shared.get("loop") as? Double == 1)
    }

    @Test("First paused seek acknowledges its target in the same evaluation", arguments: [0.25, 0.75])
    func firstPausedSeekReadback(_ target: Double) throws {
        let shared = WPESharedScriptState(layers: [layer("video", "video")])
        shared.publishVideoPlayback(["video": snapshot(UUID(), time: 1.5)], sourceKeys: ["video": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
                                                  export function init() {
                                                      const video = thisLayer.getVideoTexture();
                                                      shared.before = video.getCurrentTime();
                                                      video.setCurrentTime(\(target));
                                                      shared.same = video.getCurrentTime();
                                                      shared.playing = video.isPlaying();
                                                  }
                                                  """, shared: shared, ownLayerName: "video", ownObjectID: "video",
                                                  governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(shared.get("before") as? Double == 1.5)
        #expect(shared.get("same") as? Double == target)
        #expect(shared.get("playing") as? Bool == false)
        #expect(instance.initialOutput.own.videoCommands == [.seek(target)])
    }

    @Test("Pending seek acknowledgement survives paused commands and aliases")
    func pendingSeekReadback() throws {
        let generation = UUID()
        var held = snapshot(generation, time: 0.25)
        held.acknowledgedPausedSeekTime = 0.25
        held.playbackRequested = false
        let shared = WPESharedScriptState(layers: [layer("a", "A"), layer("b", "B", index: 1)])
        shared.publishVideoPlayback(["a": held, "b": held], sourceKeys: ["a": "video.tex", "b": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            const a = thisLayer.getVideoTexture(), b = thisScene.getLayer('B').getVideoTexture();
            a.setCurrentTime(0.5); shared.second = b.getCurrentTime();
            a.play(); b.pause(); b.setCurrentTime(0.75); shared.third = a.getCurrentTime();
            b.stop(); shared.stopped = a.getCurrentTime(); shared.playing = a.isPlaying();
        }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(shared.get("second") as? Double == 0.25)
        #expect(shared.get("third") as? Double == 0.25)
        #expect(shared.get("stopped") as? Double == 0.25)
        #expect(shared.get("playing") as? Bool == false)
        #expect(!instance.initialOutput.own.videoCommands.isEmpty)
    }

    @Test("Replacement source facts discard prior evaluation acknowledgement")
    func replacementSeekReadback() throws {
        let shared = WPESharedScriptState(layers: [layer("a", "A")])
        var old = snapshot(UUID(), time: 0.25)
        old.acknowledgedPausedSeekTime = 0.25
        shared.publishVideoPlayback(["a": old], sourceKeys: ["a": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            const video = thisLayer.getVideoTexture();
            video.setCurrentTime(0.5); shared.oldTime = video.getCurrentTime();
        }
        export function update() {
            const video = thisLayer.getVideoTexture();
            video.setCurrentTime(0.75); shared.newTime = video.getCurrentTime();
        }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(shared.get("oldTime") as? Double == 0.25)
        shared.publishVideoPlayback(["a": snapshot(UUID(), time: 0.6)], sourceKeys: ["a": "video.tex"])
        _ = try #require(instance.tick())
        #expect(shared.get("newTime") as? Double == 0.75)
    }

    @Test("Unqualified finite seek retires a held acknowledgement to decoder facts", arguments: [-0.25, 0, 2, 3])
    func heldSeekFallback(_ target: Double) {
        var state = snapshot(UUID(), time: 0.25)
        state.acknowledgedPausedSeekTime = 0.25
        state.decoderCurrentTime = 0.5
        state.applyEvaluationIntent(.seek(target))
        #expect(state.acknowledgedPausedSeekTime == nil)
        #expect(state.currentTime == 0.5)
    }

    @Test("Non-finite seek does not retire an existing acknowledgement")
    func heldSeekIgnoresNonFiniteRequest() {
        for target in [Double.nan, Double.infinity, -Double.infinity] {
            var state = snapshot(UUID(), time: 0.25)
            state.acknowledgedPausedSeekTime = 0.25
            state.decoderCurrentTime = 0.5
            state.applyEvaluationIntent(.seek(target))
            #expect(state.acknowledgedPausedSeekTime == 0.25)
            #expect(state.currentTime == 0.25)
        }
    }

    @Test("Cold, policy-paused and unqualified seeks retain existing readback")
    func unqualifiedSeekReadback() {
        let generation = UUID()
        for target in [Double.nan, -Double.infinity, -0.25, 0, 2, 3] {
            var state = snapshot(generation)
            state.applyEvaluationIntent(.seek(target))
            #expect(state.currentTime == 1.5)
            #expect(state.acknowledgedPausedSeekTime == nil)
        }
        var cold = WPEVideoPlaybackSnapshot(sourceGeneration: generation, currentTime: 0,
                                            duration: 2, isPlaying: false, rate: 1, loop: true, hasPresentedFrame: false)
        cold.applyEvaluationIntent(.seek(0.25))
        #expect(cold.currentTime == 0)
        #expect(cold.acknowledgedPausedSeekTime == nil)
        var policyPaused = snapshot(generation)
        policyPaused.playbackRequested = true
        policyPaused.applyEvaluationIntent(.seek(0.25))
        #expect(policyPaused.currentTime == 1.5)
        #expect(policyPaused.acknowledgedPausedSeekTime == nil)
    }

    @Test("Same-source aliases share immediate intent without inventing seek readback")
    func aliasIntent() throws {
        let generation = UUID()
        let shared = WPESharedScriptState(layers: [layer("a", "A"), layer("b", "B", index: 1)])
        shared.publishVideoPlayback(["a": snapshot(generation), "b": snapshot(generation)],
                                    sourceKeys: ["a": "video.tex", "b": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            const a = thisLayer.getVideoTexture();
            const b = thisScene.getLayer('B').getVideoTexture();
            a.play(); b.rate = 0.5; b.loop = false; a.setCurrentTime(0.25);
            shared.time = b.getCurrentTime(); shared.playing = b.isPlaying();
            shared.rate = a.rate; shared.loop = a.loop;
        }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(shared.get("time") as? Double == 1.5)
        #expect(shared.get("playing") as? Bool == true)
        #expect(shared.get("rate") as? Double == 0.5)
        #expect(shared.get("loop") as? Double == 0)
        #expect(instance.initialOutput.own.videoCommands == [
            .play, .seek(0.25),
        ])
        #expect(instance.initialOutput.others["B"]?.videoCommands == [
            .setRate(0.5), .setLoop(false),
        ])
    }

    @MainActor
    @Test("Interleaved commands on same-source handles commit in call order", arguments: [
        "a.rate = 0.5; b.rate = 2; a.rate = 1;",
        "a.play(); b.pause(); a.play();",
    ])
    func interleavedAliasesCommitInCallOrder(_ body: String) throws {
        let generation = UUID()
        let shared = WPESharedScriptState(layers: [layer("a", "A"), layer("b", "B", index: 1)])
        shared.publishVideoPlayback(["a": snapshot(generation), "b": snapshot(generation)],
                                    sourceKeys: ["a": "video.tex", "b": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            const a = thisLayer.getVideoTexture();
            const b = thisScene.getLayer('B').getVideoTexture();
            \(body)
            shared.rate = a.rate; shared.playing = a.isPlaying();
        }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        renderer.layerObjectIDByName["B"] = "b"
        renderer.beginSceneScriptVideoCommands()
        renderer.applyLayerScriptOutput(instance.initialOutput, ownObjectID: "a")
        var committed = snapshot(generation)
        for buffered in renderer.sceneScriptVideoCommandBuffer.pending {
            committed.applyEvaluationIntent(buffered.command)
        }
        renderer.discardSceneScriptVideoCommands()
        #expect(committed.rate == shared.get("rate") as? Double)
        #expect(committed.isPlaying == shared.get("playing") as? Bool)
    }

    @Test("Stop rewinds local readback; the next evaluation reads the committed source")
    func localStopDoesNotLeak() throws {
        let generation = UUID()
        let shared = WPESharedScriptState(layers: [layer("a", "A")])
        shared.publishVideoPlayback(["a": snapshot(generation)], sourceKeys: ["a": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            const video = thisLayer.getVideoTexture(); video.stop();
            shared.stoppedTime = video.getCurrentTime(); shared.stoppedPlaying = video.isPlaying();
        }
        export function update() { shared.nextTime = thisLayer.getVideoTexture().getCurrentTime(); }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(shared.get("stoppedTime") as? Double == 0)
        #expect(shared.get("stoppedPlaying") as? Bool == false)
        shared.publishVideoPlayback(["a": snapshot(generation, time: 0.04)])
        _ = try #require(instance.tick())
        #expect(shared.get("nextTime") as? Double == 0.04)
    }

    @Test("Commands retain logical object identity across decoder replacement")
    func physicalReplacementDoesNotFilterCommands() throws {
        let shared = WPESharedScriptState(layers: [layer("a", "A")])
        shared.publishVideoPlayback(["a": snapshot(UUID())], sourceKeys: ["a": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
        export function init() { thisLayer.getVideoTexture().play(); }
        export function update() { thisLayer.getVideoTexture().pause(); }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        let initial = instance.initialOutput.own.videoCommands
        shared.publishVideoPlayback(["a": snapshot(UUID())], sourceKeys: ["a": "video.tex"])
        var buffer = WPESceneScriptVideoCommandBuffer()
        buffer.begin()
        buffer.enqueue(initial, objectID: "a")
        #expect(buffer.finish(commit: true).map(\.command) == [.play])
        #expect(try #require(instance.tick()).own.videoCommands == [.pause])
    }

    @Test("Missing decoder readback does not discard valid handle commands")
    func missingDecoderStillCollectsCommands() throws {
        let shared = WPESharedScriptState(layers: [layer("a", "A")])
        shared.publishVideoPlayback([:], sourceKeys: ["a": "video.tex"])
        let instance = try WPELayerScriptInstance(script: """
        export function init() {
            const video = thisLayer.getVideoTexture();
            shared.unavailable = video.getCurrentTime() === undefined;
            video.play(); video.pause(); video.setCurrentTime(0.25);
        }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(shared.get("unavailable") as? Bool == true)
        #expect(instance.initialOutput.own.videoCommands == [.play, .pause, .seek(0.25)])
    }

    @Test("Existing load permission accepts ordinary commands and rejects retired load completion")
    func loadIdentityOwnsCommandAdmission() {
        let loads = WPESceneScriptLoadState()
        let first = loads.begin(generation: 1)
        var buffer = WPESceneScriptVideoCommandBuffer()
        buffer.begin()
        buffer.enqueue([.play, .setRate(0.5)], objectID: "a")
        var committed: [WPELayerVideoCommand] = []
        #expect(loads.withCompletionPermission(for: first) {
            committed = buffer.finish(commit: true).map(\.command)
        })
        #expect(committed == [.play, .setRate(0.5)])
        buffer.begin()
        buffer.enqueue([.pause], objectID: "a")
        _ = loads.begin(generation: 2)
        #expect(!loads.withCompletionPermission(for: first) {
            committed.append(contentsOf: buffer.finish(commit: true).map(\.command))
        })
        #expect(buffer.finish(commit: false).isEmpty)
        #expect(committed == [.play, .setRate(0.5)])
    }

    @Test("Empty and duplicate names resolve by authored object identity")
    func objectIdentity() throws {
        let shared = WPESharedScriptState(layers: [layer("a", ""), layer("b", "", index: 1)])
        shared.publishVideoPlayback(["a": snapshot(UUID(), time: 0.25), "b": snapshot(UUID(), time: 1.5)])
        let instance = try WPELayerScriptInstance(script: """
        export function init() { shared.time = thisLayer.getVideoTexture().getCurrentTime(); }
        """, shared: shared, ownLayerName: "", ownObjectID: "b", governor: WPESceneScriptExecutionGovernor(limit: 1))
        #expect(instance.initialOutput.own.videoCommands.isEmpty)
        #expect(shared.get("time") as? Double == 1.5)
    }

    @Test("Missing and retired sources do not supply fabricated playback")
    func missingSource() throws {
        let shared = WPESharedScriptState(layers: [layer("a", "A")])
        shared.publishVideoPlayback(["a": snapshot(UUID())])
        let instance = try WPELayerScriptInstance(script: """
        export function update() {
            const video = thisLayer.getVideoTexture();
            shared.missing = video.getCurrentTime() === undefined && video.duration === undefined && video.isPlaying() === undefined;
        }
        """, shared: shared, ownLayerName: "A", ownObjectID: "a", governor: WPESceneScriptExecutionGovernor(limit: 1))
        shared.publishVideoPlayback([:])
        _ = try #require(instance.tick())
        #expect(shared.get("missing") as? Bool == true)
    }
}
#endif
