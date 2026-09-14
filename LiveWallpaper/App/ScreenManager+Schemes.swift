import Foundation
import LiveWallpaperCore

extension ScreenManager {
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

    /// Widget and Now Playing positions are stored normalized (0…1) and turned into pixels at render time.
    /// The overlay is written inside beforeCommit, not after: applying it unconditionally would leave a half-applied screen if the scheme's media had moved.
    func applyScheme(_ scheme: ScreenScheme, to screen: Screen) {
        guard !isTerminating else { return }

        // Same standing as any other explicit pick: without it a WPE import still in flight stays on the current generation and lands on top of the scheme the user just chose.
        beginExplicitWallpaperSelection(for: screen)

        var configuration = scheme.rebound(
            to: screen.id,
            fingerprint: screen.displayFingerprint
        )
        // A scheme lands on one display. Carrying the captured mode over would leave the config and the UI claiming span while the renderer draws per-display.
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
