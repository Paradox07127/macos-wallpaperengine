#if !LITE_BUILD
import Foundation

extension WPEMetalSceneRenderer {
    nonisolated static func applyParticlePlaybackCommands(
        _ commands: [WPESceneScriptParticleCommand], systems: [WPEParticleSystem]
    ) {
        for buffered in commands {
            for system in systems where system.scriptParticleObjectID == buffered.objectID {
                if case let .emit(count) = buffered.command, let values = buffered.emissionValues {
                    system.requestEmission(count, values: values)
                } else {
                    system.applyPlaybackCommand(buffered.command)
                }
            }
        }
    }

    func synchronizeParticleInstanceBindings() {
        guard let coordinator = particleInstanceCoordinator else { return }
        guard synchronizedParticleCoordinator !== coordinator
            || synchronizedParticleBindingRevision != coordinator.bindingRevision else { return }
        let bindings = coordinator.bindings
        particleSystems = particleIndependentSystems + bindings.map(\.system)
        particleTextures.removeAll(keepingCapacity: true)
        particleNormalTextures.removeAll(keepingCapacity: true)
        for system in particleIndependentSystems {
            let id = ObjectIdentifier(system)
            particleTextures[id] = particleTemplateTextures[id]
            particleNormalTextures[id] = particleTemplateNormals[id]
        }
        for binding in bindings {
            let id = ObjectIdentifier(binding.system)
            let prototypeID = ObjectIdentifier(binding.prototype)
            particleTextures[id] = particleTemplateTextures[prototypeID]
            particleNormalTextures[id] = particleTemplateNormals[prototypeID]
        }
        synchronizedParticleCoordinator = coordinator
        synchronizedParticleBindingRevision = coordinator.bindingRevision
    }

    func publishParticlePlaybackSnapshots() {
        var snapshots: [String: WPEParticlePlaybackSnapshot] = [:]
        var instanceValues: [String: WPEParticleInstanceValues] = [:]
        for system in particleSystems {
            guard let id = system.scriptParticleObjectID else { continue }
            if instanceValues[id] == nil {
                instanceValues[id] = system.instanceValues
            }
            let value = system.playbackSnapshot
            let prior = snapshots[id]
            snapshots[id] = .init(liveParticleCount: (prior?.liveParticleCount ?? 0) + value.liveParticleCount,
                                  isEmitting: (prior?.isEmitting ?? false) || value.isEmitting)
        }
        sceneScriptSharedState?.publishParticlePlayback(snapshots)
        sceneScriptSharedState?.publishParticleInstanceValues(instanceValues)
    }
}
#endif
