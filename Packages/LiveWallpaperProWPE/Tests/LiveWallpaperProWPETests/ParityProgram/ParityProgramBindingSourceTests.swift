import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import os
import XCTest

final class ParityProgramBindingSourceTests: XCTestCase {
    private struct Fixture {
        let scene: WPEParityProgramScene
        let reads: OSAllocatedUnfairLock<[String: Int]>
    }

    private func makeScene(noise: String) throws -> Fixture {
        var files = try [
            "models/counted.json": JSONSerialization.data(withJSONObject: ["material": "materials/counted.json"]),
            "materials/counted.json": JSONSerialization.data(withJSONObject: [
                "passes": [["shader": "counted", "blending": "normal", "constantshadervalues": ["speed": 3]]],
            ]),
        ]
        files["shaders/counted.vert"] = Data("void main() {}".utf8)
        files["shaders/counted.frag"] = Data("""
        uniform sampler2D g_Texture1; // {"default":"\(noise)"}
        uniform float g_Speed; // {"material":"speed","default":2}
        void main() {}
        """.utf8)
        let objects = (1 ... 3).map { id -> [String: Any] in
            ["id": id, "image": "models/counted.json", "size": "32 32", "origin": "16 16 0"]
        }
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32]],
            "objects": objects,
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in BindingSourceNoScripts() })
        let snapshot = files
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("binding-source-\(UUID().uuidString)")
        let assets = WPEParityProgramAssets(sources: [.lookup(root) { path in
            reads.withLock { $0[path, default: 0] += 1 }
            return snapshot[path]
        }])
        return Fixture(scene: WPEParityProgramScene(document: document, assets: assets, settings: .init()), reads: reads)
    }

    private static func floats(_ value: WPECBufferValue?) -> [Float]? {
        switch value {
        case let .float(number)?: [number]
        case let .vector(vector)?: vector
        default: nil
        }
    }

    private func countedBindings(_ fixture: Fixture, frame: WPEParityFrame) -> [WPEParityProgramBinding] {
        let bindings = WPEParityProgramBuilder.bindings(frame: frame, scene: fixture.scene)
        return frame.draws.compactMap { index, draw in
            guard case let .scene(draw) = draw, draw.shader == "counted" else { return nil }
            return bindings[index]
        }
    }

    func testRepeatedBindingsReadTheShaderSourceOnce() throws {
        let fixture = try makeScene(noise: "util/noise")
        let composed = try frame(fixture)
        fixture.reads.withLock { $0 = [:] }
        for call in 0 ..< 2 {
            let bindings = countedBindings(fixture, frame: composed)
            XCTAssertEqual(bindings.count, 3, "call \(call)")
            for binding in bindings {
                XCTAssertEqual(binding.textures[1], .asset("util/noise"), "call \(call)")
                XCTAssertEqual(Self.floats(binding.constants[.fragment]?["g_Speed"]), [3], "call \(call)")
            }
        }
        XCTAssertLessThanOrEqual(fixture.reads.withLock { $0["shaders/counted.frag", default: 0] }, 1)
    }

    func testEachWallpaperBindsItsOwnShaderDefaults() throws {
        let noise = try makeScene(noise: "util/noise")
        _ = try countedBindings(noise, frame: frame(noise))
        let other = try makeScene(noise: "util/other")
        let bindings = try countedBindings(other, frame: frame(other))
        XCTAssertEqual(bindings.count, 3)
        for binding in bindings {
            XCTAssertEqual(binding.textures[1], .asset("util/other"))
        }
    }

    private func frame(_ fixture: Fixture) throws -> WPEParityFrame {
        try WPEParityFrameComposer.compose(scene: fixture.scene.scene, post: fixture.scene.postProcess)
    }
}

private struct BindingSourceNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
