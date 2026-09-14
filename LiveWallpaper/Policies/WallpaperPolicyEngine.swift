import Foundation
import LiveWallpaperCore

struct WallpaperPolicyInputs {
    var powerSource: PowerMonitor.PowerSource
    var isHiddenByFullScreen: Bool
    var isWindowOccluding: Bool
    var isApplicationRuleActive: Bool
    var thermalState: ProcessInfo.ThermalState
    var isUserAbsent: Bool
    /// Graded, not boolean: `warning` throttles while `critical` suspends.
    var memoryPressureLevel: SystemMemoryPressureLevel
    var isLowPowerMode: Bool = false
    /// Vetoes discretionary suspension without overriding safety suspension.
    var isFrontmostExcludedByRule: Bool = false
    /// Video has no throttle knob; a thermal throttle is escalated to the suspend that shipped before the throttle tier existed.
    var respondsToThermalThrottle: Bool = true
}

enum WallpaperPolicyEngine {
    static func performanceProfile(
        inputs: WallpaperPolicyInputs,
        settings: GlobalSettings
    ) -> WallpaperPerformanceProfile {
        decision(inputs: inputs, settings: settings).profile
    }

    static func decision(
        inputs: WallpaperPolicyInputs,
        settings: GlobalSettings
    ) -> WallpaperPolicyDecision {
        var safety: Set<WallpaperSuspendReason> = []
        if inputs.isUserAbsent { safety.insert(.userAbsent) }
        if shouldSuspendForMemory(inputs.memoryPressureLevel) { safety.insert(.memoryPressure) }
        if shouldSuspendForThermal(inputs.thermalState)
            || (!inputs.respondsToThermalThrottle && shouldThrottleForThermal(inputs.thermalState)) {
            safety.insert(.thermal)
        }

        var discretionary: Set<WallpaperSuspendReason> = []
        if inputs.isApplicationRuleActive { discretionary.insert(.applicationRule) }
        if settings.pauseInLowPowerMode, inputs.isLowPowerMode { discretionary.insert(.lowPowerMode) }
        if shouldPauseForPower(globalSettings: settings, powerSource: inputs.powerSource) {
            discretionary.insert(.battery)
        }
        if shouldApplyFullScreenPolicy(globalSettings: settings, isHiddenByFullScreen: inputs.isHiddenByFullScreen) {
            discretionary.insert(.fullScreen)
        }
        if shouldApplyWindowOcclusionPolicy(globalSettings: settings, isWindowOccluding: inputs.isWindowOccluding) {
            discretionary.insert(.windowOcclusion)
        }
        if inputs.isFrontmostExcludedByRule { discretionary.removeAll() }

        var throttle: Set<WallpaperSuspendReason> = []
        if shouldThrottleForThermal(inputs.thermalState) { throttle.insert(.thermal) }
        if shouldThrottleForMemory(inputs.memoryPressureLevel) { throttle.insert(.memoryPressure) }

        let suspendReasons = safety.union(discretionary)
        guard suspendReasons.isEmpty else {
            return WallpaperPolicyDecision(profile: .suspended, suspendReasons: suspendReasons)
        }
        return WallpaperPolicyDecision(profile: .quality, throttleReasons: throttle)
    }

    /// Only critical suspends; serious would stop wallpapers in ordinary use.
    private static func shouldSuspendForThermal(_ thermalState: ProcessInfo.ThermalState) -> Bool {
        switch thermalState {
        case .critical:
            return true
        case .serious, .fair, .nominal:
            return false
        @unknown default:
            return true
        }
    }

    private static func shouldThrottleForThermal(_ thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState == .serious
    }

    /// Only `critical` suspends. `warning` is routine on a loaded Mac, and the
    /// byte caches already shrink themselves under it.
    private static func shouldSuspendForMemory(_ level: SystemMemoryPressureLevel) -> Bool {
        level == .critical
    }

    private static func shouldThrottleForMemory(_ level: SystemMemoryPressureLevel) -> Bool {
        level == .warning
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
