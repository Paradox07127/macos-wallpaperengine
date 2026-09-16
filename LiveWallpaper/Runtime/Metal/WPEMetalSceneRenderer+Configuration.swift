#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

extension WPEMetalSceneRenderer {
    /// Default 30 FPS matches Wallpaper Engine's stock default; 60 made `g_Time`-driven motion look ≈2× too fast.
    static let defaultPreferredFPS = 30
    /// Perspective scenes render at the drawable resolution (capped 4K) instead
    /// of the fixed 1080 fallback, so HUD text is crisp. Default ON; disable with
    /// `defaults write com.loomscreen.pro WPEMetalPerspectiveNativeResolution -bool NO`.
    static let perspectiveNativeResolutionEnabled: Bool =
        (UserDefaults.standard.object(forKey: "WPEMetalPerspectiveNativeResolution") as? Bool) ?? true
    /// Floor for the adaptive background throttle — never drop a still-visible wallpaper below this even when occluded/on battery.
    static let adaptiveThrottleFloorFPS = 15
    /// Above this raw-bytes footprint, eager-upload of a multi-frame `.tex` would burn far more VRAM than the runtime needs; route through `WPETexLazyAnimatedTextureSource` instead.
    static let lazyAnimationRawByteThreshold = WPEMemoryTier.current.lazyAnimationRawByteThreshold

    static let textureCacheBudgetMiBDefaultsKey = "WPEMetalTextureCacheBudgetMiB"
    /// Unset ⇒ the machine's memory-tier default; 0 or negative ⇒ unbounded; positive ⇒ that many MiB.
    static var textureCacheBudgetBytes: Int? {
        resolvedTextureCacheBudgetBytes(
            manualValue: UserDefaults.standard.object(forKey: textureCacheBudgetMiBDefaultsKey),
            tier: .current
        )
    }

    static func resolvedTextureCacheBudgetBytes(manualValue: Any?, tier: WPEMemoryTier) -> Int? {
        guard let manualValue else { return tier.defaultTextureCacheBudgetBytes }
        let mib = (manualValue as? NSNumber)?.intValue ?? 0
        guard mib > 0 else { return nil }
        let bytes = mib.multipliedReportingOverflow(by: 1_048_576)
        return bytes.overflow ? nil : bytes.partialValue
    }

    /// When true, emitters with no authored start offset are also pre-populated to their steady-state spread. Emitters with `starttime > 0` always prewarm.
    static var particlePrewarmEnabled: Bool {
        UserDefaults.standard.bool(forKey: "WPEParticlePrewarmEnabled")
    }

    nonisolated static func particlePrewarmSeconds(
        for definition: WPEParticleDefinition,
        manualPrewarmEnabled: Bool,
        oracleReplaySeconds: Double? = nil
    ) -> Double? {
        guard definition.rate > 0 || definition.instantaneousCount > 0 else { return nil }
        // Oracle capture renders ONE frame on a frozen clock, so `dt` is 0 and `spawnAccumulator += dt * rate` never fires.
        if let oracleReplaySeconds, oracleReplaySeconds > 0 {
            // `starttime` PRE-SIMULATES, so at frame time T the system has been running for `starttime + T`. Caller must pass `presimulateDelay: true` so `prewarm` does not re-subtract it.
            let authoredStart = max(0, definition.startDelay)
            return min(authoredStart + oracleReplaySeconds, Self.maxPrewarmSeconds)
        }
        let authoredStart = max(0, definition.startDelay)
        // `starttime` PRE-SIMULATES rather than delaying, so at load the system has already been running for exactly that long — no steady-state padding on top.
        if authoredStart > 0 {
            return min(authoredStart, Self.maxPrewarmSeconds)
        }
        // No authored offset: the manual developer flag still pre-populates to a
        // steady-state spread. That is ours, not WPE's, so it keeps its own shape.
        guard manualPrewarmEnabled else { return nil }
        return min(max(definition.lifetimeMax, 2.0), 15.0)
    }

    /// `prewarm` substeps at 1/60s, so this is also a loop bound: 120s = 7200 iterations per system.
    nonisolated static let maxPrewarmSeconds: Double = 120

    /// Slave a revealed loop video's playhead to lead its intro overlay by the
    /// measured phase offset (seamless intro→loop). Default on; `-bool NO` disables.
    static var introPhaseAlignEnabled: Bool {
        UserDefaults.standard.object(forKey: "WPEMetalIntroPhaseAlignEnabled") as? Bool ?? true
    }

}
#endif
