#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import Metal

/// Builds the renderer report shown by the scene inspector without making the
/// SwiftUI view own renderer diagnostics, system inventory, or defaults keys.
@MainActor
enum WPERenderDiagnosticReport {
    static func make(
        descriptor: SceneDescriptor,
        diagnostics: SceneRendererDiagnostics?,
        errorCode: String?,
        environmentLines: [String] = WPERenderDiagnosticEnvironment.lines()
    ) -> String {
        var lines: [String] = [
            "Capability: \(descriptor.capabilityTier.localizedLabel)"
        ]
        if let preflight = descriptor.preflightTier,
           preflight != .nativePlayable {
            lines.append("Preflight: \(preflight.localizedLabel)")
        }
        if !descriptor.preflightFeatureFlags.isEmpty {
            lines.append(
                "Features: \(descriptor.preflightFeatureFlags.map(\.rawValue).joined(separator: ", "))"
            )
        }
        if let errorCode {
            lines.append("Error code: \(errorCode)")
        }
        lines.append("")

        let loadDiagnostic = diagnostics?.loadDiagnostics?.errorDescription
        let snapshot = diagnostics?.resolution

        if let loadDiagnostic {
            lines.append(loadDiagnostic)
        }

        if let snapshot {
            if loadDiagnostic == nil {
                lines.append(
                    snapshot.missedRefs.isEmpty
                        ? "All declared refs resolved (\(snapshot.resolvedCount))."
                        : "\(snapshot.missedRefs.count) ref(s) unresolved, \(snapshot.resolvedCount) resolved."
                )
            }
            lines.append("")
            lines.append("Resource Resolution")
            lines.append(resolutionSummaryText(snapshot))
            if snapshot.missedRefs.isEmpty {
                lines.append("Misses: none")
            } else {
                lines.append("Misses:")
                for event in snapshot.missedRefs.prefix(500) {
                    lines.append("  \(event.ref): \(event.finalOutcome.debugLabel)")
                }
            }
            let fallback = fallbackResolvedRefs(snapshot)
            if !fallback.isEmpty {
                lines.append("Resolved via fallback (not in scene package):")
                for entry in fallback.prefix(40) {
                    lines.append("  \(entry.ref) <- \(entry.origin)")
                }
            }
        } else if loadDiagnostic == nil {
            lines.append("No render diagnostics yet (scene not loaded).")
        }

        if let shaders = diagnostics?.shaderErrors, shaders.count > 0 {
            lines.append("")
            lines.append(
                "Shader compile failures: \(shaders.count) (pass skipped — effect not drawn)"
            )
            for entry in shaders.entries.prefix(20) {
                lines.append("  \(entry.shader): \(entry.reason)")
            }
        }

        if let gpu = diagnostics?.gpuErrors, gpu.count > 0 {
            lines.append("")
            lines.append(
                "GPU errors: \(gpu.count)"
                    + (gpu.last.map { " (last: \($0))" } ?? "")
            )
        }

        lines.append("")
        lines.append(contentsOf: environmentLines)
        return PIISanitizer.scrub(lines.joined(separator: "\n"))
    }

    private static func resolutionSummaryText(
        _ snapshot: WPEResolutionDiagnosticsSnapshot
    ) -> String {
        let counts = snapshot.resolvedByOrigin
        let dependencyCount = counts.reduce(0) { partial, entry in
            if case .dependency = entry.key {
                return partial + entry.value
            }
            return partial
        }
        var parts = [
            "scene: \(counts[.scene, default: 0])",
            "builtin: \(counts[.builtin, default: 0])",
            "engineAssets: \(counts[.engineAssets, default: 0])"
        ]
        if dependencyCount > 0 {
            parts.append("dependency: \(dependencyCount)")
        }
        return "Events: \(snapshot.events.count), resolved: \(snapshot.resolvedCount), \(parts.joined(separator: ", "))"
    }

    private static func fallbackResolvedRefs(
        _ snapshot: WPEResolutionDiagnosticsSnapshot
    ) -> [(ref: String, origin: String)] {
        var seen = Set<String>()
        var result: [(ref: String, origin: String)] = []
        for event in snapshot.events {
            guard event.finalOutcome == .resolved,
                  let hit = event.attempts.last,
                  hit.outcome == .resolved,
                  hit.origin != .scene,
                  seen.insert(event.ref).inserted else {
                continue
            }
            result.append((event.ref, hit.origin.debugLabel))
        }
        return result
    }
}

/// System and renderer-flag inventory appended to diagnostic reports.
///
/// Keeping this outside the View makes the defaults registry reusable and
/// keeps Metal/UserDefaults discovery out of SwiftUI compilation.
@MainActor
enum WPERenderDiagnosticEnvironment {
    nonisolated static let renderFlagKeys = [
        "WPEMetalMemorylessDepthEnabled",
        "WPEMetalMipChainEnabled",
        "WPEMetalSerializeFrames",
        "WPEMetalPerspectiveNativeResolution",
        "WPEMetalSceneBloomEnabled",
        "WPEMetalStaticLayerCacheEnabled",
        "WPEMetalStaticLayerCacheBudgetMiB",
        "WPEMetalTextureCacheBudgetMiB",
        "WPEMetalIntroPhaseAlignEnabled",
        "WPEParallaxGain",
        "WPEParticlePrewarmEnabled",
        "WPEPuppetAttachmentBindAnchor",
        "WPEPuppetClipComposite",
        "WPEPuppetDeferMeshWarp"
    ]

    static func lines() -> [String] {
        var lines: [String] = ["Environment"]
        let bundle = Bundle.main
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        lines.append(
            "App \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        if let gpu = MTLCreateSystemDefaultDevice()?.name {
            lines.append("GPU: \(gpu)")
        }
        let screens = NSScreen.screens.map {
            "\(Int($0.frame.width))×\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x"
        }
        lines.append(
            "Displays: \(screens.count) [\(screens.joined(separator: ", "))]"
        )
        let flags = nonDefaultRenderFlags()
        if !flags.isEmpty {
            lines.append("Flags: \(flags.joined(separator: ", "))")
        }
        return lines
    }

    private static func nonDefaultRenderFlags() -> [String] {
        let defaults = UserDefaults.standard
        var flags = renderFlagKeys.compactMap { key -> String? in
            guard let value = defaults.object(forKey: key) else { return nil }
            return "\(key.dropFirst(3))=\(value)"
        }
        let effectiveBudget = WPEMetalSceneRenderer.textureCacheBudgetBytes
            .map { "\($0 / 1_048_576)MiB" } ?? "unbounded"
        flags.append(
            "MemoryTier=\(WPEMemoryTier.current) textureBudget=\(effectiveBudget)"
        )
        return flags
    }
}
#endif
