#if !LITE_BUILD
import AppKit
import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers

@Suite("WorkshopAnimatedGIF bounded decode")
struct WorkshopAnimatedGIFDecodeTests {
    @Test("Single-frame PNG decodes to a static image")
    func staticPNGDecodesStatic() throws {
        let data = GIFTestFixtures.png(width: 8, height: 8)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .staticImage = asset else {
            Issue.record("Expected .staticImage, got \(asset)")
            return
        }
    }

    @Test("Multi-frame GIF decodes to an animation with the right frame count + delays")
    func animatedGIFDecodesAnimated() throws {
        let data = GIFTestFixtures.gif(width: 8, height: 8, frameCount: 3, delay: 0.1)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .animatedGIF(let gif) = asset else {
            Issue.record("Expected .animatedGIF, got \(asset)")
            return
        }
        #expect(gif.frameCount == 3)
        #expect(gif.frameDelays.count == 3)
        #expect(gif.frame(at: 0) != nil)
        #expect(gif.frame(at: 2) != nil)
        #expect(gif.frame(at: 3) == nil)
        #expect(gif.frameDelays.allSatisfy { $0 >= WorkshopAnimatedGIF.minFrameDelay })
    }

    @Test("Frame delays are floored at the 30 FPS cap")
    func frameDelaysFloored() throws {
        let data = GIFTestFixtures.gif(width: 4, height: 4, frameCount: 2, delay: 0.005)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .animatedGIF(let gif) = asset else {
            Issue.record("Expected .animatedGIF")
            return
        }
        #expect(gif.frameDelays.allSatisfy { $0 >= WorkshopAnimatedGIF.minFrameDelay })
    }

    @Test("Data over the 32 MiB byte cap is rejected")
    func overByteCapRejected() {
        let oversized = Data(count: WorkshopAnimatedGIF.maxBytes + 1)
        #expect(WorkshopAnimatedGIF.make(from: oversized) == nil)
    }

