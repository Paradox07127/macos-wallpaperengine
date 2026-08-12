#if !LITE_BUILD
import Foundation
import simd

/// DEBUG-only WPE render-oracle switch: deterministic RNG/clock/hashes for traces.
/// Release/Lite accessors are inert.
enum WPEOracleMode {
    #if DEBUG
    /// Test override for `isEnabled` (avoids a developer's persisted `WPEOracleEnabled`).
    nonisolated(unsafe) static var testingOverride: Bool?

    /// Multi-frame capture clock step; folded into `WPEOracleFrameOverride.time` each read.
    nonisolated(unsafe) static var frameAdvanceSeconds: Double = 0
    #endif

    /// Master toggle, read from the `WPEOracleEnabled` user default.
    static var isEnabled: Bool {
        #if DEBUG
        if let testingOverride { return testingOverride }
        // Test host: ignore persisted WPEOracleEnabled (it freezes clock/RNG in suite).
        if isRunningInTestHost { return false }
        return UserDefaults.standard.bool(forKey: "WPEOracleEnabled")
        #else
        return false
        #endif
    }

    #if DEBUG
    private static let isRunningInTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    #endif

    /// Opt-in per-pass hashes (`WPEOraclePerPassHashes`); off by default (costly).
    static var perPassHashesEnabled: Bool {
        #if DEBUG
        return isEnabled && UserDefaults.standard.bool(forKey: "WPEOraclePerPassHashes")
        #else
        return false
        #endif
    }

    /// Frozen scene time for oracle runs (default 6.0s; `WPEOracleFreezeTime`).
    static var freezeTime: Double {
        #if DEBUG
        if let value = UserDefaults.standard.object(forKey: "WPEOracleFreezeTime") as? Double, value >= 0 {
            return value
        }
        #endif
        return 6.0
    }

    /// Fixed wall-clock input for scripts whose `Date` reads would otherwise make traces nondeterministic.
    static let frozenWallClock: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 6
        comps.hour = 10; comps.minute = 9; comps.second = 8
        return Calendar.current.date(from: comps) ?? Date(timeIntervalSince1970: 1_767_694_148)
    }()

    /// JavaScript epoch milliseconds corresponding to `frozenWallClock`.
    static var frozenWallClockMillis: Double { frozenWallClock.timeIntervalSince1970 * 1000 }

    /// Frozen time/daytime/pointer for oracle captures; fidelity mode uses `WPEOracleReplay*`.
    static func loadFrameOverride() -> WPEOracleFrameOverride? {
        guard isEnabled else { return nil }
        let defaults = UserDefaults.standard
        let time = (defaults.object(forKey: "WPEOracleReplayTime") as? Double) ?? freezeTime
        let daytime = (defaults.object(forKey: "WPEOracleReplayDaytime") as? Double) ?? 0.5
        let pointerX = (defaults.object(forKey: "WPEOracleReplayPointerX") as? Double) ?? 0.5
        let pointerY = (defaults.object(forKey: "WPEOracleReplayPointerY") as? Double) ?? 0.5
        return WPEOracleFrameOverride(
            baseTime: time,
            daytime: min(max(daytime, 0), 1),
            pointer: SIMD2<Double>(pointerX, pointerY)
        )
    }
}

/// Frozen frame globals for a render-oracle capture. Substituted into
/// `WPEMetalRuntimeUniforms` at the top of each frame; see `WPEOracleMode`.
struct WPEOracleFrameOverride: Equatable {
    /// The capture's frozen scene time, before any multi-frame advance.
    var baseTime: Double
    var daytime: Double
    var pointer: SIMD2<Double>

    /// Current frame time = baseTime + frameAdvanceSeconds (override is a stored `let`).
    var time: Double {
        #if DEBUG
        baseTime + WPEOracleMode.frameAdvanceSeconds
        #else
        baseTime
        #endif
    }
}
#endif
