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

    /// 幅 (e5 b9 85) and 包 (e5 8c 85) carry a 0x85 byte; annotation lines end only at CR/LF (140162100.c:113).
    func testUTF8AnnotationNamesAndWholeLinesSurviveDeclarationParse() {
        let assets = WPEParityProgramAssets(sources: [Self.lookup("line", [
            "shaders/line.vert": "void main() {}",
            "shaders/line.frag": """
            uniform vec3 u_curveColor; // {"default":"1.0 1.0 1.0","material":"曲线颜色","type":"color"}
            uniform float u_amplitude; // {"material":"整体振幅","default":0.4}
            // [COMBO] {"material":"包络","combo":"TRANSPARENCY","type":"options","default":1}
            uniform float u_separator; // {"material":"a\u{2028}b","default":0}
            // [COMBO] {"material":"c\u{85}d","combo":"SEPARATOR","type":"options","default":2}
            void main() {}
            """,
        ])])

        let declarations = assets.shaderDeclarations("line")
        XCTAssertEqual(declarations.uniforms[.fragment]?["u_curveColor"]?.material, "曲线颜色")
        XCTAssertEqual(declarations.uniforms[.fragment]?["u_amplitude"]?.material, "整体振幅")
        XCTAssertEqual(declarations.annotations.defaults["TRANSPARENCY"], 1)
        XCTAssertEqual(declarations.uniforms[.fragment]?["u_separator"]?.material, "a\u{2028}b")
        XCTAssertEqual(declarations.annotations.defaults["SEPARATOR"], 2)
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

    func testDescriptionReadsShaderFilesAndTextureHeadersOncePerAssets() {
        func tex(_ format: Character) -> String {
            "TEXV0005\0TEXI0001\0\(format)\0\0\0\u{2}\0\0\0" + String(repeating: "\0", count: 16)
        }
        let files = [
            "shaders/probe.vert": "void main() {}\n",
            "shaders/probe.frag": """
            #include "common.h"
            uniform sampler2D g_Texture0; // {"formatcombo":true}
            uniform sampler2D g_Texture1; // {"default":"util/noise"}
            void main() {}

            """,
            "shaders/common.h": "// common\n",
            "materials/a.tex": tex("\u{8}"),
            "materials/b.tex": tex("\u{9}"),
            "materials/util/noise.tex": tex("\u{7}"),
        ]
        let source = { (reads: OSAllocatedUnfairLock<[String: Int]>?) in
            WPEParityProgramAssets.Source.lookup(URL(fileURLWithPath: "/lookup/describe", isDirectory: true)) { path in
                reads?.withLock { $0[path, default: 0] += 1 }
                return files[path].map { Data($0.utf8) }
            }
        }
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let assets = WPEParityProgramAssets(sources: [source(reads)])
        func shaderReads() -> Int {
            reads.withLock { $0.filter { $0.key.hasPrefix("shaders/") }.values.reduce(0, +) }
        }
        func describe(_ texture: String, _ assets: WPEParityProgramAssets) -> WPEParityProgramDescription {
            WPEParityProgramBuilder.description(WPEParityProgramMaterial(shader: "probe", textures: [0: texture]),
                                                engineFlags: WPEEngineComboFlags(), assets: assets)
        }

        let first = describe("a", assets)
        let shaderReadsAfterFirst = shaderReads()
        let noiseReadsAfterFirst = reads.withLock { $0["materials/util/noise.tex"] }
        let second = describe("b", assets)

        XCTAssertGreaterThan(shaderReadsAfterFirst, 0)
        XCTAssertEqual(shaderReads(), shaderReadsAfterFirst, "second description read the shader files again")
        XCTAssertEqual(noiseReadsAfterFirst, 1)
        XCTAssertEqual(reads.withLock { $0["materials/util/noise.tex"] }, 1,
                       "second description read the default texture again")
        XCTAssertEqual(first.engineFlags.textureFormats, [0: 8, 1: 7])
        XCTAssertEqual(second.engineFlags.textureFormats, [0: 9, 1: 7])
        XCTAssertEqual(first, describe("a", WPEParityProgramAssets(sources: [source(nil)])))
        XCTAssertEqual(second, describe("b", WPEParityProgramAssets(sources: [source(nil)])))
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
