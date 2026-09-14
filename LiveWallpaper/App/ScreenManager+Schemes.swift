import Foundation
import LiveWallpaperCore

extension ScreenManager {
    /// Snapshots a display's whole setup — wallpaper configuration plus both
    /// overlay layers — into the local scheme archive. Nil when the screen has
    /// no stored configuration to capture.
    @discardableResult
    func captureScheme(from screen: Screen, name: String) -> ScreenScheme? {
        guard !isTerminating,
              let configuration = configurationStore.get(
                  for: screen.id,
                  fingerprint: screen.displayFingerprint
              ) else { return nil }

        let scheme = SchemeStore.shared.add(
            name: name,
            configuration: configuration,
            overlay: monitorOverlay(for: screen),
            sourceDisplayName: screen.name
        )
        captureCover(forScheme: scheme.id, from: screen)
        Logger.info(
            "Capture Scheme: captured screen \(screen.id) as scheme \(scheme.id)",
            category: .screenManager
        )
        return scheme
    }

    /// Overwrites an existing scheme with what `screen` is showing now. The
    /// reverse of `applyScheme`, and deliberately targets one named slot: a
    /// display can hold several schemes.
    @discardableResult
    func recaptureScheme(_ scheme: ScreenScheme, from screen: Screen) -> ScreenScheme? {
        guard !isTerminating,
              let configuration = configurationStore.get(
                  for: screen.id,
                  fingerprint: screen.displayFingerprint
              ) else { return nil }

        let replaced = SchemeStore.shared.replace(
            scheme.id,
            configuration: configuration,
            overlay: monitorOverlay(for: screen),
            sourceDisplayName: screen.name
        )
        if replaced != nil {
            captureCover(forScheme: scheme.id, from: screen)
        }
        Logger.info(
            "Replace Scheme: re-captured screen \(screen.id) over scheme \(scheme.id)",
            category: .screenManager
        )
        return replaced
    }

    /// Whole-screen overwrite: wallpaper content, every per-screen setting, and
    /// both overlay layers. Widget and Now Playing positions are stored
    /// normalized (0…1) and turned into pixels at render time, so a scheme
    /// captured on one panel lands correctly on a differently sized one without
    /// any coordinate conversion here.
    /// The overlay is written inside `beforeCommit`, not after the call: that
    /// closure runs only when the prepared wallpaper session actually commits.
    /// Applying it unconditionally left a half-applied screen whenever the
    /// scheme's media had moved or its security-scoped grant had gone stale —
    /// the wallpaper stayed as it was while the overlay was replaced anyway.
    func applyScheme(_ scheme: ScreenScheme, to screen: Screen) {
        guard !isTerminating else { return }

        // Same standing as any other explicit pick: without it a WPE import
        // that is still in flight stays on the current generation and lands on
        // top of the scheme the user just chose.
        beginExplicitWallpaperSelection(for: screen)

        var configuration = scheme.rebound(
            to: screen.id,
            fingerprint: screen.displayFingerprint
        )
        // A scheme lands on one display. Span needs at least two members with
        // the same source, so carrying the captured mode over would leave the
        // config and the UI claiming span while the renderer draws per-display
        // anyway — the same degrade `setVideoDisplayMode` already does when a
        // span is requested with one screen attached.
        if configuration.videoDisplayMode == .spanAllDisplays {
            configuration.videoDisplayMode = .perDisplay
        }
        restoreWallpaperSession(
            for: screen,
            configuration: configuration,
            preservingState: false,
            intent: .proposal,
            beforeCommit: { [weak self] in
                guard let self else { return false }
                saveConfiguration(configuration)
                setMonitorOverlay(scheme.overlay, for: screen)
                Logger.info(
                    "Apply Scheme: applied scheme \(scheme.id) to screen \(screen.id)",
                    category: .screenManager
                )
                return true
            }
        )
    }
}
