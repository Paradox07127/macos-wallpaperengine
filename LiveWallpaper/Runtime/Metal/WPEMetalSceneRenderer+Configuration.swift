#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

extension WPEMetalSceneRenderer {
    /// Default frame rate target when no user override applied. 30 FPS matches Wallpaper
    /// Engine's stock default (Windows app's "Balanced" preset defaults to 30) — most
    /// published WPE shaders are tuned around a 30 FPS clock, so 60 made their
    /// `g_Time`-driven motion look ≈2× too fast. `MTKView` clamps this to the display's refresh rate.
    static let defaultPreferredFPS = 30
    /// Perspective scenes render at the drawable resolution (capped 4K) instead
    /// of the fixed 1080 fallback, so HUD text is crisp. Default ON; disable with
    /// `defaults write com.loomscreen.pro WPEMetalPerspectiveNativeResolution -bool NO`.
    static let perspectiveNativeResolutionEnabled: Bool =
        (UserDefaults.standard.object(forKey: "WPEMetalPerspectiveNativeResolution") as? Bool) ?? true
    /// Floor for the adaptive "background" throttle — never drop a still-visible
    /// wallpaper below this even when occluded/on battery (15 FPS measured at
    /// ~83 mW vs ~330 mW at 60, a ~75% GPU-power cut, while staying watchable).
    static let adaptiveThrottleFloorFPS = 15
    /// `.unlimited` means "run at the display's configured ceiling" — it locks to the
    /// screen setting's upper limit, never free-runs past vsync
    /// (`setPreferredFramesPerSecond(0)` is read as "as fast as possible" on some macOS
    /// versions). Derived from the fastest attached display; each display's pacing layer
    /// clamps to its own setting, so over-asking a slower screen is harmless.
    /// Note the energy consequence, measured 2026-09-01: a 136 Hz panel really does
    /// render 136 fps here, ≈ +34pp process CPU versus a 60 ceiling. That is the
    /// intended meaning of "unlimited"; users who want the power back pick an explicit
    /// ceiling in Settings.
    static var unlimitedPreferredFPS: Int {
        unlimitedPreferredFPS(
            fastestDisplayFPS: NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 0
        )
    }

    static func unlimitedPreferredFPS(fastestDisplayFPS: Int) -> Int {
        fastestDisplayFPS > 0 ? fastestDisplayFPS : 60
    }
    /// Above this raw-bytes footprint, eager-upload of a multi-frame `.tex` would burn far
    /// more VRAM than the runtime needs at any moment — route through
    /// `WPETexLazyAnimatedTextureSource` instead. Chosen to keep small (≤2-3 frame) workshop
    /// sprite-sheets on the fast eager path while sending workshop 3725117707-class assets
    /// (60 × 122 MB raw) to the streaming source; tiered by physical RAM (halved on 8 GB machines, see `WPEMemoryTier`).
    static let lazyAnimationRawByteThreshold = WPEMemoryTier.current.lazyAnimationRawByteThreshold

    static let textureCacheBudgetMiBDefaultsKey = "WPEMetalTextureCacheBudgetMiB"
    /// VRAM budget for reloadable static source textures. Unset ⇒ the machine's memory-tier
    /// default (every tier bounded, see `WPEMemoryTier`); 0 or negative ⇒ unbounded
    /// (manual opt-out); positive ⇒ that many MiB. Over-budget inactive (hidden-layer)
    /// textures are LRU-evicted and reloaded on demand. Snapshot per scene load, so
    /// `defaults write com.loomscreen.pro WPEMetalTextureCacheBudgetMiB -int 256` applies on the next (re)load.
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
        return mib * 1_048_576
    }

    /// When true, emitters with no authored start offset are also pre-populated
    /// to their steady-state spread on load. Emitters with `starttime > 0`
    /// always prewarm because WPE authors use that field as an initial simulation
    /// offset for already-populated first frames.
    static var particlePrewarmEnabled: Bool {
        UserDefaults.standard.bool(forKey: "WPEParticlePrewarmEnabled")
    }

    nonisolated static func particlePrewarmSeconds(
        for definition: WPEParticleDefinition,
        manualPrewarmEnabled: Bool,
        oracleReplaySeconds: Double? = nil
    ) -> Double? {
        guard definition.rate > 0 || definition.instantaneousCount > 0 else { return nil }
        // Oracle capture renders ONE frame on a frozen clock, so `dt` is 0 and
        // `spawnAccumulator += dt * rate` never fires: a `starttime: 0` emitter shows 0
        // alive while WPE (running for real) shows rate x elapsed (2955378002: 273 alive =
        // 40/s x the 6.845s replay time). Simulating to the replay instant is what makes the
        // two frames comparable; the steady-state heuristic below would land on a different count.
        if let oracleReplaySeconds, oracleReplaySeconds > 0 {
            // `starttime` PRE-SIMULATES, so at frame time T the system has been
            // running for `starttime + T` — WPE docs, corroborated by RenderDoc
            // (3448877775 snowperspective: starttime 15, T 4.851s, 344 alive;
            // dead-zoning the 15s predicts 121). Caller must pass
            // `presimulateDelay: true` so `prewarm` does not re-subtract it.
            let authoredStart = max(0, definition.startDelay)
            return min(authoredStart + oracleReplaySeconds, Self.maxPrewarmSeconds)
        }
        let authoredStart = max(0, definition.startDelay)
        // `starttime` PRE-SIMULATES rather than delaying, so at load the system has already
        // been running for exactly that long — no steady-state padding on top. Same
        // semantics the oracle branch above uses, RenderDoc-corroborated; the live path used
        // to add an extra 2–15s of emission and dead-zone the offset instead, matching WPE at neither end.
        if authoredStart > 0 {
            return min(authoredStart, Self.maxPrewarmSeconds)
        }
        // No authored offset: the manual developer flag still pre-populates to a
        // steady-state spread. That is ours, not WPE's, so it keeps its own shape.
        guard manualPrewarmEnabled else { return nil }
        return min(max(definition.lifetimeMax, 2.0), 15.0)
    }

    /// `prewarm` substeps at 1/60s, so this is also a loop bound: 120s = 7200
    /// iterations per system, which a 273-system scene still runs in seconds.
    /// Oracle captures beyond this clamp are no longer count-exact; live scenes
    /// beyond it load slightly less full than WPE.
    nonisolated static let maxPrewarmSeconds: Double = 120

    /// Slave a revealed loop video's playhead to lead its intro overlay by the
    /// measured phase offset (seamless intro→loop). Default on; `-bool NO` disables.
    static var introPhaseAlignEnabled: Bool {
        UserDefaults.standard.object(forKey: "WPEMetalIntroPhaseAlignEnabled") as? Bool ?? true
    }

}
#endif
