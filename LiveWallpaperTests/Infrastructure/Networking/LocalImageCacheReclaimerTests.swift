import AppKit
import AVFoundation
import CoreVideo
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@MainActor
private final class PurgeCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@Suite("Local image cache reclaim after the last window closes", .serialized)
@MainActor
struct LocalImageCacheReclaimerTests {

    /// Short enough to keep the suite quick, long enough that a "did not purge"
    /// assertion is not just a race the scheduler happened to win.
    private static let testDelay = Duration.milliseconds(120)
    private static let settleWindow = Duration.milliseconds(960)

    private static let probeKey = "LocalImageCacheReclaimerTests.probe" as NSString

    // MARK: - Helpers

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeWallpaperLevelWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeBitmap() throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
    }

    /// Puts a probe entry into each local-source cache through the very cache objects
    /// production uses; touching them is what forces their lazy creation and registration.
    private func fillLocalImageCaches() throws {
        let bitmap = try makeBitmap()

        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let decoded = try #require(WPEPreviewDecodedImage.decode(png))
        WPEPreviewDecodedCache.shared.setObject(
            decoded, forKey: Self.probeKey, cost: decoded.estimatedCost
        )

        WallpaperThumbnailService.shared.cache.setObject(
            NSImage(size: NSSize(width: 8, height: 8)), forKey: Self.probeKey, cost: 8 * 8 * 4
        )

        let cgImage = try #require(bitmap.cgImage)
        SystemWallpaperThumbnails.cache.setObject(
            SystemWallpaperThumbnails.CGImageBox(cgImage),
            forKey: Self.probeKey,
            cost: cgImage.bytesPerRow * cgImage.height
        )

        WorkshopPreviewImageLoader.shared.assetCache.setObject(
            CachedWorkshopPreviewAsset(asset: .staticImage(cgImage)),
            forKey: Self.probeKey,
            cost: 8 * 8 * 4
        )
    }

    /// Per-cache occupancy of the probe entry, in a fixed order so a failure
    /// names which cache survived.
    private var probesStillCached: [Bool] {
        [
            WPEPreviewDecodedCache.shared.object(forKey: Self.probeKey) != nil,
            WallpaperThumbnailService.shared.cache.object(forKey: Self.probeKey) != nil,
            SystemWallpaperThumbnails.cache.object(forKey: Self.probeKey) != nil,
            WorkshopPreviewImageLoader.shared.assetCache.object(forKey: Self.probeKey) != nil
        ]
    }

    // MARK: - (a) No purge while a window is still open

    @Test("Closing one of two windows leaves the caches alone")
    func closingOneOfTwoWindowsDoesNotPurge() async {
        let counter = PurgeCounter()
        let reclaimer = LocalImageCacheReclaimer(delay: Self.testDelay) { counter.record() }
        let first = makeWindow()
        let second = makeWindow()
        reclaimer.windowDidOpen(first)
        reclaimer.windowDidOpen(second)

        reclaimer.windowWillClose(first)
        #expect(reclaimer.hasPendingPurgeForTesting == false)
        try? await Task.sleep(for: Self.settleWindow)
        #expect(counter.count == 0)
        #expect(reclaimer.hasOpenWindowsForTesting)

        // Control group: the same reclaimer does purge once the last one goes.
        reclaimer.windowWillClose(second)
        await waitUntil { counter.count > 0 }
        #expect(counter.count == 1)
    }

    // MARK: - (b) The last close does fire, and empties all four caches

    @Test("The last window closing empties all four local-source caches")
    func lastWindowCloseEmptiesEveryLocalImageCache() async throws {
        try fillLocalImageCaches()
        let reclaimer = LocalImageCacheReclaimer(delay: Self.testDelay) {
            LocalImageCacheRegistry.shared.purgeAll()
        }

        let window = makeWindow()
        reclaimer.windowDidOpen(window)
        // Control group: opening a window does not itself empty anything.
        #expect(probesStillCached == [true, true, true, true])

        reclaimer.windowWillClose(window)
        await waitUntil { probesStillCached == [false, false, false, false] }
        #expect(probesStillCached == [false, false, false, false])
    }

    // MARK: - (c) Re-opening inside the delay cancels

    @Test("Re-opening a window inside the delay cancels the pending purge")
    func reopeningInsideTheDelayCancelsThePurge() async {
        let counter = PurgeCounter()
        let reclaimer = LocalImageCacheReclaimer(delay: Self.testDelay) { counter.record() }
        let first = makeWindow()
        reclaimer.windowDidOpen(first)

        reclaimer.windowWillClose(first)
        #expect(reclaimer.hasPendingPurgeForTesting)

        let second = makeWindow()
        reclaimer.windowDidOpen(second)
        #expect(reclaimer.hasPendingPurgeForTesting == false)

        try? await Task.sleep(for: Self.settleWindow)
        #expect(counter.count == 0)

        // Control group: the reclaimer is still armed for a genuine last close.
        reclaimer.windowWillClose(second)
        await waitUntil { counter.count > 0 }
        #expect(counter.count == 1)
    }

    // MARK: - (d) Wallpaper windows take no part

    @Test("A wallpaper-level window neither arms nor blocks the purge")
    func wallpaperLevelWindowsDoNotParticipate() async {
        let counter = PurgeCounter()
        let reclaimer = LocalImageCacheReclaimer(delay: Self.testDelay) { counter.record() }
        let wallpaper = makeWallpaperLevelWindow()
        wallpaper.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        wallpaper.orderFrontRegardless()
        defer { wallpaper.orderOut(nil) }

        let ui = makeWindow()
        reclaimer.windowDidOpen(ui)

        reclaimer.windowWillClose(wallpaper)
        #expect(reclaimer.hasPendingPurgeForTesting == false)
        try? await Task.sleep(for: Self.settleWindow)
        #expect(counter.count == 0)

        #expect(wallpaper.isVisible)
        reclaimer.windowWillClose(ui)
        await waitUntil { counter.count > 0 }
        #expect(counter.count == 1)
    }

    // MARK: - (f) A poster generated for a cancelled requester is never inserted

    /// Must stay in this `.serialized` suite: the purge tests above would otherwise
    /// empty the control group out from under it.
    @Test("A poster generated for a cancelled requester is never inserted")
    func aCancelledRequesterLeavesNothingInTheThumbnailCache() async throws {
        let fixture = try await VideoPosterFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let service = WallpaperThumbnailService.shared
        let liveKey = "LocalImageCacheReclaimerTests.live.\(UUID().uuidString)"
        let cancelledKey = "LocalImageCacheReclaimerTests.cancelled.\(UUID().uuidString)"
        defer {
            service.invalidate(cacheKey: liveKey)
            service.invalidate(cacheKey: cancelledKey)
        }

        #expect(await service.videoPosterImage(for: fixture, cacheKey: liveKey) != nil)
        #expect(service.cachedThumbnail(forKey: liveKey) != nil)

        let requester = Task { @MainActor in
            await service.videoPosterImage(for: fixture, cacheKey: cancelledKey)
        }
        // Cancelled before it can start: this test holds the main actor and has
        // not suspended, so the task body has not run yet.
        requester.cancel()
        #expect(await requester.value == nil)
        #expect(service.cachedThumbnail(forKey: cancelledKey) == nil)

        // The generator is not cancelled with its requester, so it finishes
        // regardless — a late arrival is the failure this test exists for.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(service.cachedThumbnail(forKey: cancelledKey) == nil)
    }

    // MARK: - (g) The caches survive being purged

    @Test("A purged cache still stores and returns objects")
    func purgedCachesRemainUsable() throws {
        try fillLocalImageCaches()
        LocalImageCacheRegistry.shared.purgeAll()
        #expect(probesStillCached == [false, false, false, false])

        try fillLocalImageCaches()
        #expect(probesStillCached == [true, true, true, true])
        LocalImageCacheRegistry.shared.purgeAll()
    }
}

