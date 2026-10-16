#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import os
import XCTest

/// A relayout binds every draw again; it must not reread the wallpaper's shader files to do so.
final class WPEParityFramePlanShaderReadTests: XCTestCase {
    func testRelayoutDoesNotRereadShaderSources() throws {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        var files = try [
            "models/counted.json": JSONSerialization.data(withJSONObject: ["material": "materials/counted.json"]),
            "materials/counted.json": JSONSerialization.data(withJSONObject: [
                "passes": [["shader": "counted", "blending": "normal", "constantshadervalues": ["speed": 3]]],
            ]),
        ]
        files["shaders/counted.vert"] = Data("void main() {}".utf8)
        files["shaders/counted.frag"] = Data("""
        uniform sampler2D g_Texture1; // {"default":"util/noise"}
        uniform float g_Speed; // {"material":"speed","default":2}
        void main() {}
        """.utf8)
        let objects = (1 ... 50).map { id -> [String: Any] in
            ["id": id, "image": "models/counted.json", "size": "32 32", "origin": "16 16 0"]
        }
        let scene: [String: Any] = ["camera": ["eye": "0 0 1", "center": "0 0 0", "up": "0 1 0"],
                                    "general": ["orthogonalprojection": ["width": 32, "height": 32],
                                                "clearcolor": "0 0 0", "cameraparallax": false, "camerashake": false],
                                    "objects": objects]
        let sourceFiles = files
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let root = FileManager.default.temporaryDirectory.appending(path: "parity-shader-read-\(UUID().uuidString)")
        let assets = WPEParityProgramAssets(sources: [.lookup(root) { path in
            reads.withLock { $0[path, default: 0] += 1 }
            return sourceFiles[path]
        }, .directory(engine)])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in ShaderReadNoScripts() })
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false), width: 32, height: 32)

        reads.withLock { $0 = [:] }
        let layout = try plan.layout(effects: plan.state)

        XCTAssertEqual(reads.withLock { $0["shaders/counted.frag", default: 0] }, 0)
        let relaid = try XCTUnwrap(layout.bindings.first)
        let loaded = try XCTUnwrap(plan.layout.bindings.first)
        XCTAssertEqual(relaid.filter { $0.value.textures[1] == .asset("util/noise") }.count, 50)
        XCTAssertEqual(relaid.mapValues(\.textures), loaded.mapValues(\.textures))
        XCTAssertEqual(Self.constants(relaid), Self.constants(loaded))
    }

    private static func constants(_ bindings: [Int: WPEParityProgramBinding]) -> [String] {
        bindings.flatMap { index, binding in
            binding.constants.flatMap { stage, values in
                values.map { name, value in "\(index) \(stage) \(name) \(value)" }
            }
        }.sorted()
    }
}

private struct ShaderReadNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
