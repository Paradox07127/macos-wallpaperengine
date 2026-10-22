import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

extension ParityProgramBloomTests {
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

    func testUserPropertyValueReachesHDRStrength() throws {
        let post = try fixturePost("3509243656", hdr: true, userValues: ["hdr": .number(8)])
        XCTAssertEqual(post.bloomSettings.hdrStrength, 8)
        XCTAssertEqual(post.bloomSettings.hdrScatter, 2)
    }

    private func fixturePost(_ sceneID: String, hdr: Bool,
                             userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws
        -> WPEParityPostProcessConfig {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw CorpusFixtures.MissingInput("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let sceneDirectory = URL(fileURLWithPath: directory).appendingPathComponent("scene-sources/\(sceneID)")
        let data = try Data(contentsOf: sceneDirectory.appendingPathComponent("scene.json"))
        return try post(data, directory: sceneDirectory, hdr: hdr, userValues: userValues)
    }
}
