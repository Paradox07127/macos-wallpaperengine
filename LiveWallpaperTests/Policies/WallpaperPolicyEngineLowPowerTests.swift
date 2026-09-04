import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// macOS Low Power Mode used to suspend wallpapers through
/// `GameModeDetector.evaluate(lowPowerMode:classification:)`, which returned
/// `lowPowerMode || classification == .game`. Deleting game detection took the
/// Low Power Mode term with it. These pin the restored behaviour so it cannot
/// be dropped as collateral again.
@Suite("WallpaperPolicyEngine low power mode")
struct WallpaperPolicyEngineLowPowerTests {

    @Test("Low Power Mode suspends when the setting is on")
    func lowPowerSuspends() {
        let settings = GlobalSettings(pauseInLowPowerMode: true)
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isLowPowerMode: true),
            settings: settings
        )
        #expect(profile == .suspended)
    }

    @Test("Low Power Mode is ignored when the setting is off")
    func lowPowerRespectsOptOut() {
        let settings = GlobalSettings(pauseInLowPowerMode: false)
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isLowPowerMode: true),
            settings: settings
        )
        #expect(profile == .quality)
    }

    @Test("Low Power Mode off leaves the profile alone")
    func lowPowerOffIsQuality() {
        let settings = GlobalSettings(pauseInLowPowerMode: true)
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isLowPowerMode: false),
            settings: settings
        )
        #expect(profile == .quality)
    }

    /// Low Power Mode is discretionary, exactly as the game/LPM term was: a
    /// `.neverPause` app keeps playing, but a safety suspend still wins.
    @Test("A neverPause app vetoes the Low Power Mode suspend")
    func neverPauseVetoesLowPower() {
        let settings = GlobalSettings(pauseInLowPowerMode: true)
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isLowPowerMode: true, isFrontmostExcludedByRule: true),
            settings: settings
        )
        #expect(profile == .quality)
    }

    @Test("Safety suspends still win over a neverPause app in Low Power Mode")
    func safetyStillWinsInLowPower() {
        let settings = GlobalSettings(pauseInLowPowerMode: true)
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(
                thermalState: .critical,
                isLowPowerMode: true,
                isFrontmostExcludedByRule: true
            ),
            settings: settings
        )
        #expect(profile == .suspended)
    }

    @Test("The setting ships on, matching the old game/LPM default")
    func defaultsToOn() {
        #expect(GlobalSettings().pauseInLowPowerMode)
    }

    @Test("An install predating the key gets the shipping default, and an explicit opt-out survives")
    func decodeDefaults() throws {
        let legacy = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        #expect(legacy.pauseInLowPowerMode, "installs without the key must keep pausing")

        var optedOut = GlobalSettings()
        optedOut.pauseInLowPowerMode = false
        let round = try JSONDecoder().decode(
            GlobalSettings.self, from: JSONEncoder().encode(optedOut)
        )
        #expect(!round.pauseInLowPowerMode, "an explicit false must survive a round-trip")
    }
}
