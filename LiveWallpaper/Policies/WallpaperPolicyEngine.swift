import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Raw system-state signals consumed by the centralized performance policy.
struct WallpaperPolicyInputs {
    var powerSource: PowerMonitor.PowerSource
    var isHiddenByFullScreen: Bool
    var isWindowOccluding: Bool
    var isApplicationRuleActive: Bool
    var thermalState: ProcessInfo.ThermalState
    var isUserAbsent: Bool
    var isUnderMemoryPressure: Bool
    var isLowPowerMode: Bool = false
    /// Vetoes discretionary suspension without overriding safety suspension.
    var isFrontmostExcludedByRule: Bool = false
}

enum WallpaperPolicyEngine {
    /// Resolves raw signals and user settings into a single performance profile.
    static func performanceProfile(
        inputs: WallpaperPolicyInputs,
        settings: GlobalSettings
    ) -> WallpaperPerformanceProfile {
        // Hard safety suspends (occlusion/memory/thermal); neverPause cannot veto.
        let safetySuspend = inputs.isUserAbsent ||
            inputs.isUnderMemoryPressure ||
            shouldSuspendForThermal(inputs.thermalState)

        // Discretionary suspends yield the GPU for full-screen / battery / Low
        // Power Mode / app rules. A `.neverPause` exception on the frontmost app
        // vetoes them.
        let discretionarySuspend = inputs.isApplicationRuleActive ||
            (settings.pauseInLowPowerMode && inputs.isLowPowerMode) ||
            shouldPauseForPower(globalSettings: settings, powerSource: inputs.powerSource) ||
            shouldApplyFullScreenPolicy(globalSettings: settings, isHiddenByFullScreen: inputs.isHiddenByFullScreen) ||
            shouldApplyWindowOcclusionPolicy(globalSettings: settings, isWindowOccluding: inputs.isWindowOccluding)

        let shouldSuspend = safetySuspend || (discretionarySuspend && !inputs.isFrontmostExcludedByRule)
        return shouldSuspend ? .suspended : .quality
    }

    /// serious/critical → suspend; fair/nominal leave FPS to user caps/ASIC.
    private static func shouldSuspendForThermal(_ thermalState: ProcessInfo.ThermalState) -> Bool {
        switch thermalState {
        case .critical, .serious:
            return true
        case .fair, .nominal:
            return false
        @unknown default:
            return true
        }
    }

    static func shouldPauseForPower(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource
    ) -> Bool {
        powerSource.isOnBattery && globalSettings.globalPauseOnBattery
    }

    static func shouldApplyFullScreenPolicy(
        globalSettings: GlobalSettings,
        isHiddenByFullScreen: Bool
    ) -> Bool {
        globalSettings.pauseOnFullScreen && isHiddenByFullScreen
    }

    static func shouldApplyWindowOcclusionPolicy(
        globalSettings: GlobalSettings,
        isWindowOccluding: Bool
    ) -> Bool {
        globalSettings.pauseOnWindowOcclusion && isWindowOccluding
    }

    static func shouldEnableFullScreenFallbackPolling(
        globalSettings: GlobalSettings,
        hasConfiguredWallpaperSessions: Bool,
        hasConfiguredSceneSessions: Bool
    ) -> Bool {
        // Adaptive FPS poll only when a scene session is live (skip video/HTML-only).
        let coverageRule = (globalSettings.pauseOnFullScreen || globalSettings.pauseOnWindowOcclusion)
            && hasConfiguredWallpaperSessions
        let adaptiveRule = globalSettings.adaptiveFrameRateEnabled && hasConfiguredSceneSessions
        return coverageRule || adaptiveRule
    }
}
