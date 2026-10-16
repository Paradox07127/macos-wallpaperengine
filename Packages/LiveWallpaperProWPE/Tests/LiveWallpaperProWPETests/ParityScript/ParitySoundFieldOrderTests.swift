import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParitySoundFieldOrderTests: XCTestCase {
    func testNativeSoundScalarBindingOrderKeepsObjectGlobalsBeforeInit() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript")
        let data = try Data(contentsOf: fixtures.appendingPathComponent("cold-sound-field-order-v2/scene.json"))
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in SoundFieldOrderNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let base = try Data(contentsOf: fixtures.appendingPathComponent("baseclasses.js"))
        let assets = WPEParityProgramAssets(sources: [.lookup(fixtures) { path in
            path == "scripts/jsclasses/baseclasses.js" ? base : nil
        }])
        var messages: [String] = []
        var markers: [[String: Any]] = []
        var diagnostics: [String] = []
        let engine = try WPEParityScriptEngine.prepare(document: document, state: &state, configuration: .init(
            assets: assets, canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32), log: { _, message in
                diagnostics.append(message)
                let prefix = "AUDIT_SS_01A13310 "
                if message.hasPrefix(prefix), let data = message.dropFirst(prefix.count).data(using: .utf8),
                   let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    messages.append(message)
                    markers.append(row)
                }
            }
        ), volume: { _, _ in XCTFail("Pure phase markers must not request a sound volume write") },
        command: { _, _, _ in XCTFail("Pure phase markers must not request a sound command"); return false })
        let roles = ["sound-a-maxtime", "sound-a-mintime", "sound-a-volume", "sound-b-volume"]
        let prepared = markers.filter { ($0["role"] as? String)?.hasPrefix("sound-") == true }
        XCTAssertEqual(prepared.compactMap { $0["role"] as? String }, roles)
        XCTAssertEqual(prepared.compactMap { $0["phase"] as? String }, [String](repeating: "module-global", count: 4))
        try engine.start(state: &state)
        engine.tick(dt: 0, state: &state)

        let sound = markers.filter { ($0["role"] as? String)?.hasPrefix("sound-") == true }
        let expected = ["module-global", "init", "first-update"].flatMap { phase in roles.map { $0 + "/" + phase } }
        XCTAssertEqual(sound.compactMap { row -> String? in
            guard let role = row["role"] as? String, let phase = row["phase"] as? String else { return nil }
            return role + "/" + phase
        }, expected)
        XCTAssertEqual(sound.compactMap { $0["localSeq"] as? Int }, [Int](repeating: 1, count: 4)
            + [Int](repeating: 2, count: 4) + [Int](repeating: 3, count: 4))
        XCTAssertEqual(sound.compactMap { $0["frame"] as? Int }, [Int](repeating: 0, count: 8) + [Int](repeating: 1, count: 4))
        XCTAssertTrue(markers.allSatisfy { $0["nonce"] as? String == "ss-b3ed47df60a84112"
                && $0["schema"] as? String == "lw.wpe.s11.cold-order.marker.v2"
        })
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        // Retain all original general markers without claiming native general early-init ordering here.
        XCTAssertFalse(diagnostics.contains { $0.contains("general.bloom script is unsupported") })
        print("S10 cold-order actual JSC markers (Sound subset qualified only):\n" + messages.joined(separator: "\n"))
    }
}

private struct SoundFieldOrderNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
