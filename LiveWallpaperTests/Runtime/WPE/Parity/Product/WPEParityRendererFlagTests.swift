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
}
#endif
