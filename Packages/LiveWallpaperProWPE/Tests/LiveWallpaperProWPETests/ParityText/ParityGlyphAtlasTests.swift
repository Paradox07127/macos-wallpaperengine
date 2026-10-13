@testable import LiveWallpaperProWPE
import XCTest

final class ParityGlyphAtlasTests: XCTestCase {
    private func gray(_ width: Int, _ rows: Int, seed: Int = 0) -> WPEParityGlyphBitmap {
        WPEParityGlyphBitmap(
            width: width,
            rows: rows,
            pixelMode: .gray,
            pixels: (0 ..< width * rows).map { UInt8(1 + ($0 + seed) % 250) }
        )
    }

    private func pixel(_ atlas: WPEParityGlyphAtlas, _ x: Int, _ y: Int) -> UInt8 {
        atlas.pixels[(y * atlas.width + x) * atlas.format.bytesPerPixel]
    }

    private func rect(_ entry: WPEParityGlyphAtlasEntry?) -> [Int] {
        guard let entry else { return [] }
        return [entry.x0, entry.y0, entry.x1, entry.y1]
    }

    func testShelfFirstFitAndNewShelfOrigins() {
        var atlas = WPEParityGlyphAtlas(format: .r8)
        let sizes = [(10, 20), (30, 10), (5, 25), (460, 8), (6, 6), (3, 4), (2, 30), (4, 4)]
        let bitmaps = sizes.enumerated().map { gray($0.element.0, $0.element.1, seed: $0.offset) }
        let rects = bitmaps.enumerated().map { rect(atlas.insert(key: UInt32($0.offset + 1), bitmap: $0.element)) }

        XCTAssertEqual(rects, [
            [0, 0, 10, 20], [11, 0, 41, 10], [42, 0, 47, 25], [48, 0, 508, 8],
            [0, 26, 6, 32], [509, 0, 512, 4], [7, 26, 9, 56], [10, 26, 14, 30],
        ])
        XCTAssertEqual([atlas.width, atlas.height], [512, 512])
        XCTAssertEqual(atlas.entry(forKey: 1)?.uv, SIMD4<Float>(0, 0, 10.0 / 512, 20.0 / 512))
        XCTAssertEqual(atlas.entry(forKey: 5)?.uv, SIMD4<Float>(0, 26.0 / 512, 6.0 / 512, 32.0 / 512))
        XCTAssertEqual(atlas.entry(forKey: 6)?.uv, SIMD4<Float>(509.0 / 512, 0, 1, 4.0 / 512))

        for row in 0 ..< 6 {
            for column in 0 ..< 6 {
                XCTAssertEqual(pixel(atlas, column, 26 + row), bitmaps[4].pixels[row * 6 + column])
            }
        }
        for row in 0 ..< 20 {
            XCTAssertEqual(pixel(atlas, 10, row), 0)
        }
        for column in 0 ..< 10 {
            XCTAssertEqual(pixel(atlas, column, 20), 0)
        }
        for row in 0 ..< 10 {
            XCTAssertEqual(pixel(atlas, 41, row), 0)
        }
        for column in 11 ..< 41 {
            XCTAssertEqual(pixel(atlas, column, 10), 0)
        }
        for row in 0 ..< 6 {
            XCTAssertEqual(pixel(atlas, 6, 26 + row), 0)
        }

        // Entry 6 ends at x = 512; WPE clears its right gap at column 512 % 512, over entry 1's first column.
        for row in 0 ..< 4 {
            XCTAssertEqual(pixel(atlas, 0, row), 0)
        }
        XCTAssertEqual(pixel(atlas, 0, 4), bitmaps[0].pixels[4 * 10])
    }

    private func fillForEviction(_ atlas: inout WPEParityGlyphAtlas) -> WPEParityGlyphBitmap {
        let first = gray(200, 300, seed: 1)
        XCTAssertEqual(rect(atlas.insert(key: 1, bitmap: first)), [0, 0, 200, 300])
        XCTAssertEqual(rect(atlas.insert(key: 2, bitmap: gray(300, 200))), [201, 0, 501, 200])
        XCTAssertEqual(rect(atlas.insert(key: 3, bitmap: gray(100, 200))), [0, 301, 100, 501])
        return first
    }

