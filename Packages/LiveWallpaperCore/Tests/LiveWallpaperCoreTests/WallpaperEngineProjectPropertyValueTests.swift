import Foundation
import Testing
@testable import LiveWallpaperCore

/// `project.json` arrives with imported wallpapers and is untrusted. The
/// integral fast path in `stringValue` used to call `Int(_:)`, which traps past
/// `Int`'s range — crashing while building the custom-settings UI for an
/// imported wallpaper rather than rendering the value as-is.
@Suite("WallpaperEngineProjectPropertyValue numeric formatting")
struct WallpaperEngineProjectPropertyValueTests {

    @Test("An out-of-range integral value formats instead of trapping")
    func outOfRangeIntegralFormats() {
        // 1e300 is finite and integral, so it reaches the fast path.
        let value = WallpaperEngineProjectPropertyValue.number(1e300)
        #expect(value.stringValue == String(1e300))
        #expect(WallpaperEngineProjectPropertyValue.number(-1e300).stringValue == String(-1e300))
    }

    @Test("In-range integral values keep their integer formatting")
    func inRangeIntegralKeepsIntegerForm() {
        #expect(WallpaperEngineProjectPropertyValue.number(3).stringValue == "3")
        #expect(WallpaperEngineProjectPropertyValue.number(-7).stringValue == "-7")
        #expect(WallpaperEngineProjectPropertyValue.number(0).stringValue == "0")
    }

    @Test("Fractional values keep their Double formatting")
    func fractionalKeepsDoubleForm() {
        #expect(WallpaperEngineProjectPropertyValue.number(2.5).stringValue == "2.5")
    }
}