    @Test("Garbage bytes fail to decode")
    func garbageRejected() {
        #expect(WorkshopAnimatedGIF.make(from: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    @Test("Animations over the 120-frame cap degrade to a static poster")
    func overFrameCapDegradesToPoster() throws {
        let data = GIFTestFixtures.gif(width: 2, height: 2, frameCount: WorkshopAnimatedGIF.maxFrameCount + 1, delay: 0.1)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .staticImage = asset else {
            Issue.record("Expected over-cap animation to degrade to .staticImage, got \(asset)")
            return
        }
    }

    @Test("Decoded-pixel budget is overflow-safe and rejects oversized animations")
    func pixelBudget() {
        #expect(WorkshopAnimatedGIF.isWithinPixelBudget(width: 256, height: 256, frameCount: 10))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: 4000, height: 4000, frameCount: 100))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: 6000, height: 6000, frameCount: 1))
        #expect(WorkshopAnimatedGIF.isWithinPixelBudget(width: 4000, height: 4000, frameCount: 1))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: 0, height: 8, frameCount: 1))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: Int.max, height: Int.max, frameCount: Int.max))
    }

    @Test("Grid decode is capped at the tile size, frames included")
    func tileDecodeIsCapped() throws {
        let data = GIFTestFixtures.gif(width: 1600, height: 900, frameCount: 3, delay: 0.1)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data, size: .tile))
        guard case .animatedGIF(let gif) = asset else {
            Issue.record("Expected .animatedGIF, got \(asset)")
            return
        }
        let cap = WorkshopPreviewSize.tile.maxPixelSize
        #expect(max(gif.posterFrame.width, gif.posterFrame.height) <= cap)
        // Playback frames take the same path — a hovered tile must not start
        // decoding 1600×900 thirty times a second.
        let frame = try #require(gif.frame(at: 1))
        #expect(max(frame.width, frame.height) <= cap)
    }

    @Test("The hero tier decodes larger than the tile tier from the same bytes")
    func heroDecodesLargerThanTile() throws {
        let data = GIFTestFixtures.gif(width: 1600, height: 900, frameCount: 2, delay: 0.1)
        let tile = try #require(WorkshopAnimatedGIF.make(from: data, size: .tile))
        let hero = try #require(WorkshopAnimatedGIF.make(from: data, size: .hero))
        #expect(hero.posterFrame.width > tile.posterFrame.width)
        #expect(max(hero.posterFrame.width, hero.posterFrame.height) <= WorkshopPreviewSize.hero.maxPixelSize)
    }

    @Test("Installed-side previews decode at the shared pixel cap, frames included")
    func installedDecodeIsCapped() throws {
        // Over the cap but inside the decoded-pixel budget, so this exercises
        // the animated branch rather than the degrade-to-poster one.
        let data = GIFTestFixtures.gif(width: 2400, height: 1200, frameCount: 3, delay: 0.1)
        let cap = WPEPreviewSize.tile.maxPixelSize
        let decoded = try #require(WPEPreviewDecodedImage.decode(data, maxPixelSize: cap))
        #expect(max(decoded.posterFrame.width, decoded.posterFrame.height) <= cap)
        #expect(decoded.frameCount == 3)
        let frame = try #require(decoded.frame(at: 1))
        #expect(max(frame.width, frame.height) <= cap)
    }

    @Test("The installed preview path decodes off the main thread, not in updateNSView")
    func installedPreviewDecodesOffMain() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/ScenePreview.swift")
        #expect(source.contains("NSCache<NSString, WPEPreviewDecodedImage>"))
        #expect(!source.contains("func setImage(data:"))
        #expect(source.contains("kCGImageSourceShouldCacheImmediately: true"))
    }

    @Test("A preview regenerated at the same path is not served from the cache")
    func previewCacheKeyCarriesModificationDate() throws {
        // A Workshop update rewrites `preview.jpg` in place, so a URL-only key would serve
        // the pre-update pixels for the rest of the session.
        let source = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/ScenePreview.swift")
        #expect(source.contains("contentModificationDateKey"))
        #expect(!source.contains(#""\(previewSize.maxPixelSize)|\(url.absoluteString)""#))
        // A URL whose date cannot be read yields no key, and an entry nothing
        // can invalidate must not be written at all.
        #expect(source.contains("size: WPEPreviewSize) -> NSString?"))
        #expect(source.contains("if let cacheKey {"))
    }

    @Test("The pane tier decodes larger than the tile tier")
    func paneDecodesLargerThanTile() throws {
        let data = GIFTestFixtures.gif(width: 2400, height: 1200, frameCount: 2, delay: 0.1)
        let tile = try #require(WPEPreviewDecodedImage.decode(data, maxPixelSize: WPEPreviewSize.tile.maxPixelSize))
        let pane = try #require(WPEPreviewDecodedImage.decode(data, maxPixelSize: WPEPreviewSize.pane.maxPixelSize))
        #expect(pane.posterFrame.width > tile.posterFrame.width)
        #expect(WPEPreviewSize.pane.maxPixelSize > WPEPreviewSize.tile.maxPixelSize)
    }

    @Test("The animation budget is priced against decoded frames, not the source")
    func animationBudgetFollowsDecodedSize() throws {
        // 1920x1080 x 20 frames is ~166 MB of source-sized RGBA, over the 96 MB budget,
        // while the capped 800 px playback frames are ~23 MB for all twenty.
        let data = GIFTestFixtures.gif(width: 1920, height: 1080, frameCount: 20, delay: 0.1)
        #expect(!WPEPreviewImageDecodeBudget.isWithinPixelBudget(width: 1920, height: 1080, frameCount: 20))

        let decoded = try #require(WPEPreviewDecodedImage.decode(data, maxPixelSize: WPEPreviewSize.tile.maxPixelSize))
        #expect(decoded.frameCount == 20)
        #expect(try #require(decoded.frame(at: 5)).width <= WPEPreviewSize.tile.maxPixelSize)
    }

    @Test("A shared preview load is unregistered by identity, not by key")
    func inflightLoadsAreRetiredByIdentity() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Workshop/WorkshopPreviewImageLoader.swift"
        )
        // A cancelled load finishes after its replacement has been registered,
        // so removing by key alone would unregister the live one.
        #expect(source.contains("guard assetInflight[cacheKey] === load else { return }"))
        #expect(!source.contains("defer { self?.assetInflight.removeValue(forKey: cacheKey) }"))
        #expect(source.contains("private func dropWaiter(_ load: InflightLoad, forKey cacheKey: String)"))
    }

    @Test("Workshop preview cache has one count-and-cost bounded owner")
    func previewCacheIsUnifiedAndBounded() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Workshop/WorkshopPreviewImageLoader.swift"
        )

        #expect(source.contains("NSCache<NSString, CachedWorkshopPreviewAsset>"))
        // The key carries the decode size, or the grid's small poster would be
        // served to the detail hero (and vice versa).
        #expect(source.contains(#"let cacheKey = "\(size.rawValue)|\(url.absoluteString)""#))
        #expect(source.contains("load.task.cancel()"))
        #expect(source.contains("PreviewWorkGate.shared.run"))
        #expect(source.contains("assetCache.countLimit = Self.cacheCountLimit"))
        #expect(source.contains("assetCache.totalCostLimit = Self.cacheCostLimit"))
        #expect(source.contains("cost: cached.estimatedCacheCost"))
        #expect(!source.contains("private var cache: [URL: NSImage]"))
        #expect(!source.contains("private var assetCache: [URL: WorkshopPreviewAsset]"))
    }
}

