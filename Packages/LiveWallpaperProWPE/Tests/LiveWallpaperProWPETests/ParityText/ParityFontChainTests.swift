import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityFontChainTests: XCTestCase {
    static let assetsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
    static let notoSans = "fonts/NotoSans-Regular.ttf"

    /// A library reading only the WPE assets root; skips when Wallpaper Engine is not installed.
    static func makeLibrary() throws -> WPEParityFontLibrary {
        let font = assetsRoot.appendingPathComponent(notoSans)
        guard FileManager.default.fileExists(atPath: font.path) else {
            throw XCTSkip("Wallpaper Engine assets fonts not installed at \(assetsRoot.path)")
        }
        let assets = WPEParityProgramAssets(sources: [.directory(assetsRoot)])
        return WPEParityFontLibrary(assets: assets)
    }

    func testPointSizeIsClampedToOneThrough256() throws {
        let library = try Self.makeLibrary()
        XCTAssertEqual(library.chain(fontPath: Self.notoSans, pointSize: 0).faces.first?.pointSize, 1)
        XCTAssertEqual(library.chain(fontPath: Self.notoSans, pointSize: 300).faces.first?.pointSize, 256)
        XCTAssertEqual(library.chain(fontPath: Self.notoSans, pointSize: 32).faces.first?.pointSize, 32)
    }

    func testNotoSansMetricsAt32PointAnd300Dpi() throws {
        let face = try XCTUnwrap(Self.makeLibrary().chain(fontPath: Self.notoSans, pointSize: 32).faces.first)
        XCTAssertEqual(face.ascender, 143)
        XCTAssertEqual(face.descender, -40)
        XCTAssertEqual(face.height, 182)
        XCTAssertEqual(face.familyName, "Noto Sans")
    }

    func testUnreadablePathFallsBackToArial() throws {
        let chain = try Self.makeLibrary().chain(fontPath: "fonts/does-not-exist.ttf", pointSize: 32)
        XCTAssertEqual(chain.faces.count, 1)
        XCTAssertEqual(chain.faces.first?.familyName, "Arial")
    }

    func testSystemFontArialResolvesToArialFamily() throws {
        let chain = try Self.makeLibrary().chain(fontPath: "systemfont_arial", pointSize: 32)
        XCTAssertEqual(chain.faces.first?.familyName, "Arial")
        XCTAssertEqual(chain.faces.first?.postScriptName, "ArialMT")
    }

    /// System fonts are read by FreeType from their files instead of being copied whole into memory.
    func testSystemFontsOpenFromTheirFilesAndCollectionsPickThePostScriptFace() throws {
        let library = try Self.makeLibrary()
        let collection = try XCTUnwrap(library.chain(fontPath: "systemfont_helvetica_neue", pointSize: 32).faces.first)
        XCTAssertEqual(collection.postScriptName, "HelveticaNeue")
        XCTAssertNil(collection.bytes)
        let asset = try XCTUnwrap(library.chain(fontPath: Self.notoSans, pointSize: 32).faces.first)
        XCTAssertNotNil(asset.bytes)
    }

    func testGlyphBoxAndRasterOfCapitalH() throws {
        let face = try XCTUnwrap(Self.makeLibrary().chain(fontPath: Self.notoSans, pointSize: 32).faces.first)
        let capitalH: UInt32 = 43
        XCTAssertEqual(face.glyphBox(capitalH), WPEParityGlyphBox(xMin: 12, yMin: 0, xMax: 86, yMax: 95))
        let bitmap = try XCTUnwrap(face.rasterize(capitalH))
        XCTAssertEqual(bitmap.pixelMode, .gray)
        XCTAssertEqual(bitmap.width, 86 - 12)
        XCTAssertEqual(bitmap.rows, 95)
        XCTAssertEqual(bitmap.pixels.count, bitmap.width * bitmap.rows)
        XCTAssertTrue(bitmap.pixels.contains { $0 != 0 })
    }
}
