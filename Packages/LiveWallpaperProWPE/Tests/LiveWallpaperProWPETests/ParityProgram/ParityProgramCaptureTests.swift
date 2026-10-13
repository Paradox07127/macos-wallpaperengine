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

    /// `.mdl` model draws, which take the generic4 material inside the model file.
    private static let modelDraws: Set<String> = ["188/mesh0", "214/mesh0", "218/mesh0", "2077/mesh0",
                                                  "238/mesh0", "436/mesh0"]

    /// Draws whose program has the `.dxs` key of an earlier draw's capture but whose combo text order differs: 436
    /// shares 238's key, and 449's albedo (material combos FOG, LIGHTING) shares the key of n=15/16.
    private static let knownMatchedByKey: [String: [String: Int]] = [
        "3509243656": ["436/mesh0": 39, "449/albedo": 16],
    ]

    /// Draws that match no capture, byte for byte or by key.
    private static let knownUnmatched: [String: Set<String>] = [:]

    /// Visible particle draws and the captures their vertex, geometry and fragment stages reproduce.
    private static let particleMatches: [String: [String: [Int]]] = [
        "3509243656": ["2097/particle/r0": [29, 30, 31], "2084/particle/r0": [29, 30, 31]],
        "3660962877": ["560/particle/r0": [111, 112, 113], "747/particle/r0": [125, 126, 127]],
    ]

    func testFrameZeroProgramsMatchCapturedHLSLAndDXSKeys() throws {
        let fixture = try fixture()
        var summary: [String] = []
        var keysChecked = 0
        for scene in ParityProgramCaptureFixture.scenes {
            let results = try fixture.run(scene.id, captureRange: scene.captures)
            print("scene \(scene.id) draw table")
            for result in results {
                let outcome = if result.matched {
                    "n=" + [WPEHLSLStage.vertex, .geometry, .fragment].compactMap { result.matches[$0] }
                        .map(String.init).joined(separator: ",")
                } else if let key = result.keyMatch {
                    "key of n=\(key) | " + result.problems.joined(separator: " | ")
                } else {
                    result.problems.joined(separator: " | ")
                }
                print("  \(scene.id) | \(result.pass.rawValue) | \(result.shader) | \(outcome)")
            }
            let byKey = results.filter { !$0.matched && $0.keyMatch != nil }
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: byKey.map { ($0.pass.rawValue, $0.keyMatch ?? 0) }),
                           Self.knownMatchedByKey[scene.id] ?? [:], scene.id)
            if scene.id == "3509243656" {
                // ledsource puts 449 through its composite, drawn with BLENDMODE 0 and FOG_COMPUTED 1.
                XCTAssertEqual(results.first { $0.pass == "449/passthrough4" }?.matches[.fragment], 48)
            }
            for (pass, captures) in Self.particleMatches[scene.id] ?? [:] {
                let result = results.first { $0.pass.rawValue == pass }
                XCTAssertEqual([WPEHLSLStage.vertex, .geometry, .fragment].compactMap { result?.matches[$0] }, captures,
                               "\(scene.id) \(pass)")
            }
            let matched = results.filter(\.matched)
            for result in matched {
                guard let program = result.program, let capture = result.matches[.fragment] else { continue }
                XCTAssertEqual(program.dxsKey(), fixture.dxsKey(capture),
                               "\(scene.id) \(result.pass.rawValue) .dxs key differs from capture n=\(capture)")
                keysChecked += 1
            }
            XCTAssertEqual(Set(results.filter { !$0.matched && $0.keyMatch == nil }.map(\.pass.rawValue)),
                           Self.knownUnmatched[scene.id] ?? [], scene.id)
            for result in results where Self.modelDraws.contains(result.pass.rawValue) {
                XCTAssertEqual(result.shader, "generic4", "\(scene.id) \(result.pass.rawValue)")
            }
            let keys = Set(byKey.compactMap { $0.keyMatch.flatMap(fixture.dxsKey) })
            let produced = Set(results.flatMap(\.matches.values))
                .union(scene.captures.filter { fixture.dxsKey($0).map(keys.contains) == true })
            let missing = scene.captures.filter { !produced.contains($0) }
                .compactMap { fixture.captures[$0] }.map { "n=\($0.n) \($0.name)" }
            print("scene \(scene.id): matched \(matched.count)/\(results.count) draws byte for byte, "
                + "\(byKey.count) by .dxs key; captures no draw produced (\(missing.count)): "
                + missing.joined(separator: ", "))
            summary.append("\(scene.id) \(matched.count)/\(results.count) (+\(byKey.count) by key)")
        }
        print("matched draws per scene: \(summary.joined(separator: "; ")); .dxs keys compared: \(keysChecked)")
    }

    func testDroppingHDRFlagLosesMatches() throws {
        let fixture = try fixture()
        var baseline = 0
        var withoutHDR = 0
        for scene in ParityProgramCaptureFixture.scenes {
            baseline += try fixture.run(scene.id, captureRange: scene.captures).count(where: \.matched)
            withoutHDR += try fixture.run(scene.id, captureRange: scene.captures) { description, _ in
                description.engineFlags.hdr = false
            }.count(where: \.matched)
        }
        print("negative control: matched draws \(baseline) with engine flags, \(withoutHDR) with HDR dropped")
        XCTAssertLessThan(withoutHDR, baseline)
    }

    /// TEXnFORMAT for samplers without `"formatcombo": true` too; any extra define breaks a match, so writing them
    /// through the pass JSON stands in for the resolver's E segment.
    func testIgnoringFormatComboLosesMatches() throws {
        let fixture = try fixture()
        var baseline = 0
        var everySampler = 0
        for scene in ParityProgramCaptureFixture.scenes {
            baseline += try fixture.run(scene.id, captureRange: scene.captures).count(where: \.matched)
            everySampler += try fixture.run(scene.id, captureRange: scene.captures) { description, assets in
                let sources = WPEParityProgramResolver.expandedSources(shader: description.material.shader,
                                                                       sources: assets)
                let samplers = WPEShaderAnnotationCombos(vertexSource: sources.vertex,
                                                         fragmentSource: sources.fragment).samplers
                for (slot, format) in description.engineFlags.textureFormats where samplers[slot]?.formatCombo != true {
                    description.material.combos["TEX\(slot)FORMAT"] = format
                }
            }.count(where: \.matched)
        }
        print("negative control: matched draws \(baseline) with formatcombo, \(everySampler) ignoring it")
        XCTAssertLessThan(everySampler, baseline)
    }
}
