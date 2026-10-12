import Foundation
@testable import LiveWallpaperProWPE
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
}