    func testEvictionReusesReleasedEntryWithoutGrowing() throws {
        var atlas = WPEParityGlyphAtlas(format: .r8)
        let first = fillForEviction(&atlas)
        atlas.retain([1, 2, 3])
        atlas.release([1])

        let entry = try XCTUnwrap(atlas.insert(key: 4, bitmap: gray(150, 250, seed: 9)))

        XCTAssertEqual(rect(entry), [0, 0, 150, 250])
        XCTAssertNil(atlas.entry(forKey: 1))
        XCTAssertEqual(atlas.entry(forKey: 2)?.references, 1)
        XCTAssertEqual([atlas.width, atlas.height, atlas.generation], [512, 512, 0])
        for row in 0 ..< 250 {
            XCTAssertEqual(pixel(atlas, 150, row), 0)
        }
        for column in 0 ..< 150 {
            XCTAssertEqual(pixel(atlas, column, 250), 0)
        }
        XCTAssertEqual(pixel(atlas, 160, 10), first.pixels[10 * 200 + 160])
    }

    func testRetainedEntryIsNeverEvicted() throws {
        var atlas = WPEParityGlyphAtlas(format: .r8)
        _ = fillForEviction(&atlas)
        atlas.retain([1])

        let entry = try XCTUnwrap(atlas.insert(key: 4, bitmap: gray(150, 250)))

        XCTAssertEqual(rect(atlas.entry(forKey: 1)), [0, 0, 200, 300])
        XCTAssertEqual(atlas.entry(forKey: 1)?.references, 1)
        XCTAssertEqual([atlas.width, atlas.generation], [1024, 1])
        XCTAssertEqual(rect(entry), [502, 0, 652, 250])
    }

    func testDoublingHalvesUVsKeepsPixelsAndBumpsGeneration() throws {
        var atlas = WPEParityGlyphAtlas(format: .r8)
        let first = gray(400, 400, seed: 3)
        let before = try XCTUnwrap(atlas.insert(key: 1, bitmap: first))
        atlas.retain([1])
        XCTAssertEqual(before.uv, SIMD4<Float>(0, 0, 400.0 / 512, 400.0 / 512))

        let second = try XCTUnwrap(atlas.insert(key: 2, bitmap: gray(400, 400, seed: 5)))

        XCTAssertEqual([atlas.width, atlas.height, atlas.generation], [1024, 1024, 1])
        XCTAssertEqual(atlas.pixels.count, 1024 * 1024)
        let after = try XCTUnwrap(atlas.entry(forKey: 1))
        XCTAssertEqual(after.uv, before.uv * 0.5)
        XCTAssertEqual(rect(after), [0, 0, 400, 400])
        XCTAssertEqual(rect(second), [401, 0, 801, 400])
        XCTAssertEqual(second.uv, SIMD4<Float>(401.0 / 1024, 0, 801.0 / 1024, 400.0 / 1024))
        for (column, row) in [(0, 0), (399, 0), (0, 399), (399, 399), (123, 287)] {
            XCTAssertEqual(pixel(atlas, column, row), first.pixels[row * 400 + column])
        }
    }

    func testInsertNeedingMoreThan4096IsFullAndResetKeepsSizeAndPixels() {
        var atlas = WPEParityGlyphAtlas(format: .r8)
        let big = WPEParityGlyphBitmap(
            width: 4000, rows: 4000, pixelMode: .gray, pixels: Array(repeating: 7, count: 4000 * 4000)
        )
        XCTAssertEqual(rect(atlas.insert(key: 1, bitmap: big)), [0, 0, 4000, 4000])
        atlas.retain([1])
        XCTAssertEqual([atlas.width, atlas.height, atlas.generation], [4096, 4096, 3])
        _ = atlas.takeDirty()

        XCTAssertNil(atlas.insert(key: 2, bitmap: big))
        XCTAssertEqual([atlas.width, atlas.generation], [4096, 3])
        XCTAssertNotNil(atlas.entry(forKey: 1))
        XCTAssertFalse(atlas.isDirty)

        atlas.reset()
        XCTAssertNil(atlas.entry(forKey: 1))
        XCTAssertEqual([atlas.width, atlas.height, atlas.generation], [4096, 4096, 3])
        XCTAssertEqual(pixel(atlas, 0, 0), 7)
        XCTAssertFalse(atlas.isDirty)

        XCTAssertEqual(rect(atlas.insert(key: 2, bitmap: big)), [0, 0, 4000, 4000])
        XCTAssertEqual(atlas.width, 4096)
    }