@Suite("GIFPlaybackCoordinator LRU", .serialized)
@MainActor
struct GIFPlaybackCoordinatorTests {
    @Test("Up to 8 concurrent clients play without eviction")
    func underCapNoEviction() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen = Set<UUID>()
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.insert(id) }
        }
        #expect(frozen.isEmpty)
    }

    @Test("A 9th client evicts the least-recently-used one")
    func overCapEvictsLRU() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0..<9).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        #expect(frozen == [ids[0]])
    }

    @Test("touch protects a client from eviction")
    func touchProtects() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        coordinator.touch(id: ids[0])
        let newcomer = UUID()
        coordinator.requestPlayback(id: newcomer) { frozen.append(newcomer) }
        #expect(frozen == [ids[1]])
    }

    @Test("endPlayback frees a slot so no eviction occurs")
    func endPlaybackFreesSlot() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        coordinator.endPlayback(id: ids[3])
        let newcomer = UUID()
        coordinator.requestPlayback(id: newcomer) { frozen.append(newcomer) }
        #expect(frozen.isEmpty)
    }
}

@Suite("ThumbnailPlaybackGate")
struct ThumbnailPlaybackGateTests {
    @Test("Grid gate requires visibility, hover, motion, and unblurred content")
    func gridGateRequiresAllInputs() {
        var gate = ThumbnailPlaybackGate(
            isVisible: true,
            isHovered: true,
            reduceMotion: false,
            isBlurred: false,
            trigger: .hover
        )
        #expect(gate.allowsPlayback)

        gate.isVisible = false
        #expect(!gate.allowsPlayback)

        gate.isVisible = true
        gate.isHovered = false
        #expect(!gate.allowsPlayback)

        gate.isHovered = true
        gate.reduceMotion = true
        #expect(!gate.allowsPlayback)

        gate.reduceMotion = false
        gate.isBlurred = true
        #expect(!gate.allowsPlayback)
    }

    @Test("Detail gate auto-plays when visible, without hover")
    func detailGateAutoPlays() {
        var gate = ThumbnailPlaybackGate(
            isVisible: true,
            isHovered: false,
            reduceMotion: false,
            isBlurred: false,
            trigger: .auto
        )
        #expect(gate.allowsPlayback)

        gate.isVisible = false
        #expect(!gate.allowsPlayback)

        gate.isVisible = true
        gate.isBlurred = true
        #expect(!gate.allowsPlayback)
    }

