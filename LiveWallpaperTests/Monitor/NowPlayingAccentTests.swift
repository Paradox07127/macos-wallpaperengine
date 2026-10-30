import CoreGraphics
import CryptoKit
import ImageIO
@testable import LiveWallpaper
import os
import UniformTypeIdentifiers
import XCTest

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
        let artwork = MonitorNowPlayingArtwork(Data([0x01]))
        let first = await store.accent(for: "track-a", artwork: artwork)
        XCTAssertEqual(first, NowPlayingAccentColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(store.extractionCount, 1)

        let second = await store.accent(for: "track-a", artwork: artwork)
        XCTAssertEqual(second, first)
        XCTAssertEqual(store.extractionCount, 1, "cache hit re-ran the extractor")

        _ = await store.accent(for: "track-b", artwork: artwork)
        XCTAssertEqual(store.extractionCount, 2)
    }

    @MainActor
    func testArtworkDecodeRefreshesBytesForAStableTrack() async throws {
        let store = NowPlayingArtworkStore()
        let red = try pngData(filledWith: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), side: 24)
        let blue = try pngData(filledWith: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), side: 48)
        let firstResult = await store.image(for: "stable-track", artwork: MonitorNowPlayingArtwork(red))
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.width, 24)
        let updatedResult = await store.image(for: "stable-track", artwork: MonitorNowPlayingArtwork(blue))
        let updated = try XCTUnwrap(updatedResult)
        XCTAssertEqual(updated.width, 48, "The same track received a different valid cover payload")
        XCTAssertFalse(first === updated)
        let cached = await store.image(for: "stable-track", artwork: MonitorNowPlayingArtwork(blue))
        XCTAssertTrue(updated === cached, "Unchanged cover bytes must reuse the decoded image")
    }

    @MainActor
    func testAccentRefreshesBytesForAStableTrack() async throws {
        let store = NowPlayingAccentStore()
        let red = try pngData(filledWith: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let blue = try pngData(filledWith: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let firstResult = await store.accent(for: "stable-track", artwork: MonitorNowPlayingArtwork(red))
        let first = try XCTUnwrap(firstResult)
        XCTAssertGreaterThan(first.red, first.blue)
        let updatedResult = await store.accent(for: "stable-track", artwork: MonitorNowPlayingArtwork(blue))
        let updated = try XCTUnwrap(updatedResult)
        XCTAssertGreaterThan(updated.blue, updated.red, "A replacement cover must refresh its extracted accent")
        let cached = await store.accent(for: "stable-track", artwork: MonitorNowPlayingArtwork(blue))
        XCTAssertEqual(cached, updated)
        XCTAssertEqual(store.extractionCount, 2, "Unchanged bytes must remain cached")
    }

    /// Bytes whose storage reports when the last `Data` referencing it is freed.
    private final class ReleaseProbe: Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)

        func data(copying bytes: Data) -> Data {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
            bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            return Data(bytesNoCopy: buffer, count: bytes.count, deallocator: .custom { [flag] pointer, _ in
                pointer.deallocate()
                flag.withLock { $0 = true }
            })
        }

        /// The detached worker may drop its copy just after its result is delivered.
        func released() async -> Bool {
            for _ in 0 ..< 50 where !flag.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return flag.withLock { $0 }
        }
    }

    @MainActor
    func testAccentCacheKeepsNoArtworkBytes() async throws {
        let store = NowPlayingAccentStore(extract: { _ in NowPlayingAccentColor(red: 1, green: 0, blue: 0) })
        let red = try pngData(filledWith: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let probe = ReleaseProbe()
        _ = await store.accent(for: "track", artwork: MonitorNowPlayingArtwork(probe.data(copying: red)))
        let accentReleased = await probe.released()
        XCTAssertTrue(accentReleased, "The accent cache retained the raw artwork bytes")
        _ = await store.accent(for: "track", artwork: MonitorNowPlayingArtwork(Data(red)))
        XCTAssertEqual(store.extractionCount, 1, "Equal bytes in a new buffer must hit the cache")
        let blue = try pngData(filledWith: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        _ = await store.accent(for: "track", artwork: MonitorNowPlayingArtwork(blue))
        XCTAssertEqual(store.extractionCount, 2, "Different bytes for the same track must miss the cache")
    }

    @MainActor
    func testArtworkCacheKeepsNoArtworkBytes() async throws {
        let store = NowPlayingArtworkStore()
        let red = try pngData(filledWith: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), side: 24)
        let probe = ReleaseProbe()
        let decodedResult = await store.image(for: "track", artwork: MonitorNowPlayingArtwork(probe.data(copying: red)))
        let decoded = try XCTUnwrap(decodedResult)
        let artworkReleased = await probe.released()
        XCTAssertTrue(artworkReleased, "The artwork cache retained the raw artwork bytes")
        XCTAssertTrue(store.cached(for: "track", digest: SHA256.hash(data: Data(red))) === decoded, "Equal bytes in a new buffer must hit the cache")
        let blue = try pngData(filledWith: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), side: 24)
        XCTAssertNil(store.cached(for: "track", digest: SHA256.hash(data: blue)), "Different bytes for the same track must miss the cache")
    }

    @MainActor
    func testCoverIsHashedOnceWhereItArrives() async throws {
        let red = try pngData(filledWith: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), side: 24)
        var state = MonitorNowPlayingState(phase: .playing, title: "Track")
        state.artwork = red
        let artwork = try XCTUnwrap(state.artworkPayload)
        XCTAssertEqual(artwork.digest, SHA256.hash(data: red))
        // The main-actor merge re-assigns the bytes it already holds; that must keep the arrival digest.
        state.artwork = state.artwork
        XCTAssertEqual(state.artworkPayload, artwork)

        let images = NowPlayingArtworkStore()
        XCTAssertNil(images.cached(for: "track", digest: artwork.digest))
        let decodedResult = await images.image(for: "track", artwork: artwork)
        let decoded = try XCTUnwrap(decodedResult)
        XCTAssertTrue(images.cached(for: "track", digest: artwork.digest) === decoded)

        let accents = NowPlayingAccentStore(extract: { _ in NowPlayingAccentColor(red: 1, green: 0, blue: 0) })
        _ = await accents.accent(for: "track", artwork: artwork)
        _ = try await accents.accent(for: "track", artwork: XCTUnwrap(state.artworkPayload))
        XCTAssertEqual(accents.extractionCount, 1, "The same arrival digest must hit the accent cache")
    }

    @MainActor
    func testNilResultIsCachedToo() async {
        let store = NowPlayingAccentStore(extract: { _ in nil })
        _ = await store.accent(for: "gray", artwork: MonitorNowPlayingArtwork(Data([0x01])))
        _ = await store.accent(for: "gray", artwork: MonitorNowPlayingArtwork(Data([0x01])))
        XCTAssertEqual(store.extractionCount, 1)
    }
}
