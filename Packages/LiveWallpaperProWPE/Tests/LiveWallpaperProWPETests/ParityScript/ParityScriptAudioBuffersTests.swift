import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptAudioBuffersTests: XCTestCase {
    private static let script = "const b16=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16), "
        + "b32=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_32), "
        + "b64=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64); export function update(v){ return "
        + "[b64.average[0], b32.average[0], b16.average[0], b16.left[0], b16.right[0]].join(','); }"

    func testAverageMaxPoolsTheChannelMean() throws {
        var bins = [Float](repeating: 0, count: 128)
        (bins[0], bins[65]) = (1, 1)
        let (engine, value) = try run(bins)
        XCTAssertEqual(value, .string("0.5,0.5,0.5,1,1"))
        XCTAssertEqual(engine.audioBuffer(resolution: 16)?[32], 0.5)
    }

    func testSixteenPoolsTheThirtyTwoAverage() throws {
        var bins = [Float](repeating: 0, count: 128)
        (bins[0], bins[66]) = (1, 1)
        let (engine, _) = try run(bins)
        let half = try XCTUnwrap(engine.audioBuffer(resolution: 32))
        XCTAssertEqual(half[64], 0.5)
        XCTAssertEqual(half[65], 0.5)
        XCTAssertEqual(engine.audioBuffer(resolution: 16)?[32], 0.5)
    }

    func testMonoKeepsAverageEqualToLeft() throws {
        let levels: [Float] = [0, 0.25, 0.5, 1]
        let channel = (0 ..< 64).map { levels[($0 * 7 + $0 / 3) % 4] }
        let (engine, _) = try run(channel + channel)
        for resolution in [16, 32, 64] {
            let buffer = try XCTUnwrap(engine.audioBuffer(resolution: resolution))
            XCTAssertEqual(Array(buffer[2 * resolution ..< 3 * resolution]), Array(buffer[0 ..< resolution]),
                           "resolution \(resolution)")
        }
    }

    private func run(_ bins: [Float]) throws -> (WPEParityScriptEngine, WPEParitySceneState.ScriptValue?) {
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "text": ["value": "seed", "script": Self.script]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64)
        ))
        try engine.start(state: &state)
        engine.updateAudio(bins)
        engine.tick(dt: 0.1, state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        return (engine, state.scriptField("text", of: "1"))
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
