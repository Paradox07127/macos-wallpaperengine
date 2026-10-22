import CFreeType
import CoreText
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityFontChainTests: XCTestCase {
    static let assetsRoot = PackageTestAssets.root
    static let notoSans = "fonts/NotoSans-Regular.ttf"

    /// Hand-authored SFNT with a single raw BGRA CBLC/CBDT strike at 100 ppem and no outlines. U+0041 maps to
    /// glyph 1: a 2×3 bitmap, left bearing -1, top bearing 2, advance 3. Fixed bytes avoid platform font fallback.
    /// SHA256 e7ed41e98aeb72194ee67f077b35a5d312ae25fd2d457971d72fe48251c5ac03.
    private static let bitmapOnlyFont = """
    AAEAAAAJAIAAAwAQQ0JEVAIGO3gAAACcAAAAIUNCTENwaCSBAAAAwAAAAFBjbWFwAAwAdAAAARAAAAAs
    aGVhZF8UPb4AAAE8AAAANmhoZWEABAAFAAABdAAAACRobXR4AAb//wAAAZgAAAAIbWF4cAACUAAAAAGg
    AAAABm5hbWUH/xB2AAABqAAAAG5wb3N0AAMAAAAAAhgAAAAgAAMAAAMC/wIDChQe/ygyPP9GUFr/ZG54
    /4KMlv+gqrT/AAAAAAMAAAAAAAEAAAA4AAAAGAAAAAEAAAAAAv8DAQAA/wAC/wAAAv8DAQAA/wAC/wAA
    AAEAAWRkIAEAAQABAAAACAABAAEAAAAEAAAAAAAAAB0AAAABAAMAAQAAAAwABAAgAAAABAAEAAEAAABB
    //8AAABB////wAABAAAAAAABAAAAAQAAjwgdrF8PPPUAAABkAAAAAAAAAAAAAAAAAAAAAP////8AAQAC
    AAAAZAACAAAAAAAAAAEAAAAC//8AAAAD//8AAAABAAEAAAAAAAAAAAAAAAAAAAACAAMAAAAD//8AAFAA
    AAIAAAAAAAIAHgADAAEECQABACoAAAADAAEECQAGACYAKgBQAGEAcgBpAHQAeQAgAEIAaQB0AG0AYQBw
    ACAARgBpAHgAdAB1AHIAZQBQAGEAcgBpAHQAeQBCAGkAdABtAGEAcABGAGkAeAB0AHUAcgBlAAAAAwAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
    """

    /// Read the pinned, OFL-licensed test font; missing repository fixtures are failures.
    static func makeLibrary() throws -> WPEParityFontLibrary {
        let font = assetsRoot.appendingPathComponent(notoSans)
        _ = try Data(contentsOf: font)
        let assets = WPEParityProgramAssets(sources: [.directory(assetsRoot)])
        return WPEParityFontLibrary(assets: assets)
    }

    static func makeLibraryWithFixedFallbacks() throws -> WPEParityFontLibrary {
        let bindings = [
            ("Arial", "TestFontCollection.ttc", "NotoSans-Regular"),
            ("Helvetica Neue", "TestFontCollection.ttc", "RobotoMono-Regular"),
            ("Apple Symbols", "TestSymbols-Regular.otf", "LoomscreenTestSymbols-Regular"),
            ("PingFang SC", "TestCJK-Regular.otf", "LoomscreenTestCJK-Regular"),
            ("Apple SD Gothic Neo", "NotoSans-Regular.ttf", "NotoSans-Regular"),
        ]
        let descriptors = try Dictionary(uniqueKeysWithValues: bindings.map { family, file, postScript in
            try (family, PackageTestAssets.fontDescriptor(file: file, postScriptName: postScript))
        })
        return WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(assetsRoot)]),
                                    systemFontForTesting: { family, pointSize in
                                        descriptors[family].map {
                                            CTFontCreateWithFontDescriptor($0, CGFloat(pointSize * 300 / 72), nil)
                                        }
                                    })
    }

    func testPointSizeIsClampedToOneThrough256() throws {
        let library = try Self.makeLibrary()
        XCTAssertEqual(library.chain(fontPath: Self.notoSans, pointSize: 0).faces.first?.pointSize, 1)
        XCTAssertEqual(library.chain(fontPath: Self.notoSans, pointSize: 300).faces.first?.pointSize, 256)
        XCTAssertEqual(library.chain(fontPath: Self.notoSans, pointSize: 32).faces.first?.pointSize, 32)
    }

    func testDistinctFloatSizesDoNotAliasWithinOneBitmapAtlasKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try XCTUnwrap(Data(base64Encoded: Self.bitmapOnlyFont, options: .ignoreUnknownCharacters))
        try data.write(to: directory.appendingPathComponent("bitmap.ttf"))
        let library = WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(directory)]))
        let first: Float = 32
        let second = first.nextUp
        XCTAssertEqual(WPEParityGlyphAtlasInstance.key(fontPath: "bitmap.ttf", pointSize: first),
                       WPEParityGlyphAtlasInstance.key(fontPath: "bitmap.ttf", pointSize: second))
        let a = library.chain(fontPath: "bitmap.ttf", pointSize: first)
        let b = library.chain(fontPath: "bitmap.ttf", pointSize: second)
        XCTAssertFalse(a === b)
        XCTAssertEqual(a.pointSize, first)
        XCTAssertEqual(b.pointSize, second)
        XCTAssertFalse(a.faces.isEmpty)
        XCTAssertFalse(b.faces.isEmpty)
        XCTAssertTrue(a === library.chain(fontPath: "bitmap.ttf", pointSize: first))
        XCTAssertTrue(b === library.chain(fontPath: "bitmap.ttf", pointSize: second))
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

    func testSystemFontTableResolvesItsFamiliesAndConsolasStaysMonospace() throws {
        let library = try Self.makeLibrary()
        XCTAssertEqual(library.chain(fontPath: "systemfont_comicsans", pointSize: 32).faces.first?.postScriptName,
                       "ComicSansMS")
        XCTAssertEqual(library.chain(fontPath: "systemfont_sansserif", pointSize: 32).faces.first?.postScriptName,
                       "MicrosoftSansSerif")
        let consolas = try XCTUnwrap(library.chain(fontPath: "systemfont_consolas", pointSize: 32).faces.first)
        XCTAssertNotEqual(consolas.face.pointee.face_flags & FT_Long(FT_FACE_FLAG_FIXED_WIDTH), 0)
    }

    func testSystemFontOutsideTheTableIsAnAssetPathEndingInArial() throws {
        let chain = try Self.makeLibrary().chain(fontPath: "systemfont_helvetica_neue", pointSize: 32)
        XCTAssertEqual(chain.faces.map(\.familyName), ["Arial"])
    }

    /// System fonts are read by FreeType from their files instead of being copied whole into memory.
    func testSystemFontsOpenFromTheirFilesAndCollectionsPickThePostScriptFace() throws {
        let descriptor = try PackageTestAssets.fontDescriptor(file: "TestFontCollection.ttc", postScriptName: "RobotoMono-Regular")
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(32 * 300) / 72, nil)
        let url = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        XCTAssertEqual(url.lastPathComponent, "TestFontCollection.ttc")
        let assets = WPEParityProgramAssets(sources: [.directory(Self.assetsRoot)])
        let collection = try XCTUnwrap(WPEParityFontLoader(assets: assets).face(for: font, pointSize: 32))
        XCTAssertEqual(collection.familyName, "Roboto Mono")
        XCTAssertEqual(collection.postScriptName, "RobotoMono-Regular")
        XCTAssertEqual(collection.face.pointee.face_index, 1)
        XCTAssertNil(collection.bytes)
        XCTAssertNotNil(try Self.makeLibrary().chain(fontPath: Self.notoSans, pointSize: 32).faces.first?.bytes)
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

    func testBitmapOnlyColorGlyphKeepsItsRenderedBearingsAndReachesTheColorMesh() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.bitmapOnlyFont, options: .ignoreUnknownCharacters))
        let library = try XCTUnwrap(WPEParityFreeTypeLibrary())
        let face = try XCTUnwrap(WPEParityFontFace(library: library, bytes: WPEParityFontBytes(data), path: nil,
                                                   source: "bitmap-fixture", faceIndex: 0, pointSize: 24))
        XCTAssertNil(face.glyphBox(1), "this input must exercise the path with no outline")
        let glyph = try XCTUnwrap(face.layoutGlyph(1))
        XCTAssertTrue(glyph.isColor)
        XCTAssertEqual(glyph.box, WPEParityGlyphBox(xMin: -1, yMin: -1, xMax: 1, yMax: 2))
        let bitmap = try XCTUnwrap(face.rasterize(1))
        XCTAssertEqual(bitmap.pixelMode, .bgra)
        XCTAssertEqual([bitmap.width, bitmap.rows], [2, 3])
        XCTAssertEqual(Array(bitmap.pixels.prefix(4)), [10, 20, 30, 255])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("bitmap.ttf"))
        let planner = WPEParityTextPlanner(assets: WPEParityProgramAssets(sources: [.directory(directory)]))
        let planned = try planner.plan(WPEParityTextObject(json: .object([
            "id": .string("bitmap"), "font": .string("bitmap.ttf"), "text": .string("A"),
            "pointsize": .number(24),
        ])), effectCount: 0)
        let mesh = try XCTUnwrap(planned.layout.mesh)
        XCTAssertTrue(mesh.mono.glyphKeys.isEmpty)
        XCTAssertEqual(mesh.color.glyphKeys, [1])
        XCTAssertEqual(mesh.color.vertices.map { SIMD2($0.x, $0.y) },
                       [SIMD2(-1, 2), SIMD2(1, 2), SIMD2(-1, -1), SIMD2(1, -1)])
        XCTAssertEqual(planner.atlases[planned.atlasKey]?.colorGroups[1]?.entry(forKey: 1)?.references, 1)
    }
}
