import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Home cover capture retry")
struct HomeCoverCaptureRetryTests {
    private static func pixel() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private static let delays: [Duration] = Array(repeating: .milliseconds(400), count: 4)

    @Test("A session with no frame yet is captured again until it has one")
    func retriesUntilAFrameLands() async throws {
        let frame = try Self.pixel()
        var calls = 0
        let image = await HomePage.captureCover(
            retryDelays: Self.delays,
            isNewest: { true },
            sleep: { _ in },
            capture: {
                calls += 1
                return calls < 3 ? nil : frame
            }
        )
        #expect(image === frame, "a capture that is nil during a transition hold leaves the card on the previous wallpaper")
        #expect(calls == 3)
    }

    @Test("A newer capture asked for stops the retries")
    func aNewerRequestStopsRetrying() async {
        var calls = 0
        var newest = true
        let image = await HomePage.captureCover(
            retryDelays: Self.delays,
            isNewest: { newest },
            sleep: { _ in },
            capture: {
                calls += 1
                newest = false
                return nil
            }
        )
        #expect(image == nil)
        #expect(calls == 1, "a superseded request keeps capturing frames nobody shows")
    }

    @Test("Retries end once the delays run out")
    func retriesEndWithTheDelays() async {
        var calls = 0
        let image = await HomePage.captureCover(
            retryDelays: Self.delays,
            isNewest: { true },
            sleep: { _ in },
            capture: {
                calls += 1
                return nil
            }
        )
        #expect(image == nil)
        #expect(calls == 1 + Self.delays.count)
    }

    private static func display(cover: CGImage?) -> StageDisplay {
        StageDisplay(
            id: 1, fingerprint: "", frame: .zero, isBuiltin: false, name: "",
            badgeText: "", statusText: "", cover: cover, state: .empty
        )
    }

    @Test("A display whose wallpaper was removed drops the cover of the wallpaper it no longer runs")
    func aRemovedWallpaperDropsItsCover() throws {
        var display = try Self.display(cover: Self.pixel())
        let cleared = HomePage.reconcileCover(&display, hasConfiguration: false)
        #expect(cleared, "the in-flight capture of the removed wallpaper is not told to stand down")
        #expect(display.cover == nil, "the detail top bar keeps showing the removed wallpaper")
    }

    @Test("A display whose wallpaper was removed before its first cover landed stops that capture")
    func aRemovedWallpaperWithoutCoverStopsItsCapture() {
        var display = Self.display(cover: nil)
        let superseded = HomePage.reconcileCover(&display, hasConfiguration: false)
        #expect(superseded, "the first capture of the removed wallpaper lands after the removal")
        #expect(display.cover == nil)
    }

    @Test("A display still running a wallpaper keeps its cover while a new one is captured")
    func aRunningWallpaperKeepsItsCover() throws {
        let frame = try Self.pixel()
        var display = Self.display(cover: frame)
        let cleared = HomePage.reconcileCover(&display, hasConfiguration: true)
        #expect(!cleared)
        #expect(display.cover === frame, "the card flashes blank between two wallpapers")
    }

    private static func webConfiguration() throws -> ScreenConfiguration {
        let url = try #require(URL(string: "https://example.com"))
        return ScreenConfiguration(screenID: 1, wallpaper: .html(source: .url(url), config: .default))
    }

    @Test("Changing only how a display sounds leaves its cover signature alone")
    func soundOnlyChangesKeepTheSignature() throws {
        let base = try Self.webConfiguration()
        var louder = base
        louder.videoVolume = 0.3
        louder.muted.toggle()
        var html = try #require(louder.htmlConfig)
        html.muteAudio.toggle()
        html.audioVolume = 0.2
        louder.activeWallpaper = try .html(source: #require(louder.htmlSource), config: html)
        louder.savedHTMLConfig = html
        #expect(
            HomePage.coverSignature(of: louder) == HomePage.coverSignature(of: base),
            "a volume or mute change recaptures the cover and pushes back the library cover save"
        )
    }

    @Test("Changing what a display draws changes its cover signature")
    func visualChangesMoveTheSignature() throws {
        let base = try Self.webConfiguration()
        var refit = base
        refit.fitMode = refit.fitMode == .aspectFill ? .aspectFit : .aspectFill
        #expect(HomePage.coverSignature(of: refit) != HomePage.coverSignature(of: base), "a fit change keeps the stale cover")
        var switched = base
        switched.activeWallpaper = .video(bookmarkData: Data([1]), packageEntryName: nil)
        #expect(HomePage.coverSignature(of: switched) != HomePage.coverSignature(of: base), "a new wallpaper keeps the old cover")
        var moved = base
        var html = try #require(moved.htmlConfig)
        html.transformScale = 2
        moved.activeWallpaper = try .html(source: #require(moved.htmlSource), config: html)
        #expect(HomePage.coverSignature(of: moved) != HomePage.coverSignature(of: base), "a page transform keeps the stale cover")
        #expect(HomePage.coverSignature(of: nil) == nil)
    }
}
