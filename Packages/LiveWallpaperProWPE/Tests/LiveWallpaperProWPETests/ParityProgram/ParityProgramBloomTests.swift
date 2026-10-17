import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

/// Bloom chain shape and per-pass constants as WPE writes them.
final class ParityProgramBloomTests: XCTestCase {
    /// Scene 3509243656's first frame at 1920×1080.
    func testScene3509243656HDRPassesCarryWPEsConstants() throws {
        let post = try fixturePost("3509243656", hdr: true)
        XCTAssertEqual(post.hdrBloomLevelCount, 6)
        let (width, height): (Float, Float) = (1920, 1080)
        func rv0(_ scale: Float) -> [Float] {
            [scale / width, scale / height, -scale / width, -scale / height]
        }
        func rt(_ divisor: Int) -> WPEResourceID {
            WPEResourceID("_rt_\(divisor)FrameBuffer")
        }
        var expected: [(shader: String, reads: [WPEResourceID], constants: [String: [Float]])] = [
            ("hdr_downsample_bloom", ["_rt_FullFrameBuffer"], [
                "g_BloomStrength": [0.235294], "g_BloomBlendParams": [0.46, 0.0552, 0.8096, 0.617574],
                "g_BloomTint": [1, 1, 1], "g_RenderVar0": rv0(1),
            ]),
        ]
        for scale in [2, 4, 8, 16, 32] {
            expected.append(("hdr_downsample", [rt(scale)], ["g_RenderVar0": rv0(Float(scale))]))
        }
        for scale in [32, 16, 8, 4, 2] {
            expected.append((scale >= 16 ? "hdr_upsample_cubic" : "hdr_upsample", [rt(scale * 2)],
                             ["g_RenderVar0": rv0(Float(scale)), "g_BloomScatter": [2]]))
        }
        expected.append(("combine_hdr", ["_rt_FullFrameBuffer", rt(2)], ["g_RenderVar0": [1, 1, -2 / width, -2 / height]]))
        let draws = WPEParityPostProcessBuilder.build(post).draws
        XCTAssertEqual(draws.map(\.shader), expected.map(\.shader))
        XCTAssertEqual(draws.map(\.reads), expected.map(\.reads))
        for (draw, pass) in zip(draws, expected) {
            Self.assertConstants(draw.constants, pass.constants, pass.shader)
        }
    }

    func testScene3509243656LDRQuarterDownsampleCarriesBloomValues() throws {
        let draws = try WPEParityPostProcessBuilder.build(fixturePost("3509243656", hdr: false)).draws
        XCTAssertEqual(draws.map(\.shader), ["downsample_quarter_bloom", "downsample_eighth_blur_v", "blur_h_bloom",
                                             "combine"])
        Self.assertConstants(draws[0].constants, ["g_BloomStrength": [4], "g_BloomThreshold": [0.23],
                                                  "g_BloomTint": [1, 1, 1]], draws[0].shader)
        XCTAssertTrue(draws.dropFirst().allSatisfy(\.constants.isEmpty))
    }

    /// A user property bound to a general bloom key reaches the constants.
    func testUserPropertyValueReachesHDRStrength() throws {
        let post = try fixturePost("3509243656", hdr: true, userValues: ["hdr": .number(8)])
        XCTAssertEqual(post.bloomSettings.hdrStrength, 8)
        XCTAssertEqual(post.bloomSettings.hdrScatter, 2)
    }

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

    private static func assertConstants(_ actual: [String: [Float]], _ expected: [String: [Float]], _ shader: String,
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

    private func fixturePost(_ sceneID: String, hdr: Bool,
                             userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws
        -> WPEParityPostProcessConfig {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let sceneDirectory = URL(fileURLWithPath: directory).appendingPathComponent("scene-sources/\(sceneID)")
        let data = try Data(contentsOf: sceneDirectory.appendingPathComponent("scene.json"))
        return try post(data, directory: sceneDirectory, hdr: hdr, userValues: userValues)
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
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: userValues,
                                                makeTransformScriptResolver: { _, _ in NoScripts() })
    }

    private func post(_ data: Data, directory: URL, hdr: Bool,
                      userValues: [String: WallpaperEngineProjectPropertyValue]) throws -> WPEParityPostProcessConfig {
        let document = try WPESceneDocumentParser.parse(data: data, userValues: userValues,
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        var post = WPEParityProgramScene(document: document,
                                         assets: WPEParityProgramAssets(sceneDirectory: directory, assetRoots: []),
                                         settings: WPEParityProgramSettings(hdrPostProcessing: hdr)).postProcess
        (post.backbufferWidth, post.backbufferHeight) = (1920, 1080)
        return post
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
