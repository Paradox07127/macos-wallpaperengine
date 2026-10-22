import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

/// Bloom chain shape and per-pass constants as WPE writes them.
final class ParityProgramBloomTests: XCTestCase {
    /// Scene 3509243656's first frame at 1920×1080.

    /// A user property bound to a general bloom key reaches the constants.

    func testUserPropertyValuesReachLDRBloomSettingsWithoutHDR() throws {
        let post = try inlinePost(general: [
            "hdr": false, "bloom": true,
            "bloomstrength": ["user": "s", "value": 2],
            "bloomthreshold": ["user": "t", "value": 0.65],
        ], userValues: ["s": .number(3), "t": .number(0.2)])
        XCTAssertEqual(post.bloomSettings.strength, 3)
        XCTAssertEqual(post.bloomSettings.threshold, 0.2)
    }

    func testMissingUserPropertyValuesKeepAuthoredLDRBloomSettings() throws {
        let post = try inlinePost(general: [
            "hdr": false, "bloom": true,
            "bloomstrength": ["user": "s", "value": 2],
            "bloomthreshold": ["user": "t", "value": 0.65],
        ])
        XCTAssertEqual(post.bloomSettings.strength, 2)
        XCTAssertEqual(post.bloomSettings.threshold, 0.65)
    }

    func testUserPropertyValuesReachHDRBloomSettingsAndTintWithoutHDR() throws {
        let post = try inlinePost(general: [
            "hdr": false, "bloom": true,
            "bloomhdrstrength": ["user": "s", "value": 2],
            "bloomhdrthreshold": ["user": "t", "value": 1],
            "bloomhdrfeather": ["user": "f", "value": 0.1],
            "bloomhdrscatter": ["user": "c", "value": 1.619],
            "bloomhdriterations": ["user": "i", "value": 8],
            "bloomtint": ["user": "color", "value": "1 1 1"],
        ], userValues: ["s": .number(4), "t": .number(0.3), "f": .number(0.4),
                        "c": .number(2), "i": .number(5), "color": .string("0.2 0.4 0.6")])
        XCTAssertEqual(post.bloomSettings.hdrStrength, 4)
        XCTAssertEqual(post.bloomSettings.hdrThreshold, 0.3)
        XCTAssertEqual(post.bloomSettings.hdrFeather, 0.4)
        XCTAssertEqual(post.bloomSettings.hdrScatter, 2)
        XCTAssertEqual(post.bloomSettings.hdrIterations, 5)
        XCTAssertEqual(post.bloomSettings.tint, SIMD3<Float>(0.2, 0.4, 0.6))
    }

    func testUserPropertyValueEnablesBloomSwitchWithoutHDR() throws {
        let post = try inlinePost(general: [
            "hdr": false, "bloom": ["user": "enabled", "value": false],
        ], userValues: ["enabled": .bool(true)])
        XCTAssertTrue(post.sceneBloomEnabled)
        XCTAssertEqual(WPEParityPostProcessBuilder.build(post).draws.map(\.shader),
                       ["downsample_quarter_bloom", "downsample_eighth_blur_v", "blur_h_bloom", "combine"])
    }

    func testHDRDisabledKeepsLegacyBloomSettingsNil() throws {
        let inputs: [(general: [String: Any], userValues: [String: WallpaperEngineProjectPropertyValue])] = [
            (["hdr": false, "bloom": true, "bloomstrength": ["user": "s", "value": 2],
              "bloomthreshold": ["user": "t", "value": 0.65]], ["s": .number(3), "t": .number(0.2)]),
            (["hdr": false, "bloom": true, "bloomstrength": ["user": "s", "value": 2],
              "bloomthreshold": ["user": "t", "value": 0.65]], [:]),
            (["hdr": false, "bloom": true, "bloomhdrstrength": ["user": "s", "value": 2]],
             ["s": .number(4)]),
            (["hdr": false, "bloom": ["user": "enabled", "value": false]], ["enabled": .bool(true)]),
        ]
        for input in inputs {
            let document = try inlineDocument(general: input.general, userValues: input.userValues)
            XCTAssertNil(document.general.bloom)
        }
    }

    /// e0 starts at 0x26, so an absent `general.bloom` is on; absent bloom keys keep WPE's defaults.
    func testMissingBloomKeyBuildsLDRChainWithWPEDefaults() throws {
        let post = try inlinePost(general: [:])
        XCTAssertEqual(post.bloomSettings, WPEParityBloomSettings())
        XCTAssertEqual(WPEParityPostProcessBuilder.build(post).draws.map(\.shader),
                       ["downsample_quarter_bloom", "downsample_eighth_blur_v", "blur_h_bloom", "combine"])
        let off = try inlinePost(general: ["bloom": false])
        XCTAssertTrue(WPEParityPostProcessBuilder.build(off).draws.isEmpty)
    }

    func testWPEDefaults() {
        let defaults = WPEParityBloomSettings()
        XCTAssertEqual(defaults.strength, 2)
        XCTAssertEqual(defaults.threshold, 0.65)
        XCTAssertEqual(defaults.hdrStrength, 2)
        XCTAssertEqual(defaults.hdrThreshold, 1)
        XCTAssertEqual(defaults.hdrFeather, 0.1)
        XCTAssertEqual(defaults.hdrScatter, 1.619)
        XCTAssertEqual(defaults.hdrIterations, 8)
        XCTAssertEqual(defaults.tint, SIMD3<Float>(1, 1, 1))
    }

    static func assertConstants(_ actual: [String: [Float]], _ expected: [String: [Float]], _ shader: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), shader, file: file, line: line)
        for (name, values) in expected {
            let got = actual[name] ?? []
            XCTAssertEqual(got.count, values.count, "\(shader) \(name)", file: file, line: line)
            for (value, want) in zip(got, values) {
                XCTAssertEqual(value, want, accuracy: 1e-5, "\(shader) \(name)", file: file, line: line)
            }
        }
    }

    private func inlinePost(general: [String: Any],
                            userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws
        -> WPEParityPostProcessConfig {
        let document = try inlineDocument(general: general, userValues: userValues)
        return WPEParityProgramScene(document: document,
                                     assets: WPEParityProgramAssets(sceneDirectory: FileManager.default.temporaryDirectory,
                                                                    assetRoots: []),
                                     settings: WPEParityProgramSettings()).postProcess
    }

    private func inlineDocument(general: [String: Any],
                                userValues: [String: WallpaperEngineProjectPropertyValue]) throws -> WPESceneDocument {
        var general = general
        general["orthogonalprojection"] = ["width": 1920, "height": 1080]
        let json: [String: Any] = ["camera": ["center": "0 0 0"], "general": general,
                                   "objects": [["id": 1, "name": "layer"]]]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: userValues)
    }

    func post(_ data: Data, directory: URL, hdr: Bool,
                      userValues: [String: WallpaperEngineProjectPropertyValue]) throws -> WPEParityPostProcessConfig {
        let document = try WPESceneDocumentParser.parse(data: data, userValues: userValues)
        var post = WPEParityProgramScene(document: document,
                                         assets: WPEParityProgramAssets(sceneDirectory: directory, assetRoots: []),
                                         settings: WPEParityProgramSettings(hdrPostProcessing: hdr)).postProcess
        (post.backbufferWidth, post.backbufferHeight) = (1920, 1080)
        return post
    }
}
