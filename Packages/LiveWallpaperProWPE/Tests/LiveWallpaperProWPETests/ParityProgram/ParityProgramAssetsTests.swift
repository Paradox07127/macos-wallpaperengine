import Foundation
@testable import LiveWallpaperProWPE
import os
import XCTest

final class ParityProgramAssetsTests: XCTestCase {
    private static func lookup(_ root: String, _ files: [String: String]) -> WPEParityProgramAssets.Source {
        .lookup(URL(fileURLWithPath: "/lookup/\(root)", isDirectory: true)) { files[$0].map { Data($0.utf8) } }
    }

    private static let wallpaper = lookup("2370640409", [
        "scene.json": #"{"objects":[{"id":1}]}"#,
        "materials/layer.json": #"{"passes":[{"shader":"probe"}]}"#,
        "materials/layer.tex": "TEXV0005\0TEXI0001\0\u{9}\0\0\0\u{2}\0\0\0" + String(repeating: "\0", count: 16),
        "shaders/probe.frag": "#include \"common.h\"\nvoid main() {}\n",
        "shaders/shared.h": "// wallpaper shared\n",
    ])
    private static let wpe = lookup("wpe", [
        "shaders/common.h": "// wpe common\n",
        "shaders/shared.h": "// wpe shared\n",
    ])

    func testLookupSourceServesSceneMaterialAndShaderInclude() {
        let assets = WPEParityProgramAssets(sources: [Self.wallpaper, Self.wpe])

        XCTAssertEqual(assets.json("scene.json")?["objects"]?[0]?["id"], .number(1))
        XCTAssertEqual(assets.json("materials/layer.json")?["passes"]?[0]?["shader"], .string("probe"))
        XCTAssertEqual(assets.textureHeader(named: "layer"), WPEParityProgramTextureHeader(format: 9, flags: 2))
        XCTAssertNil(assets.data("materials/missing.json"))
        let fragment = WPEParityProgramResolver.expandedSources(shader: "probe", sources: assets).fragment
        XCTAssertEqual(fragment, "// wpe common\n\nvoid main() {}\n")
        XCTAssertEqual(assets.roots.map(\.lastPathComponent), ["2370640409", "wpe"])
    }

    func testWallpaperSourceComesBeforeAssetsRoots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shaders/shared.h")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("// directory shared\n".utf8).write(to: file)
        func shared(_ sources: [WPEParityProgramAssets.Source]) -> String? {
            WPEParityProgramAssets(sources: sources).data("shaders/shared.h").flatMap { String(bytes: $0, encoding: .utf8) }
        }

        XCTAssertEqual(shared([Self.wallpaper, Self.wpe]), "// wallpaper shared\n")
        XCTAssertEqual(shared([Self.wallpaper, .directory(directory)]), "// wallpaper shared\n")
        XCTAssertEqual(shared([.directory(directory), Self.wpe]), "// directory shared\n")
        // Negative control: with the assets root first, its file shadows the wallpaper's.
        XCTAssertEqual(shared([Self.wpe, Self.wallpaper]), "// wpe shared\n")
    }

    func testResolverRewritesOneShaderAndDefineListOncePerAssets() throws {
        let files = [
            "shaders/probe.vert": "void main() {}\n",
            "shaders/probe.frag": "#include \"common.h\"\nvoid main() {}\n",
            "shaders/common.h": "// common\n",
        ]
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let assets = WPEParityProgramAssets(sources: [.lookup(URL(fileURLWithPath: "/lookup/memo", isDirectory: true)) {
            reads.withLock { $0 += 1 }
            return files[$0].map { Data($0.utf8) }
        }])
        func description(_ path: String) -> WPEParityProgramDescription {
            WPEParityProgramDescription(material: WPEParityProgramMaterial(shader: "probe", path: path, combos: ["ALPHA": 1]),
                                        engineFlags: WPEEngineComboFlags(), boundTextures: [:])
        }

        let first = try WPEParityProgramResolver.resolve(description("materials/a.json"), sources: assets)
        let readsAfterFirst = reads.withLock { $0 }
        let second = try WPEParityProgramResolver.resolve(description("materials/b.json"), sources: assets)

        XCTAssertGreaterThan(readsAfterFirst, 0)
        XCTAssertEqual(second, first)
        XCTAssertEqual(reads.withLock { $0 }, readsAfterFirst, "second resolve read the shader files again")
        let uncached = try WPEParityProgramResolver.resolve(description("materials/a.json"),
                                                            sources: MemorySources(files: files))
        XCTAssertEqual(first, uncached)
    }

    func testHLSLProgramEqualityFollowsEveryStageByte() {
        let a = WPEHLSLProgram(vertex: Array("vs".utf8), geometry: nil, fragment: Array("ps".utf8))
        var b = WPEHLSLProgram(vertex: Array("vs".utf8), geometry: nil, fragment: Array("ps".utf8))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)

        b.fragment?[1] = UInt8(ascii: "x")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, WPEHLSLProgram(vertex: Array("vs".utf8), geometry: [], fragment: Array("ps".utf8)))
    }
}

private struct MemorySources: WPEShaderSourceProviding {
    let files: [String: String]

    func shaderSource(named name: String) -> [UInt8]? {
        files[name].map { Array($0.utf8) }
    }
}
