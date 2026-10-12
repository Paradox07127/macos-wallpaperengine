import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

/// Bloom chain shape and per-pass constants as WPE writes them (R15).
final class ParityProgramBloomTests: XCTestCase {
    /// R15 "3509243656 首帧" at 1920×1080.
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

    private func inlinePost(general: [String: Any]) throws -> WPEParityPostProcessConfig {
        var general = general
        general["orthogonalprojection"] = ["width": 1920, "height": 1080]
        let json: [String: Any] = ["camera": ["center": "0 0 0"], "general": general,
                                   "objects": [["id": 1, "name": "layer"]]]
        return try post(JSONSerialization.data(withJSONObject: json), directory: FileManager.default.temporaryDirectory,
                        hdr: false, userValues: [:])
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
