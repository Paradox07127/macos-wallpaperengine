#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import XCTest

final class WPEParityRendererFlagTests: XCTestCase {
    private var suite: TestScratch.DefaultsSuite!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = try TestScratch.defaultsSuite("WPEParityRendererFlagTests")
    }

    override func tearDown() {
        suite.discard()
        super.tearDown()
    }

    func testAbsentKeyEnablesNoScene() {
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: "3815666789", defaults: suite.defaults))
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: nil, defaults: suite.defaults))
    }

    func testListEnablesOnlyListedScenes() {
        suite.defaults.set(["3815666789", "2370640409"], forKey: WPEParityRendererFlag.defaultsKey)
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: "3815666789", defaults: suite.defaults))
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: "2370640409", defaults: suite.defaults))
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: "3660962877", defaults: suite.defaults))
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: nil, defaults: suite.defaults))
    }

    func testWildcardEnablesEveryScene() {
        suite.defaults.set(["*"], forKey: WPEParityRendererFlag.defaultsKey)
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: "3815666789", defaults: suite.defaults))
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: nil, defaults: suite.defaults))
    }

    func testAbsentModeReadsAsListed() {
        XCTAssertEqual(WPEParityRendererFlag.mode(defaults: suite.defaults), .listed)
        suite.defaults.set("bogus", forKey: WPEParityRendererFlag.modeDefaultsKey)
        XCTAssertEqual(WPEParityRendererFlag.mode(defaults: suite.defaults), .listed)
    }

    func testOffModeDisablesListedScenes() {
        suite.defaults.set(["3815666789", "*"], forKey: WPEParityRendererFlag.defaultsKey)
        WPEParityRendererFlag.setMode(.off, defaults: suite.defaults)
        XCTAssertEqual(WPEParityRendererFlag.mode(defaults: suite.defaults), .off)
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: "3815666789", defaults: suite.defaults))
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: nil, defaults: suite.defaults))
    }

    func testAllModeEnablesEveryScene() {
        WPEParityRendererFlag.setMode(.all, defaults: suite.defaults)
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: "3660962877", defaults: suite.defaults))
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: nil, defaults: suite.defaults))
    }

    func testListedModeUsesTheList() {
        suite.defaults.set(["3815666789"], forKey: WPEParityRendererFlag.defaultsKey)
        WPEParityRendererFlag.setMode(.listed, defaults: suite.defaults)
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: "3815666789", defaults: suite.defaults))
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: "3660962877", defaults: suite.defaults))
    }

    func testSetListedRoundTripsWithoutDuplicates() {
        WPEParityRendererFlag.setListed(true, workshopID: "3815666789", defaults: suite.defaults)
        WPEParityRendererFlag.setListed(true, workshopID: "3815666789", defaults: suite.defaults)
        WPEParityRendererFlag.setListed(true, workshopID: "2370640409", defaults: suite.defaults)
        XCTAssertEqual(suite.defaults.stringArray(forKey: WPEParityRendererFlag.defaultsKey), ["3815666789", "2370640409"])
        XCTAssertTrue(WPEParityRendererFlag.isEnabled(workshopID: "3815666789", defaults: suite.defaults))

        WPEParityRendererFlag.setListed(false, workshopID: "3815666789", defaults: suite.defaults)
        XCTAssertEqual(suite.defaults.stringArray(forKey: WPEParityRendererFlag.defaultsKey), ["2370640409"])
        XCTAssertFalse(WPEParityRendererFlag.isEnabled(workshopID: "3815666789", defaults: suite.defaults))
    }

    func testMenuStateFollowsTheMode() {
        suite.defaults.set(["3815666789"], forKey: WPEParityRendererFlag.defaultsKey)

        let listed = WPEParityRendererFlag.menuState(workshopID: "3815666789", defaults: suite.defaults)
        XCTAssertTrue(listed.isChecked)
        XCTAssertTrue(listed.isEnabled)
        let unlisted = WPEParityRendererFlag.menuState(workshopID: "3660962877", defaults: suite.defaults)
        XCTAssertFalse(unlisted.isChecked)
        XCTAssertTrue(unlisted.isEnabled)

        WPEParityRendererFlag.setMode(.all, defaults: suite.defaults)
        let all = WPEParityRendererFlag.menuState(workshopID: "3660962877", defaults: suite.defaults)
        XCTAssertTrue(all.isChecked)
        XCTAssertFalse(all.isEnabled)

        WPEParityRendererFlag.setMode(.off, defaults: suite.defaults)
        let off = WPEParityRendererFlag.menuState(workshopID: "3815666789", defaults: suite.defaults)
        XCTAssertFalse(off.isChecked)
        XCTAssertFalse(off.isEnabled)
    }
}
#endif