    /// The inspector stays mounted when collapsed, so `onDisappear` never fires
    /// and `isVisible` stays true.
    @Test("A mounted-but-hidden host stops playback even though the view never disappeared")
    func hiddenHostStopsAutoPlay() {
        var gate = ThumbnailPlaybackGate(
            isVisible: true,
            hostIsPresented: true,
            isHovered: false,
            reduceMotion: false,
            isBlurred: false,
            trigger: .auto
        )
        #expect(gate.allowsPlayback)

        gate.hostIsPresented = false
        #expect(!gate.allowsPlayback)

        // Hover cannot override it either: the tile is not on screen at all.
        gate.trigger = .hover
        gate.isHovered = true
        #expect(!gate.allowsPlayback)
    }
}

@Suite("GIFAnimationController playback gating", .serialized)
@MainActor
struct GIFAnimationControllerTests {
    @Test("Installing an asset shows the poster and does not auto-animate")
    func posterByDefault() {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.animatedAsset(frameCount: 3))
        #expect(controller.displayedFrame != nil)
        #expect(controller.isAnimating == false)
    }

    @Test("A static asset never animates even when asked to play")
    func staticNeverAnimates() async {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.staticAsset())
        controller.play(debounced: false)
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(controller.isAnimating == false)
    }

    @Test("An animated asset begins playing on an undebounced play")
    func animatedPlays() async {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.animatedAsset(frameCount: 3))
        controller.play(debounced: false)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating == true)
        controller.stop()
        #expect(controller.isAnimating == false)
    }

    @Test("Stopping within the 250 ms debounce window starts no playback")
    func debounceCancellation() async {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.animatedAsset(frameCount: 3))
        controller.play(debounced: true)
        controller.stop()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(controller.isAnimating == false)
    }
}

@MainActor
@Suite("Installed preview playback lifecycle", .serialized)
struct InstalledPreviewPlaybackLifecycleTests {
    @Observable
    final class Presentation {
        var hovered = true
        var presented = true
        var included = true
    }

    @Test("Parent hover and presentation stop real layer playback and permit resuming")
    func installedPreviewStopsOutsidePresentation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("installed-lifecycle-\(UUID().uuidString).gif")
        try GIFTestFixtures.gif(width: 16, height: 16, frameCount: 3, delay: 0.08).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = Presentation()
        let host = NSHostingView(rootView: Preview(state: state, url: url))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await GIFTestFixtures.waitUntil { imageView(in: host)?.layer?.contents != nil }
        let view = try #require(imageView(in: host))
        #expect(try await changes(in: view) > 0, "Visible hovered control must animate")

