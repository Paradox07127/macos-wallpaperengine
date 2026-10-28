import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LiveWallpaper

final class NowPlayingAccentTests: XCTestCase {

    // MARK: Fixture images (encoded PNG bytes, like real artwork payloads)

    private func pngData(filledWith color: CGColor, side: Int = 64) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try XCTUnwrap(ctx.makeImage())

        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    // MARK: Extraction

    func testPureColorImageYieldsThatColor() throws {
        let red = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.12, alpha: 1)
        let data = try pngData(filledWith: red)
        let accent = try XCTUnwrap(NowPlayingAccent.dominantColor(in: data))
        XCTAssertGreaterThan(accent.red, 0.7)
        XCTAssertLessThan(accent.green, 0.35)
        XCTAssertLessThan(accent.blue, 0.35)
        XCTAssertGreaterThan(accent.red, accent.green)
        XCTAssertGreaterThan(accent.red, accent.blue)
    }

    func testGrayscaleImageFallsBackWithoutCrashing() throws {
        let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        XCTAssertNil(NowPlayingAccent.dominantColor(in: try pngData(filledWith: gray)))
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertNil(NowPlayingAccent.dominantColor(in: try pngData(filledWith: black)))
    }

    func testGarbageDataFallsBackWithoutCrashing() {
        XCTAssertNil(NowPlayingAccent.dominantColor(in: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(NowPlayingAccent.dominantColor(in: Data()))
    }

    func testDarkColorGetsLiftedToTheReadabilityFloor() throws {
        let darkBlue = CGColor(srgbRed: 0.02, green: 0.05, blue: 0.3, alpha: 1)
        let accent = try XCTUnwrap(NowPlayingAccent.dominantColor(in: try pngData(filledWith: darkBlue)))
        XCTAssertGreaterThanOrEqual(max(accent.red, accent.green, accent.blue), 0.55 - 0.02)
    }

    // MARK: Cache (hits must not re-run the extractor)

    @MainActor
    func testCacheHitDoesNotReextract() async {
        let store = NowPlayingAccentStore(extract: { _ in
            NowPlayingAccentColor(red: 1, green: 0, blue: 0)
        })
        let data = Data([0x01])
        let first = await store.accent(for: "track-a", data: data)
        XCTAssertEqual(first, NowPlayingAccentColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(store.extractionCount, 1)

        let second = await store.accent(for: "track-a", data: data)
        XCTAssertEqual(second, first)
        XCTAssertEqual(store.extractionCount, 1, "cache hit re-ran the extractor")

        _ = await store.accent(for: "track-b", data: data)
        XCTAssertEqual(store.extractionCount, 2)
    }

    @MainActor
    func testArtworkDecodeRefreshesBytesForAStableTrack() async throws {
        let store = NowPlayingArtworkStore()
        let red = try pngData(filledWith: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), side: 24)
        let blue = try pngData(filledWith: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), side: 48)
        let firstResult = await store.image(for: "stable-track", data: red)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.width, 24)
        let updatedResult = await store.image(for: "stable-track", data: blue)
        let updated = try XCTUnwrap(updatedResult)
        XCTAssertEqual(updated.width, 48, "The same track received a different valid cover payload")
        XCTAssertFalse(first === updated)
        let cached = await store.image(for: "stable-track", data: blue)
        XCTAssertTrue(updated === cached, "Unchanged cover bytes must reuse the decoded image")
    }

    @MainActor
    func testAccentRefreshesBytesForAStableTrack() async throws {
        let store = NowPlayingAccentStore()
        let red = try pngData(filledWith: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let blue = try pngData(filledWith: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let firstResult = await store.accent(for: "stable-track", data: red)
        let first = try XCTUnwrap(firstResult)
        XCTAssertGreaterThan(first.red, first.blue)
        let updatedResult = await store.accent(for: "stable-track", data: blue)
        let updated = try XCTUnwrap(updatedResult)
        XCTAssertGreaterThan(updated.blue, updated.red, "A replacement cover must refresh its extracted accent")
        let cached = await store.accent(for: "stable-track", data: blue)
        XCTAssertEqual(cached, updated)
        XCTAssertEqual(store.extractionCount, 2, "Unchanged bytes must remain cached")
    }

    @MainActor
    func testNilResultIsCachedToo() async {
        let store = NowPlayingAccentStore(extract: { _ in nil })
        _ = await store.accent(for: "gray", data: Data([0x01]))
        _ = await store.accent(for: "gray", data: Data([0x01]))
        XCTAssertEqual(store.extractionCount, 1)
    }
}
