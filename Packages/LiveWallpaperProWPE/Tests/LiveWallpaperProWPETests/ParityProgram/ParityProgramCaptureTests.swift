import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramCaptureTests: XCTestCase {
    private func fixture() throws -> ParityProgramCaptureFixture {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing dxs-pairs.json and scene-sources/")
        }
        let install = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let assets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: assets.appendingPathComponent("materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util, models/util)")
        }
        return try ParityProgramCaptureFixture(root: URL(fileURLWithPath: directory), wpeAssets: assets)
    }

    /// Draws whose program is known not to match: the .mdl model objects (the frame treats them as image layers and
    /// their material lives in the .mdl) and layer 449, whose material sets FOG=1 and gets BLENDMODE=0 and
    /// FOG_COMPUTED=1 from the image layer in WPE (n=47/48).
    private static let knownUnmatched: [String: Set<String>] = [
        "3509243656": ["188/albedo", "214/albedo", "218/albedo", "2077/albedo", "238/albedo", "436/albedo",
                       "449/albedo"],
    ]

    func testFrameZeroProgramsMatchCapturedHLSLAndDXSKeys() throws {
        let fixture = try fixture()
        var summary: [String] = []
        var keysChecked = 0
        for scene in ParityProgramCaptureFixture.scenes {
            let results = try fixture.run(scene.id, captureRange: scene.captures)
            print("scene \(scene.id) draw table")
            for result in results {
                let outcome = result.matched
                    ? "n=" + [WPEHLSLStage.vertex, .geometry, .fragment].compactMap { result.matches[$0] }
                    .map(String.init).joined(separator: ",")
                    : result.problems.joined(separator: " | ")
                print("  \(scene.id) | \(result.pass.rawValue) | \(result.shader) | \(outcome)")
            }
            let matched = results.filter(\.matched)
            for result in matched {
                guard let program = result.program, let capture = result.matches[.fragment] else { continue }
                XCTAssertEqual(program.dxsKey(), fixture.dxsKey(capture),
                               "\(scene.id) \(result.pass.rawValue) .dxs key differs from capture n=\(capture)")
                keysChecked += 1
            }
            XCTAssertEqual(Set(results.filter { !$0.matched }.map(\.pass.rawValue)),
                           Self.knownUnmatched[scene.id] ?? [], scene.id)
            let produced = Set(results.flatMap(\.matches.values))
            let missing = scene.captures.filter { !produced.contains($0) }
                .compactMap { fixture.captures[$0] }.map { "n=\($0.n) \($0.name)" }
            print("scene \(scene.id): matched \(matched.count)/\(results.count) draws; "
                + "captures no draw produced (\(missing.count)): \(missing.joined(separator: ", "))")
            summary.append("\(scene.id) \(matched.count)/\(results.count)")
        }
        print("matched draws per scene: \(summary.joined(separator: "; ")); .dxs keys compared: \(keysChecked)")
    }

    func testDroppingHDRFlagLosesMatches() throws {
        let fixture = try fixture()
        var baseline = 0
        var withoutHDR = 0
        for scene in ParityProgramCaptureFixture.scenes {
            baseline += try fixture.run(scene.id, captureRange: scene.captures).count(where: \.matched)
            withoutHDR += try fixture.run(scene.id, captureRange: scene.captures) { $0.hdr = false }
                .count(where: \.matched)
        }
        print("negative control: matched draws \(baseline) with engine flags, \(withoutHDR) with HDR dropped")
        XCTAssertLessThan(withoutHDR, baseline)
    }
}