/// A two-frame 64×36 mp4, the smallest thing `AVAssetImageGenerator` will hand
/// back a first frame for.
private enum VideoPosterFixture {

    static func make() async throws -> URL {
        let width = 64
        let height = 36
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("poster-fixture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.failed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.failed(writer.error.map { "\($0)" } ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<2 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixelBuffer: CVPixelBuffer?
            var status = kCVReturnError
            if let pool = adaptor.pixelBufferPool {
                status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            }
            if status != kCVReturnSuccess {
                status = CVPixelBufferCreate(
                    kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
                )
            }
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw FixtureError.failed("pixel buffer create returned \(status)")
            }
            fill(buffer, level: UInt8(index == 0 ? 200 : 60))
            let pts = CMTime(value: Int64(index), timescale: 24)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw FixtureError.failed(writer.error.map { "\($0)" } ?? "append \(index)")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw FixtureError.failed(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")
        }
        return outputURL
    }

    private static func fill(_ buffer: CVPixelBuffer, level: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        memset(base, Int32(level), bytes)
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            switch self {
            case let .failed(message): return "video poster fixture failed: \(message)"
            }
        }
    }
}

#if !LITE_BUILD
    @Suite("Settings window drives the cache reclaimer", .serialized)
    @MainActor
    struct SettingsWindowReclaimerWiringTests {

        @Test("Opening registers the settings window and closing arms the purge")
        func settingsWindowOpenAndCloseDriveTheReclaimer() throws {
            let reclaimer = LocalImageCacheReclaimer.shared
            reclaimer.resetForTesting()
            // The real singleton carries a 10s delay; leaving it armed would
            // purge under whichever test runs next.
            defer { reclaimer.resetForTesting() }

            let delegate = AppDelegate()
            delegate.screenManager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false,
                startAutomation: false,
                powerMonitor: FakePowerMonitor(),
                fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(),
                displayRegistry: FakeDisplayRegistry(),
                featureCatalog: .unconfigured
            ))

            delegate.showSettings()
            let window = try #require(delegate.settingsWindowControllerForTesting?.window)
            #expect(reclaimer.hasOpenWindowsForTesting)
            #expect(reclaimer.hasPendingPurgeForTesting == false)

            window.close()
            #expect(reclaimer.hasOpenWindowsForTesting == false)
            #expect(reclaimer.hasPendingPurgeForTesting)
        }
    }
#endif
