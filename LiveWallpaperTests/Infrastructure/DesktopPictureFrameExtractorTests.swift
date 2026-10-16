import AppKit
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Desktop picture frame extractor")
struct DesktopPictureFrameExtractorTests {
    @Test("A request that decodes after a newer one for the same screen does not install", .timeLimit(.minutes(1)))
    func staleRequestIsRejected() async throws {
        let screen = try #require(NSScreen.screens.first)
        let screenID = CGDirectDisplayID.random(in: 0xF000_0000 ... 0xFFFF_FFFE)
        defer { Self.removeFiles(for: screenID) }
        let probe = Probe()

        let older = Task { @MainActor in
            await DesktopPictureFrameExtractor.applyFrame(
                { await withCheckedContinuation { probe.olderFrame = $0 } },
                screenID: screenID, nsScreen: screen, install: { url, _ in try probe.record(url) }
            )
        }
        while probe.olderFrame == nil {
            await Task.yield()
        }
        let newer = await DesktopPictureFrameExtractor.applyFrame(
            { try Self.image(width: 2) },
            screenID: screenID, nsScreen: screen, install: { url, _ in try probe.record(url) }
        )
        try probe.olderFrame?.resume(returning: Self.image(width: 1))
        let olderOutcome = await older.value

        #expect(newer == .captured)
        #expect(olderOutcome == .superseded)
        #expect(probe.installedWidths == [2], "the older frame overwrote the newer one")
    }

    @Test("A single request installs a persistent desktop picture and leaves no staging file")
    func singleRequestInstalls() async throws {
        let screen = try #require(NSScreen.screens.first)
        let screenID = CGDirectDisplayID.random(in: 0xF000_0000 ... 0xFFFF_FFFE)
        defer { Self.removeFiles(for: screenID) }
        let probe = Probe()

        let outcome = await DesktopPictureFrameExtractor.applyFrame(
            { try Self.image(width: 3) },
            screenID: screenID, nsScreen: screen, install: { url, _ in try probe.record(url) }
        )

        #expect(outcome == .captured)
        #expect(probe.installedWidths == [3])
        #expect(probe.installedURLs.first?.lastPathComponent.hasPrefix("LiveWallpaper_LockScreen_\(screenID)_") == true)
        #expect(probe.installedURLs.first?.deletingLastPathComponent() == DesktopPictureFrameExtractor.picturesDirectory)
        #expect(Self.files(for: screenID) == probe.installedURLs.map(\.lastPathComponent))
    }

    @Test("Snapshots use fresh URLs, retain two files, and preserve the installed PNG after rejection")
    func freshURLsAndRejectedInstall() async throws {
        let screen = try #require(NSScreen.screens.first)
        let screenID = CGDirectDisplayID.random(in: 0xF000_0000 ... 0xFFFF_FFFE)
        defer { Self.removeFiles(for: screenID) }
        let probe = Probe()
        for width in 1 ... 4 {
            let outcome = await DesktopPictureFrameExtractor.applyFrame(
                { try Self.image(width: width) }, screenID: screenID, nsScreen: screen,
                install: { url, _ in try probe.record(url) }
            )
            #expect(outcome == .captured)
        }
        #expect(Set(probe.installedURLs).count == 4)
        #expect(Self.files(for: screenID).count == 2)
        let installed = try #require(probe.installedURLs.last)
        let original = try Data(contentsOf: installed)
        let files = Self.files(for: screenID)
        let outcome = await DesktopPictureFrameExtractor.applyFrame(
            { try Self.image(width: 5) }, screenID: screenID, nsScreen: screen,
            install: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        #expect(outcome == .installFailed)
        #expect(try Data(contentsOf: installed) == original)
        #expect(Self.files(for: screenID) == files)
    }

    @MainActor
    private final class Probe {
        var olderFrame: CheckedContinuation<CGImage, Never>?
        var installedURLs: [URL] = []
        var installedWidths: [Int] = []

        func record(_ url: URL) throws {
            installedURLs.append(url)
            try installedWidths.append(#require(NSBitmapImageRep(data: Data(contentsOf: url))).pixelsWide)
        }
    }

    private static func image(width: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private static func files(for screenID: CGDirectDisplayID) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: DesktopPictureFrameExtractor.picturesDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("LiveWallpaper_LockScreen_\(screenID)") }.sorted()
    }

    private static func removeFiles(for screenID: CGDirectDisplayID) {
        for name in files(for: screenID) {
            try? FileManager.default.removeItem(at: DesktopPictureFrameExtractor.picturesDirectory.appendingPathComponent(name))
        }
    }
}
