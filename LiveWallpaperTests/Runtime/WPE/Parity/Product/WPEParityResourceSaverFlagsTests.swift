#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import XCTest

final class WPEParityResourceSaverFlagsTests: XCTestCase {
    private static let off = WPEParityResourceSaverFlags(textureCompression: false, renderTargetAliasing: false,
                                                         offscreenScaleTier: 0, sceneMirrorRendering: false)

    func testUnsetPreferencesResolveToAllOff() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
        defer { suite.discard() }
        XCTAssertEqual(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults), Self.off)
    }

    func testEachKeyFlipsOnlyItsOwnField() throws {
        let cases: [(String, Any, WPEParityResourceSaverFlags)] = [
            (WPEParityResourceSaverFlags.textureCompressionDefaultsKey, true,
             .init(textureCompression: true, renderTargetAliasing: false, offscreenScaleTier: 0,
                   sceneMirrorRendering: false)),
            (WPEParityResourceSaverFlags.renderTargetAliasingDefaultsKey, true,
             .init(textureCompression: false, renderTargetAliasing: true, offscreenScaleTier: 0,
                   sceneMirrorRendering: false)),
            (WPEParityResourceSaverFlags.offscreenScaleTierDefaultsKey, 3,
             .init(textureCompression: false, renderTargetAliasing: false, offscreenScaleTier: 3,
                   sceneMirrorRendering: false)),
            (WPEParityResourceSaverFlags.sceneMirrorRenderingDefaultsKey, true,
             .init(textureCompression: false, renderTargetAliasing: false, offscreenScaleTier: 0,
                   sceneMirrorRendering: true)),
        ]
        for (key, value, expected) in cases {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
            defer { suite.discard() }
            suite.defaults.set(value, forKey: key)
            XCTAssertEqual(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults), expected, key)
        }
    }

    func testNonBoolSwitchValuesResolveOff() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
        defer { suite.discard() }
        suite.defaults.set(1, forKey: WPEParityResourceSaverFlags.textureCompressionDefaultsKey)
        suite.defaults.set("true", forKey: WPEParityResourceSaverFlags.renderTargetAliasingDefaultsKey)
        XCTAssertEqual(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults), Self.off)
    }

    func testOutOfRangeOrNonIntegralTierResolvesToZero() throws {
        let values: [Any] = [7, -1, 1.5, "2"]
        for value in values {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
            defer { suite.discard() }
            suite.defaults.set(value, forKey: WPEParityResourceSaverFlags.offscreenScaleTierDefaultsKey)
            XCTAssertEqual(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults).offscreenScaleTier, 0,
                           "\(value)")
        }
    }
}
#endif
