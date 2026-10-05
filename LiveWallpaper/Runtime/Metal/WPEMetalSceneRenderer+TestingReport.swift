#if !LITE_BUILD
import Foundation

extension WPEMetalSceneRenderer {
    /// Called on the display actor during a diagnostic poll, never from a frame callback.
    var sceneTestingSummary: String {
        let passes = renderPipeline?.layers.flatMap(\.passes) ?? []
        var lines = [
            sceneTestingObjectSummary,
            "External engine assets available: \(effectiveEngineAssetsRootURL != nil), dependency mounts: \(dependencyMounts.count)",
            "Prepared layers: \(renderPipeline?.layers.count ?? 0), passes: \(passes.count)",
            "Loaded particle systems (including children): \(particleSystems.count)",
            "Dynamic texture sources: \(dynamicTextureSources.count)",
            "Layer script instances: \(layerScriptInstances.count), sound runtime: \(soundRuntime != nil)",
            "Follow cursor: \(mouseInteractionEnabled), click capture: \(lastPushedClickCaptureEnabled.map(String.init) ?? "unset")",
            "Pointer live: \(previousPointerWasLive), normalized position: \(previousPointer)",
            "Fit: \(presentFitMode), continuous frames: \(needsContinuousFrames), animated shader passes: \(hasAnimatedShaderPasses)",
            "Shader paths (selected implementation; compilation failures are listed separately):",
        ]
        for pass in passes.prefix(80) {
            let path = pass.shader?.executionClassification.rawValue ?? "specialized-or-unclassified"
            let slots = pass.textureBindings.keys.sorted().map(String.init).joined(separator: ",")
            lines.append("  \(pass.pass.shader): \(path), texture slots [\(slots)]")
        }
        if passes.count > 80 {
            lines.append("  [Remaining shader paths omitted]")
        }
        if !sceneTestingMessages.isEmpty {
            lines.append("Parser / skipped-feature diagnostics:")
            lines.append(contentsOf: sceneTestingMessages)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func recordSceneTestingMessage(_ message: String) {
        guard sceneTestingMessages.count < 200, !sceneTestingMessages.contains(message) else { return }
        sceneTestingMessages.append(String(message.prefix(1000)))
    }
}
#endif
