import Foundation
import LiveWallpaperCore

@MainActor
extension ScreenManager {
    func setupMemoryPressureMonitoring() {
        memoryPressureWatcher.start { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating else { return }
                // Unstructured MainActor hops are not FIFO: applying the level
                // this callback captured lets a late `critical` land after the
                // `normal` that cleared it and re-arm the hibernate retry
                // cadence for an emergency that is already over. Read the live
                // level instead, which is latest-wins by construction.
                self.applyMemoryPressureLevel(self.memoryPressureWatcher.currentLevel())
            }
        }
        applyMemoryPressureLevel(memoryPressureWatcher.currentLevel())
    }

    private func applyMemoryPressureLevel(_ level: SystemMemoryPressureLevel) {
        guard !isTerminating else { return }
        setMemoryPressure(level != .normal)
        #if !LITE_BUILD
        // Critical pressure skips the hibernate dwell: the refresh above has
        // already suspended every session, so release scene renderer resources
        // now instead of waiting out a countdown the system may not survive.
        // Pushed on EVERY level change, not just the critical edge — the
        // session's retry cadence has to be revoked when the pressure clears.
        let isCritical = level == .critical
        for screen in screens {
            (screen.runtimeSession as? SceneWallpaperSession)?
                .setCriticalMemoryPressureActive(isCritical)
        }
        #endif
    }

    /// Suspends all wallpaper types while memory pressure holds without changing
    /// the user's play/pause intent, then restores the prior policy when it clears.
    private func setMemoryPressure(_ active: Bool) {
        guard isUnderMemoryPressure != active else { return }
        isUnderMemoryPressure = active
        Logger.notice(
            active ? "Memory pressure: suspending wallpapers" : "Memory pressure cleared: restoring wallpapers",
            category: .memory
        )
        refreshPerformancePolicyForAllScreens()
    }
}
