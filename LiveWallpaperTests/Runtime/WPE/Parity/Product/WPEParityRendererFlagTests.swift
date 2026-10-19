#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import XCTest

@MainActor
final class WPEParityRendererRetirementTests: XCTestCase {
    func testEveryHistoricalSelectionIsRemovedWithoutChangingOtherPreferences() async throws {
        for mode in ["off", "listed", "all"] {
            let suite = try TestScratch.defaultsSuite("ParityRendererRetirement")
            defer { suite.discard() }
            let root = FileManager.default.temporaryDirectory.appending(path: "parity-settings-\(UUID())")
            let defaults = suite.defaults
            defaults.set(mode, forKey: "loomscreen.wallpapers.parityRendererMode.v1")
            defaults.set(["3815666789"], forKey: "loomscreen.wallpapers.parityRenderer.v1")
            defaults.set(24, forKey: "WPEFrameRateLimit")
            let manager = SettingsManager(directory: .init(root: root), defaults: defaults)
            XCTAssertNil(defaults.object(forKey: "loomscreen.wallpapers.parityRendererMode.v1"))
            XCTAssertNil(defaults.object(forKey: "loomscreen.wallpapers.parityRenderer.v1"))
            XCTAssertEqual(defaults.integer(forKey: "WPEFrameRateLimit"), 24)
            let restarted = SettingsManager(directory: .init(root: root), defaults: defaults)
            XCTAssertEqual(defaults.integer(forKey: "WPEFrameRateLimit"), 24)
            await TestScratch.discard(root, flushing: manager, restarted)
        }
    }
}
#endif