        state.presented = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await changes(in: view) == 0, "A retained hidden host must stop producing frames")
        state.presented = true
        #expect(try await changes(in: view) > 0, "Reopening the host must resume playback")

        state.hovered = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await changes(in: view) == 0, "The parent's settled hover owns playback")
        state.hovered = true
        #expect(try await changes(in: view) > 0)

        state.included = false
        await GIFTestFixtures.waitUntil { view.layer?.contents == nil }
        #expect(view.layer?.contents == nil, "Removing the preview must clear its retained layer")
    }

    @Observable
    final class EntryPresentation {
        var entry: WPEHistoryEntry
        init(entry: WPEHistoryEntry) {
            self.entry = entry
        }
    }

    private struct HistoryPreview: View {
        let state: EntryPresentation
        var body: some View {
            HistoryRow(entry: state.entry, isActive: false, onRemove: {})
                .frame(width: 200, height: 200)
        }
    }

    @Test("Installed cards load local artwork and replace it when their entry changes")
    func installedCardReloadsChangedEntry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("installed-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try GIFTestFixtures.png(width: 16, height: 16).write(to: folder.appendingPathComponent("first.png"))
        try GIFTestFixtures.png(width: 32, height: 32).write(to: folder.appendingPathComponent("second.png"))
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        func entry(_ preview: String) -> WPEHistoryEntry {
            WPEHistoryEntry(origin: WPEOrigin(
                workshopID: "1", title: "Fixture", originalType: .scene,
                sourceFolderBookmark: bookmark, cacheRelativePath: nil, previewFileName: preview
            ), importedAt: Date(timeIntervalSince1970: 0))
        }
        let state = EntryPresentation(entry: entry("first.png"))
        let host = NSHostingView(rootView: HistoryPreview(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func width() -> Int? {
            guard let contents = imageView(in: host)?.layer?.contents else { return nil }
            // The specific image view stores CGImage frames in its layer.
            // swiftlint:disable:next force_cast
            return (contents as! CGImage).width
        }
        await GIFTestFixtures.waitUntil { width() == 16 }
        #expect(width() == 16)
        // Same workshop ID and import stamp; changing the resource itself must reload.
        state.entry = entry("second.png")
        await GIFTestFixtures.waitUntil { width() == 32 }
        #expect(width() == 32)
    }

    private struct Preview: View {
        let state: Presentation
        let url: URL

        var body: some View {
            Group {
                if state.included {
                    WPEPreviewView(imageURL: url, playbackMode: .hoverToPlay, previewSize: .tile, hovered: state.hovered)
                }
            }
            .environment(\.inspectorContentIsVisible, state.presented)
            .frame(width: 200, height: 200)
        }
    }

    private func imageView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == "AspectFillAnimatedImageView" {
            return view
        }
        return view.subviews.lazy.compactMap { imageView(in: $0) }.first
    }

    private func changes(in view: NSView) async throws -> Int {
        var prior = view.layer?.contents.map { $0 as AnyObject }
        var count = 0
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(20))
            let current = view.layer?.contents.map { $0 as AnyObject }
            if current !== prior {
                count += 1
            }
            prior = current
        }
        return count
    }
}

@MainActor
@Suite("Preview frame timing", .serialized)
struct PreviewFrameTimingTests {
    private actor DecodeProbe {
        var started = false
        var continuation: CheckedContinuation<Int?, Never>?

        func decode() async -> Int? {
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            continuation?.resume(returning: 7)
            continuation = nil
        }
    }

    @Test("An already cancelled playback does not start decoding")
    func cancelledBeforeDecode() async {
        let probe = DecodeProbe()
        let task = Task {
            await PreviewFrameLoader.frame(after: 0.1) { await probe.decode() }
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(await probe.started == false)
    }

    @Test("Cancellation while decoding discards the prepared frame")
    func cancelledDuringDecode() async throws {
        let probe = DecodeProbe()
        let task = Task {
            await PreviewFrameLoader.frame(after: 10) { await probe.decode() }
        }
        while await !probe.started {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await probe.finish()
        #expect(await task.value == nil)
    }

    @Test("A frame prepared early still waits for its display interval")
    func preparedFrameWaits() async {
        let start = ContinuousClock.now
        let result = await PreviewFrameLoader.frame(after: 0.06) { 7 }
        #expect(result == 7)
        #expect(start.duration(to: .now) >= .milliseconds(55))
    }
}

// MARK: - Fixtures

enum GIFTestFixtures {
    static func cgImage(width: Int, height: Int, seed: Int = 0) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let r = Double((seed &* 53) % 256) / 255.0
        let g = Double((seed &* 97 &+ 40) % 256) / 255.0
        let b = Double((seed &* 29 &+ 80) % 256) / 255.0
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func png(width: Int, height: Int) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage(width: width, height: height), nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func gif(width: Int, height: Int, frameCount: Int, delay: Double) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil)!
        let frameProps = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]
        ] as CFDictionary
        for index in 0..<frameCount {
            CGImageDestinationAddImage(dest, cgImage(width: width, height: height, seed: index + 1), frameProps)
        }
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func staticAsset() -> WorkshopPreviewAsset {
        WorkshopAnimatedGIF.make(from: png(width: 8, height: 8))!
    }

    static func animatedAsset(frameCount: Int) -> WorkshopPreviewAsset {
        WorkshopAnimatedGIF.make(from: gif(width: 8, height: 8, frameCount: frameCount, delay: 0.1))!
    }

    @MainActor
    static func waitUntil(timeout: Double = 5.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
