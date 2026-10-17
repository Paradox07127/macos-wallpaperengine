#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import XCTest

final class WPEParityProductSettingsTests: XCTestCase {
    func testResolverDownshiftsAndNeverUpsamplesOrEnablesInvalidInput() {
        XCTAssertEqual(WPEParityProductSettings.resolveMSAASampleCount(requested: 8, supports: { $0 == 4 }), 4)
        XCTAssertEqual(WPEParityProductSettings.resolveMSAASampleCount(requested: 2, supports: { $0 == 4 }), 1)
        XCTAssertEqual(WPEParityProductSettings.resolveMSAASampleCount(requested: 8, supports: { _ in false }), 1)
        XCTAssertEqual(WPEParityProductSettings.resolveMSAASampleCount(requested: 3, supports: { _ in true }), 1)
        XCTAssertEqual(WPEParityProductSettings.resolveMSAASampleCount(requested: 1, supports: { _ in true }), 1)
    }

    func testFactoryCombinesMacDefaultAuthorHDRAndRawPresetWithDeviceLimit() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityProductSettingsTests")
        defer { suite.discard() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = descriptor(preset: [
            "wec_e": .bool(true), "wec_brs": .number(25),
            "wcc_v": .string("Looks/Warm"), "wcc_amt": .number(25),
        ])
        let initial = try WPEParityProductSettings.make(descriptor: descriptor, device: device, defaults: suite.defaults)
        XCTAssertEqual(initial.msaaSampleCount, 1, "Off is the Mac resource default")
        XCTAssertFalse(initial.msaa)
        XCTAssertTrue(initial.hdrPostProcessing)
        XCTAssertTrue(initial.bloom)
        XCTAssertEqual(initial.colorCorrection.params[0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(initial.colorCorrection.lut, "Looks/Warm")
        XCTAssertEqual(initial.colorCorrection.lutAmount, 0.25)

        // AppStorage and the load-time factory read the same numeric preference key.
        suite.defaults.set(NSNumber(value: 8.0), forKey: WPEParityProductSettings.msaaSampleCountDefaultsKey)
        let resolved = try WPEParityProductSettings.make(descriptor: descriptor, device: device,
                                                         defaults: suite.defaults, bloomEnabled: false)
        XCTAssertFalse(resolved.bloom)
        XCTAssertTrue(resolved.hdrPostProcessing)
        XCTAssertEqual(resolved.colorCorrection, initial.colorCorrection)
        XCTAssertTrue([1, 2, 4, 8].contains(resolved.msaaSampleCount))
        XCTAssertTrue(device.supportsTextureSampleCount(resolved.msaaSampleCount))
        XCTAssertFalse([2, 4, 8].contains { $0 > resolved.msaaSampleCount && device.supportsTextureSampleCount($0) },
                       "the highest supported count at or below the request must be selected")
    }

    func testMalformedMacPreferenceFallsBackWithoutCoercion() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityProductSettingsTests")
        defer { suite.discard() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        suite.defaults.set(4.5, forKey: WPEParityProductSettings.msaaSampleCountDefaultsKey)
        XCTAssertEqual(try WPEParityProductSettings.make(descriptor: descriptor(), device: device,
                                                         defaults: suite.defaults).msaaSampleCount, 1)
        suite.defaults.set("4", forKey: WPEParityProductSettings.msaaSampleCountDefaultsKey)
        XCTAssertEqual(try WPEParityProductSettings.make(descriptor: descriptor(), device: device,
                                                         defaults: suite.defaults).msaaSampleCount, 1)
    }

    func testFactoryCarriesTheOffscreenScaleTierPreference() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityProductSettingsTests")
        defer { suite.discard() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertEqual(try WPEParityProductSettings.make(descriptor: descriptor(), device: device,
                                                         defaults: suite.defaults).offscreenScaleTier, 0)
        suite.defaults.set(2, forKey: WPEParityResourceSaverFlags.offscreenScaleTierDefaultsKey)
        XCTAssertEqual(try WPEParityProductSettings.make(descriptor: descriptor(), device: device,
                                                         defaults: suite.defaults).offscreenScaleTier, 2)
    }

    func testFactoryCarriesTheRenderTargetAliasingPreference() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityProductSettingsTests")
        defer { suite.discard() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertFalse(try WPEParityProductSettings.make(descriptor: descriptor(), device: device,
                                                         defaults: suite.defaults).renderTargetAliasing)
        suite.defaults.set(true, forKey: WPEParityResourceSaverFlags.renderTargetAliasingDefaultsKey)
        XCTAssertTrue(try WPEParityProductSettings.make(descriptor: descriptor(), device: device,
                                                        defaults: suite.defaults).renderTargetAliasing)
    }

    func testFactoryPropagatesTypedPresetFailureEvenWithBloomDisabled() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityProductSettingsTests")
        defer { suite.discard() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertThrowsError(try WPEParityProductSettings.make(
            descriptor: descriptor(preset: ["wec_brs": .string("25")]), device: device,
            defaults: suite.defaults, bloomEnabled: false
        )) { error in
            XCTAssertEqual(error as? WPEParityColorCorrectionPresetError, .unsupportedType(field: "wec_brs"))
        }
    }

    private func descriptor(preset: [String: WallpaperEngineProjectPropertyValue] = [:]) -> SceneDescriptor {
        SceneDescriptor(workshopID: "product-settings", cacheRelativePath: "wpe-cache/product-settings",
                        entryFile: "scene.json", capabilityTier: .imageOnly, presetID: "preset",
                        presetSnapshot: preset)
    }
}
#endif
