#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Particle playback changes emission without freezing simulation")
struct WPEParticlePlaybackTests {
    @Test func pauseKeepsExistingParticlesMovingAndDoesNotReplayBurstOnResume() throws {
        let system = try makeSystem()
        system.tick(now: 0)
        let identity = try #require(system.primaryLiveParticleIdentity)
        let before = try #require(system.snapshot(for: identity))
        #expect(system.liveInstanceCount == 4)
        system.applyPlaybackCommand(.pause)
        system.tick(now: 1.0 / 60)
        let paused = try #require(system.snapshot(for: identity))
        #expect(system.liveInstanceCount == 4)
        #expect(paused.age > before.age && paused.position.x > before.position.x)
        #expect(!system.playbackSnapshot.isEmitting && system.playbackSnapshot.isPlaying)
        system.applyPlaybackCommand(.play)
        system.tick(now: 2.0 / 60)
        #expect(system.liveInstanceCount == 4)
        #expect(system.snapshot(for: identity) != nil)
        for frame in 3 ... 8 {
            system.tick(now: Double(frame) / 60)
        }
        #expect(system.liveInstanceCount == 7)
    }

    @Test func stopClearsIdentityAndForcedEmissionRunsWhileAutomaticEmissionStaysStopped() throws {
        let system = try makeSystem()
        system.beginRecordingParticleEvents()
        system.tick(now: 0)
        let identity = try #require(system.primaryLiveParticleIdentity)
        system.applyPlaybackCommand(.stop)
        #expect(system.snapshot(for: identity) == nil)
        #expect(!system.playbackSnapshot.isPlaying && system.isPermanentlyIdle)
        system.applyPlaybackCommand(.emit(3))
        #expect(!system.isPermanentlyIdle)
        system.tick(now: 1.0 / 60)
        #expect(system.liveInstanceCount == 3)
        #expect(system.particleEventsThisTick.filter { $0.kind == .spawn }.count == 3)
        #expect(!system.playbackSnapshot.isEmitting && system.playbackSnapshot.isPlaying)
        system.tick(now: 2.0 / 60)
        #expect(system.liveInstanceCount == 3)
    }

    @Test func playingAfterStopRestartsAuthoredBurstWithFreshIdentities() throws {
        let system = try makeSystem()
        system.tick(now: 0)
        let prior = try #require(system.primaryLiveParticleIdentity)
        system.applyPlaybackCommand(.stop)
        system.applyPlaybackCommand(.play)
        system.tick(now: 1)
        #expect(system.liveInstanceCount == 4)
        #expect(system.primaryLiveParticleIdentity != prior)
        #expect(system.playbackSnapshot.isEmitting)
    }

    @Test func pausedParticlesExpireAndPlaybackReadbackBecomesIdle() throws {
        let system = try makeSystem(lifetime: 0.05)
        system.tick(now: 0)
        system.applyPlaybackCommand(.pause)
        system.tick(now: 0.1)
        #expect(system.liveInstanceCount == 0)
        #expect(!system.playbackSnapshot.isPlaying)
        #expect(system.isPermanentlyIdle)
    }

    @Test func explicitBirthsAreBoundedAndStoppingCancelsUnconsumedCommands() throws {
        let system = try makeSystem()
        system.applyPlaybackCommand(.pause)
        for _ in 0 ..< 10 {
            system.applyPlaybackCommand(.emit(Int.max))
        }
        system.tick(now: 0)
        #expect(system.liveInstanceCount == system.capacity)
        system.applyPlaybackCommand(.emit(3))
        system.applyPlaybackCommand(.stop)
        system.tick(now: 0.01)
        #expect(system.liveInstanceCount == 0)
        #expect(!system.playbackSnapshot.isPlaying)
    }

    @Test func restartingDoesNotTurnCompletedPresimulationIntoAnEmissionDelay() throws {
        let system = try makeSystem(startDelay: 2)
        system.prewarm(simulatedSeconds: 2, presimulateDelay: true)
        system.tick(now: 0)
        #expect(system.liveInstanceCount > 0)
        system.applyPlaybackCommand(.stop)
        system.applyPlaybackCommand(.play)
        system.tick(now: 0.01)
        #expect(system.liveInstanceCount == 4)
    }

    @Test func rendererRoutesCommittedCommandsToOnlyTheOwningObjectsSystems() throws {
        let root = try makeSystem()
        let child = try makeSystem()
        let unrelated = try makeSystem()
        root.scriptParticleObjectID = "snow"
        child.scriptParticleObjectID = "snow"
        unrelated.scriptParticleObjectID = "stars"
        for system in [root, child, unrelated] {
            system.tick(now: 0)
        }
        WPEMetalSceneRenderer.applyParticlePlaybackCommands([.init(objectID: "snow", command: .stop)],
                                                            systems: [root, child, unrelated])
        #expect(root.liveInstanceCount == 0 && child.liveInstanceCount == 0)
        #expect(unrelated.liveInstanceCount == 4)
        let token = WPESceneScriptInstanceLimitToken(generation: 1)
        token.failClosed(.executionTimedOut(operation: .tick))
        #expect(!token.withCompletionPermission {
            WPEMetalSceneRenderer.applyParticlePlaybackCommands([.init(objectID: "stars", command: .stop)],
                                                                systems: [root, child, unrelated])
        })
        #expect(unrelated.liveInstanceCount == 4)
    }

    private func makeSystem(lifetime: Double = 10, startDelay: Double = 0) throws -> WPEParticleSystem {
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 16, "starttime": startDelay,
            "emitter": [["name": "boxrandom", "rate": 60, "instantaneous": 4]],
            "initializer": [["name": "lifetimerandom", "min": lifetime, "max": lifetime],
                            ["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]],
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try #require(WPEParticleSystem(definition: definition, device: device, seed: 71))
    }
}
#endif
