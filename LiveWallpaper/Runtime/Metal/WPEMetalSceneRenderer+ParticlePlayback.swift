#if !LITE_BUILD
import Foundation

extension WPEMetalSceneRenderer {
    nonisolated static func applyParticlePlaybackCommands(
        _ commands: [WPESceneScriptParticleCommand], systems: [WPEParticleSystem]
    ) {
        for buffered in commands {
            for system in systems where system.scriptParticleObjectID == buffered.objectID {
                system.applyPlaybackCommand(buffered.command)
            }
        }
    }

    func publishParticlePlaybackSnapshots() {
        var snapshots: [String: WPEParticlePlaybackSnapshot] = [:]
        for system in particleSystems {
            guard let id = system.scriptParticleObjectID else { continue }
            let value = system.playbackSnapshot
            let prior = snapshots[id]
            snapshots[id] = .init(liveParticleCount: (prior?.liveParticleCount ?? 0) + value.liveParticleCount,
                                  isEmitting: (prior?.isEmitting ?? false) || value.isEmitting)
        }
        sceneScriptSharedState?.publishParticlePlayback(snapshots)
    }
}
#endif
