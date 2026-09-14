import Foundation
import LiveWallpaperCore

@MainActor
extension ScreenManager {
    func setupMemoryPressureMonitoring() {
        memoryPressureWatcher.start { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating else { return }
                // Unstructured MainActor hops are not FIFO: applying the captured level lets a late critical land after the normal that cleared it. Read the live level instead.
                self.applyMemoryPressureLevel(self.memoryPressureWatcher.currentLevel())
            }
        }
        applyMemoryPressureLevel(memoryPressureWatcher.currentLevel())
    }

    private func applyMemoryPressureLevel(_ level: SystemMemoryPressureLevel) {
        guard !isTerminating else { return }
        setMemoryPressure(level)
        // Critical pressure skips the hibernate dwell. Push on every level change, not just the critical edge — the session's retry cadence has to be revoked when the pressure clears.
        let isCritical = level == .critical
        for screen in screens {
            (screen.runtimeSession as? WallpaperCriticalMemoryPressureResponding)?
                .setCriticalMemoryPressureActive(isCritical)
        }
    }

    private func setMemoryPressure(_ level: SystemMemoryPressureLevel) {
        guard memoryPressureLevel != level else { return }
        memoryPressureLevel = level
        Logger.notice("Memory pressure level: \(level.rawValue)", category: .memory)
        refreshPerformancePolicyForAllScreens()
    }
}
