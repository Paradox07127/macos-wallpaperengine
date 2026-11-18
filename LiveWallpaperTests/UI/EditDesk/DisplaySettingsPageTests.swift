@testable import LiveWallpaper
import Testing

/// The Display section's menus, built from mode lists without touching a real display.
@MainActor
@Suite("Display settings menus")
struct DisplaySettingsPageTests {
    private static func option(
        _ width: Int, _ height: Int, pixels scale: Int = 2, hz: Double = 60, current: Bool = false
    ) -> DisplayModeOption {
        DisplayModeOption(
            key: DisplayModeKey(width: width, height: height, pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: hz),
            isCurrent: current, isNative: false
        )
    }

    @Test("Resolutions list each point size once, largest first, a HiDPI size before its low-resolution twin")
    func resolutionsDeduplicateAndSort() {
        let options = [
            Self.option(1512, 982, hz: 120), Self.option(1920, 1080, hz: 60), Self.option(1512, 982, hz: 60),
            Self.option(1920, 1080, pixels: 1, hz: 60), Self.option(1920, 1200, hz: 60),
        ]
        #expect(DisplaySettingsPage.resolutions(in: options) == [
            DisplayResolution(width: 1920, height: 1200, isHiDPI: true),
            DisplayResolution(width: 1920, height: 1080, isHiDPI: true),
            DisplayResolution(width: 1920, height: 1080, isHiDPI: false),
            DisplayResolution(width: 1512, height: 982, isHiDPI: true),
        ])
    }

    @Test("Refresh rates come only from the chosen resolution, fastest first")
    func refreshRatesFilterByResolution() {
        let options = [
            Self.option(1512, 982, hz: 60), Self.option(1512, 982, hz: 120), Self.option(1512, 982, hz: 60),
            Self.option(1920, 1080, hz: 50), Self.option(1512, 982, pixels: 1, hz: 30),
        ]
        let resolution = DisplayResolution(width: 1512, height: 982, isHiDPI: true)
        #expect(DisplaySettingsPage.refreshRates(for: resolution, in: options) == [120, 60])
    }

    @Test("A display that reports no rate reads Default; others read in hertz")
    func zeroHertzReadsDefault() {
        #expect(DisplaySettingsPage.refreshRateTitle(0) == String(localized: "Default", bundle: .appLanguage))
        #expect(DisplaySettingsPage.refreshRateTitle(0) != DisplaySettingsPage.refreshRateTitle(60))
        #expect(DisplaySettingsPage.refreshRateTitle(60).contains("60"))
    }

    @Test("A size reads as width × height; only a twin of a HiDPI size is marked low resolution")
    func resolutionTitles() {
        let hiDPI = DisplayResolution(width: 1920, height: 1080, isHiDPI: true)
        let twin = DisplayResolution(width: 1920, height: 1080, isHiDPI: false)
        let lone = DisplayResolution(width: 1280, height: 720, isHiDPI: false)
        let all = [hiDPI, twin, lone]
        #expect(DisplaySettingsPage.resolutionTitle(hiDPI, among: all) == "1920 × 1080")
        #expect(DisplaySettingsPage.resolutionTitle(lone, among: all) == "1280 × 720")
        #expect(DisplaySettingsPage.resolutionTitle(twin, among: all) != "1920 × 1080")
        #expect(DisplaySettingsPage.resolutionTitle(twin, among: all).contains("1920 × 1080"))
    }

    @Test("The running mode is the menus' selection")
    func currentModeIsSelected() {
        let options = [Self.option(1920, 1080, hz: 60), Self.option(1512, 982, hz: 120, current: true), Self.option(1512, 982, hz: 60)]
        let selection = DisplaySettingsPage.selection(in: options)
        #expect(selection?.resolution == DisplayResolution(width: 1512, height: 982, isHiDPI: true))
        #expect(selection?.refreshRate == 120)
        #expect(DisplaySettingsPage.selection(in: [Self.option(1920, 1080)]) == nil)
    }

    @Test("Switching resolution keeps the rate when offered, otherwise takes the fastest")
    func modeKeepsRateOrTakesFastest() {
        let options = [Self.option(1920, 1080, hz: 50), Self.option(1920, 1080, hz: 60), Self.option(1512, 982, hz: 120)]
        let resolution = DisplayResolution(width: 1920, height: 1080, isHiDPI: true)
        #expect(DisplaySettingsPage.mode(for: resolution, refreshRate: 50, in: options)?.refreshRate == 50)
        #expect(DisplaySettingsPage.mode(for: resolution, refreshRate: 120, in: options)?.refreshRate == 60)
    }
}
