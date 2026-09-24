import LiveWallpaperCore

extension ScreenManager: UndoRestoring {
    func restoreRecordedConfiguration(
        _ configuration: ScreenConfiguration, overlay: MonitorOverlayConfiguration?, on screen: Screen
    ) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        restoreWallpaperSession(
            for: screen,
            configuration: configuration,
            preservingState: false,
            intent: .proposal,
            beforeCommit: { [weak self] in
                guard let self else { return false }
                saveConfiguration(configuration)
                if let overlay {
                    setMonitorOverlay(overlay, for: screen)
                }
                return true
            }
        )
    }

    func automaticSwitchMark(for fingerprint: String) -> AutomaticSwitchMark? {
        automaticSwitchMarks[fingerprint]
    }

    func noteAutomaticSwitch(on screen: Screen, source: AutomaticSwitchMark.Source) {
        let serial = (automaticSwitchMarks[screen.displayFingerprint]?.serial ?? 0) + 1
        automaticSwitchMarks[screen.displayFingerprint] = AutomaticSwitchMark(serial: serial, source: source)
    }
}
