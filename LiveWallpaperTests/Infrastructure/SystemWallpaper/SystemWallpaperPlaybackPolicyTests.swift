import Foundation
import Testing

@testable import LiveWallpaper

@Suite("System wallpaper playback policy")
struct SystemWallpaperPlaybackPolicyTests {

    @Test("Ease to a still applies on the desktop but never on the lock screen")
    func stillOnDesktopOnlyOffLockScreen() {
        let desktop = PlaybackPolicyInput(
            thermalState: .nominal,
            onBattery: false,
            lowPowerMode: false,
            systemRequestedPause: false,
            isLockScreen: false,
            playbackMode: .stillOnDesktop
        )
        #expect(PlaybackPolicy.tier(for: desktop) == .minimal)
        #expect(PlaybackPolicy.rate(for: .minimal) == 0)

        var locked = desktop
        locked.isLockScreen = true
        #expect(PlaybackPolicy.tier(for: locked) == .full, "the lock screen is the one moment the system wants motion")
    }

    @Test("Keeping playback on keeps the desktop at full rate")
    func alwaysModeKeepsPlaying() {
        let input = PlaybackPolicyInput(
            thermalState: .nominal,
            onBattery: false,
            lowPowerMode: false,
            systemRequestedPause: false,
            isLockScreen: false,
            playbackMode: .always
        )
        #expect(PlaybackPolicy.tier(for: input) == .full)
    }
    private func input(
        thermal: ProcessInfo.ThermalState = .nominal,
        battery: Bool = false,
        lowPower: Bool = false,
        paused: Bool = false
    ) -> PlaybackPolicyInput {
        PlaybackPolicyInput(
            thermalState: thermal,
            onBattery: battery,
            lowPowerMode: lowPower,
            systemRequestedPause: paused
        )
    }

    @Test("A system pause request outranks every other signal")
    func systemPauseWins() {
        #expect(PlaybackPolicy.tier(for: input(paused: true)) == .paused)
        #expect(PlaybackPolicy.tier(for: input(thermal: .nominal, paused: true)) == .paused)
    }

    @Test("Thermal pressure steps the tier down")
    func thermalLadder() {
        #expect(PlaybackPolicy.tier(for: input(thermal: .critical)) == .paused)
        #expect(PlaybackPolicy.tier(for: input(thermal: .serious)) == .minimal)
        #expect(PlaybackPolicy.tier(for: input(thermal: .fair)) == .reduced)
        #expect(PlaybackPolicy.tier(for: input(thermal: .nominal)) == .full)
    }

    @Test("Battery reduces, and compounds with fair thermals")
    func batteryTiers() {
        #expect(PlaybackPolicy.tier(for: input(battery: true)) == .reduced)
        #expect(PlaybackPolicy.tier(for: input(thermal: .fair, battery: true)) == .minimal)
    }

    @Test("Low power mode drops to minimal on wall power")
    func lowPowerMode() {
        #expect(PlaybackPolicy.tier(for: input(lowPower: true)) == .minimal)
    }

    @Test("Rates match the tiers, with both stopped tiers at zero")
    func rates() {
        #expect(PlaybackPolicy.rate(for: .full) == 1.0)
        #expect(PlaybackPolicy.rate(for: .reduced) == 0.5)
        #expect(PlaybackPolicy.rate(for: .minimal) == 0)
        #expect(PlaybackPolicy.rate(for: .paused) == 0)
    }
}
