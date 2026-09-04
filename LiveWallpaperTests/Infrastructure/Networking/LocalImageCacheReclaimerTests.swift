import AppKit
import AVFoundation
import CoreVideo
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// Counts purges on the main actor, matching `LocalImageCacheReclaimer`'s own
/// isolation so no synchronisation is needed to read it back.
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
    /// 8× the delay. A purge that was going to fire has fired well before this.
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

    /// A stand-in for the app's wallpaper surfaces: a real window, really on
    /// screen, at the level the wallpaper renderers use.
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

    /// Puts one probe entry into each of the three local-source caches, through
    /// the very cache objects production inserts into. Touching them is also
    /// what forces their lazy creation, and therefore their registration.
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

        // Workshop previews join the same reclaim now that their bytes survive on
        // disk — dropping them costs a read plus a decode, never a re-download.
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

    /// Pins: the purge is armed by the *last* window closing, not by any close.
    /// Mutating `windowWillClose` to schedule unconditionally turns the first
    /// two expectations red; the control group at the end is what stops this
    /// from passing on an implementation that simply never purges.
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

    // MARK: - (b) The last close does fire, and empties all three caches

    /// Pins: the last window closing empties every registered local-source
    /// cache. Deleting the `LocalImageCacheRegistry.shared.register(...)` line
    /// from any one of the three cache initializers turns this red, and names
    /// which one by position.
    @Test("The last window closing empties all three local-source caches")
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

    /// Pins: a window opening inside the delay cancels the pending purge
    /// outright rather than letting it fire on a now-open UI. Removing the
    /// cancellation from `windowDidOpen` turns the third and fourth
    /// expectations red.
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

    /// Pins both halves of "the wallpaper surfaces are not part of the
    /// decision". The second half is the one with teeth against a future
    /// rewrite: an implementation that asked `NSApp.windows` whether anything
    /// is still visible would never fire here, because a desktop-level window
    /// is on screen the whole time.
    @Test("A wallpaper-level window neither arms nor blocks the purge")
    func wallpaperLevelWindowsDoNotParticipate() async {
        let counter = PurgeCounter()
        let reclaimer = LocalImageCacheReclaimer(delay: Self.testDelay) { counter.record() }
        let wallpaper = makeWallpaperLevelWindow()
        wallpaper.orderFrontRegardless()
        defer { wallpaper.orderOut(nil) }

        let ui = makeWindow()
        reclaimer.windowDidOpen(ui)

        // Half 1: a wallpaper window going away is not a UI window going away.
        reclaimer.windowWillClose(wallpaper)
        #expect(reclaimer.hasPendingPurgeForTesting == false)
        try? await Task.sleep(for: Self.settleWindow)
        #expect(counter.count == 0)

        // Half 2: one still on screen does not hold the purge back either.
        #expect(wallpaper.isVisible)
        reclaimer.windowWillClose(ui)
        await waitUntil { counter.count > 0 }
        #expect(counter.count == 1)
    }

    // MARK: - (e) A superseded pending purge stays superseded


    // MARK: - (f) A poster generated for a cancelled requester is never inserted

    /// Pins: a video poster enters the cache on the requester's side of the
    /// `await`, never from inside the generator task.
    ///
    /// That task is unstructured — it neither inherits the requester's
    /// cancellation nor dies with it — so an insert made from inside it can land
    /// after the reclaim has already emptied the cache, and the reclaim is a
    /// one-shot armed by a window closing: with no window left to close, nothing
    /// takes that entry out again. Moving `cache.setObject` back inside the task
    /// turns the last two expectations red. The live arm is the control group
    /// that stops this from passing on a build that produces no poster at all.
    ///
    /// Lives in this suite, not its own, because `.serialized` is what keeps the
    /// purge tests above from emptying the control group out from under it.
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

        // Control group.
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

    /// Pins: `purgeAll` empties the caches without disabling them. An
    /// implementation that reclaimed by clamping `totalCostLimit` instead of
    /// calling `removeAllObjects()` would leave these reads nil.
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
    /// The reclaimer is only as good as its call sites, so this drives the real
    /// `AppDelegate` window rather than the reclaimer's API.
    @Suite("Settings window drives the cache reclaimer", .serialized)
    @MainActor
    struct SettingsWindowReclaimerWiringTests {

        /// Pins: presenting the settings window registers it, and closing it
        /// arms the purge. Deleting either call site in `AppDelegate` turns
        /// this red.
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