    func testBGRAInputSwapsRedAndBlueWithoutUnpremultiplying() throws {
        var atlas = WPEParityGlyphAtlas(format: .rgba8)
        let bitmap = WPEParityGlyphBitmap(
            width: 2, rows: 1, pixelMode: .bgra, pixels: [10, 20, 30, 128, 1, 2, 3, 4]
        )

        let entry = try XCTUnwrap(atlas.insert(key: 7, bitmap: bitmap))

        XCTAssertEqual(rect(entry), [0, 0, 2, 1])
        XCTAssertEqual(atlas.pixels.count, 512 * 512 * 4)
        XCTAssertEqual(Array(atlas.pixels[0 ..< 12]), [30, 20, 10, 128, 3, 2, 1, 4, 0, 0, 0, 0])
    }

    func testDirtyFlagFollowsPixelChangesOnly() throws {
        var atlas = WPEParityGlyphAtlas(format: .r8)
        XCTAssertFalse(atlas.isDirty)
        XCTAssertEqual(atlas.contentGeneration, 0)

        let entry = try XCTUnwrap(atlas.insert(key: 1, bitmap: gray(4, 4)))
        XCTAssertTrue(atlas.isDirty)
        XCTAssertTrue(atlas.takeDirty())
        XCTAssertFalse(atlas.takeDirty())
        let uploaded = atlas.contentGeneration
        XCTAssertGreaterThan(uploaded, 0)

        XCTAssertEqual(atlas.entry(forKey: 1), entry)
        XCTAssertEqual(atlas.insert(key: 1, bitmap: gray(4, 4)), entry)
        XCTAssertFalse(atlas.isDirty)
        atlas.retain([1])
        atlas.release([1])
        XCTAssertEqual(atlas.contentGeneration, uploaded, "reference changes do not create a pixel version")
        atlas.reset()
        XCTAssertEqual(atlas.contentGeneration, uploaded, "reset retains the pixel buffer")
        XCTAssertFalse(atlas.isDirty)
        _ = try XCTUnwrap(atlas.insert(key: 2, bitmap: gray(4, 4, seed: 9)))
        XCTAssertGreaterThan(atlas.contentGeneration, uploaded)
    }

    func testInstanceKeysAndAtlasRouting() {
        XCTAssertEqual(
            WPEParityGlyphAtlasInstance.key(fontPath: "fonts/NotoSans.ttf", pointSize: 30.5),
            "fonts/NotoSans.ttf_1952"
        )
        XCTAssertEqual(WPEParityGlyphAtlas.entryKey(faceIndex: 2, glyphID: 0x41), 0x0200_0041)

        var instance = WPEParityGlyphAtlasInstance(fontPath: "fonts/NotoSans.ttf", pointSize: 30.5)
        XCTAssertEqual(instance.key, "fonts/NotoSans.ttf_1952")
        XCTAssertEqual([instance.mono.width, instance.mono.height], [512, 512])
        XCTAssertEqual(instance.mono.format, .r8)

        let bgra = WPEParityGlyphBitmap(width: 1, rows: 1, pixelMode: .bgra, pixels: [1, 2, 3, 4])
        XCTAssertEqual(instance.insert(key: 1, bitmap: gray(2, 2))?.atlas, .mono)
        XCTAssertNil(instance.color)
        XCTAssertEqual(instance.insert(key: 2, bitmap: bgra)?.atlas, .color)
        XCTAssertEqual(instance.color.map { [$0.width, $0.height] }, [512, 512])
        XCTAssertEqual(instance.color?.format, .rgba8)
        XCTAssertEqual(instance.entry(forKey: 1)?.atlas, .mono)
        XCTAssertEqual(instance.entry(forKey: 2)?.atlas, .color)
        XCTAssertNil(instance.entry(forKey: 3))
    }
}
