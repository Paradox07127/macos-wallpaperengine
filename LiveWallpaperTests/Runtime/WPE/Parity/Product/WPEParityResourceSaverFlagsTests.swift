#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import XCTest

final class WPEParityResourceSaverFlagsTests: XCTestCase {
    private static let defaultFlags = WPEParityResourceSaverFlags(textureCompression: true, renderTargetAliasing: false,
                                                                  offscreenScaleTier: 0, sceneMirrorRendering: false)

    func testUnsetPreferencesResolveCompressionOnAndOthersOff() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
        defer { suite.discard() }
        XCTAssertEqual(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults), Self.defaultFlags)
    }

    func testExplicitFalseTurnsCompressionOff() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
        defer { suite.discard() }
        suite.defaults.set(false, forKey: WPEParityResourceSaverFlags.textureCompressionDefaultsKey)
        XCTAssertFalse(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults).textureCompression)
    }

    func testEachKeyFlipsOnlyItsOwnField() throws {
        let cases: [(String, Any, WPEParityResourceSaverFlags)] = [
            (WPEParityResourceSaverFlags.textureCompressionDefaultsKey, false,
             .init(textureCompression: false, renderTargetAliasing: false, offscreenScaleTier: 0,
                   sceneMirrorRendering: false)),
            (WPEParityResourceSaverFlags.renderTargetAliasingDefaultsKey, true,
             .init(textureCompression: true, renderTargetAliasing: true, offscreenScaleTier: 0,
                   sceneMirrorRendering: false)),
            (WPEParityResourceSaverFlags.offscreenScaleTierDefaultsKey, 3,
             .init(textureCompression: true, renderTargetAliasing: false, offscreenScaleTier: 3,
                   sceneMirrorRendering: false)),
            (WPEParityResourceSaverFlags.sceneMirrorRenderingDefaultsKey, true,
             .init(textureCompression: true, renderTargetAliasing: false, offscreenScaleTier: 0,
                   sceneMirrorRendering: true)),
        ]
        for (key, value, expected) in cases {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
            defer { suite.discard() }
            suite.defaults.set(value, forKey: key)
            XCTAssertEqual(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults), expected, key)
        }
    }

    func testNonBoolSwitchValuesResolveToTheirDefaults() throws {
        let values: [Any] = [1, 0, "true", "false"]
        for value in values {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityResourceSaverFlagsTests")
            defer { suite.discard() }
            suite.defaults.set(value, forKey: WPEParityResourceSaverFlags.textureCompressionDefaultsKey)
            suite.defaults.set(value, forKey: WPEParityResourceSaverFlags.renderTargetAliasingDefaultsKey)
            XCTAssertEqual(WPEParityResourceSaverFlags.resolve(defaults: suite.defaults), Self.defaultFlags,
                           "\(value)")
        }
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
