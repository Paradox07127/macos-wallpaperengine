#if !LITE_BUILD
import AppKit
import CoreGraphics
import Darwin
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
    @MainActor
    @Test("Local author previews reject FIFOs and oversized files before decode", .timeLimit(.minutes(1)))
    func localPreviewInputBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UI-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        func origin(_ name: String) -> WPEOrigin {
            WPEOrigin(workshopID: "123", title: "Preview", originalType: .scene,
                      sourceFolderBookmark: bookmark, cacheRelativePath: nil, previewFileName: name)
        }
        let fifo = root.appendingPathComponent("blocked.gif")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try #require(fifo.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == false)
        #expect(origin("blocked.gif").sourcePreviewURL == fifo)
        try #require(!WPEPreviewImageDecodeBudget.acceptsFile(at: fifo))
        #expect(WPEPreviewImageDecodeBudget.readData(from: fifo) == nil)
        #expect(await ShelfPreviewFrames.load(origin("blocked.gif"), maxPixelSize: 32) == nil)
        #expect(await ShelfThumbnailCache.Sources().scene(origin("blocked.gif"), CGSize(width: 32, height: 32)) == nil)

        let large = root.appendingPathComponent("large.gif")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(WPEPreviewImageDecodeBudget.maxEncodedBytes + 1))
        try handle.close()
        #expect(!WPEPreviewImageDecodeBudget.acceptsFile(at: large))
        #expect(WPEPreviewImageDecodeBudget.readData(from: large) == nil)
        #expect(await ShelfPreviewFrames.load(origin("large.gif"), maxPixelSize: 32) == nil)
        #expect(await ShelfThumbnailCache.Sources().scene(origin("large.gif"), CGSize(width: 32, height: 32)) == nil)

        let normal = root.appendingPathComponent("normal.gif")
        let bytes = GIFTestFixtures.gif(width: 8, height: 8, frameCount: 2, delay: 0.1)
        try bytes.write(to: normal)
        #expect(WPEPreviewImageDecodeBudget.acceptsFile(at: normal))
        #expect(WPEPreviewImageDecodeBudget.readData(from: normal) == bytes)
        let frames = try #require(await ShelfPreviewFrames.load(origin("normal.gif"), maxPixelSize: 32))
        #expect(frames.images.count == 2)
        #expect(await ShelfThumbnailCache.Sources().scene(origin("normal.gif"), CGSize(width: 32, height: 32)) != nil)
        #expect(WPEPreviewImageDecodeBudget.readData(from: root) == nil)
        #expect(WPEPreviewImageDecodeBudget.readData(from: root.appendingPathComponent("missing.gif")) == nil)
    }

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
        guard case let .animatedGIF(gif) = asset else {
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
        guard case let .animatedGIF(gif) = asset else {
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
        guard case let .animatedGIF(gif) = asset else {
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
        let ids = (0 ..< 8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.insert(id) }
        }
        #expect(frozen.isEmpty)
    }

    @Test("A 9th client evicts the least-recently-used one")
    func overCapEvictsLRU() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0 ..< 9).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        #expect(frozen == [ids[0]])
    }

    @Test("touch protects a client from eviction")
    func touchProtects() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0 ..< 8).map { _ in UUID() }
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
        let ids = (0 ..< 8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        coordinator.endPlayback(id: ids[3])
        let newcomer = UUID()
        coordinator.requestPlayback(id: newcomer) { frozen.append(newcomer) }
        #expect(frozen.isEmpty)
    }
}

@Suite("Mounted GIF host visibility", .serialized)
@MainActor
struct MountedGIFHostVisibilityTests {
    private final class VisibilityWindow: NSWindow {
        var presentsContent = true
        var minimized = false
        var contentOccluded = false
        override var isVisible: Bool {
            presentsContent
        }

        override var isMiniaturized: Bool {
            minimized
        }

        override var occlusionState: NSWindow.OcclusionState {
            contentOccluded ? [] : [.visible]
        }
    }

    @Test("A mounted auto-play hero restores on activation only while its host presents content")
    func mountedHeroLifecycle() async {
        let controller = GIFAnimationController()
        let asset = GIFTestFixtures.animatedAsset(frameCount: 3)
        let thumbnail = AnimatedGIFThumbnail(
            url: URL(fileURLWithPath: "/fixture.gif"), playbackMode: .autoPlay,
            controller: controller, loadAsset: { _, _ in asset }
        ).environment(\._accessibilityReduceMotion, false)
        let host = NSHostingView(rootView: thumbnail)
        let window = VisibilityWindow(contentRect: CGRect(x: -30000, y: -30000, width: 120, height: 100),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Allow the representable to mount, without ordering a real window onto the desktop.
        try? await Task.sleep(for: .milliseconds(100))
        post(NSApplication.didBecomeActiveNotification)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)

        post(NSApplication.didResignActiveNotification)
        await GIFTestFixtures.waitUntil { !controller.isAnimating }
        #expect(!controller.isAnimating)
        post(NSApplication.didBecomeActiveNotification)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)

        window.minimized = true
        post(NSWindow.didMiniaturizeNotification, object: window)
        await GIFTestFixtures.waitUntil { !controller.isAnimating }
        #expect(!controller.isAnimating)
        post(NSApplication.didResignActiveNotification)
        post(NSApplication.didBecomeActiveNotification)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!controller.isAnimating)
        window.minimized = false
        post(NSWindow.didDeminiaturizeNotification, object: window)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)

        window.contentOccluded = true
        post(NSWindow.didChangeOcclusionStateNotification, object: window)
        await GIFTestFixtures.waitUntil { !controller.isAnimating }
        #expect(!controller.isAnimating)
        window.contentOccluded = false
        window.presentsContent = false
        post(NSWindow.didChangeOcclusionStateNotification, object: window)
        post(NSApplication.didResignActiveNotification)
        post(NSApplication.didBecomeActiveNotification)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!controller.isAnimating)
        window.presentsContent = true
        post(NSWindow.didChangeOcclusionStateNotification, object: window)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)

        post(NSApplication.didHideNotification)
        await GIFTestFixtures.waitUntil { !controller.isAnimating }
        #expect(!controller.isAnimating)
        post(NSApplication.didUnhideNotification)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)
        post(NSWindow.willCloseNotification, object: window)
        post(NSApplication.didResignActiveNotification)
        post(NSApplication.didBecomeActiveNotification)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!controller.isAnimating)
        window.contentView = nil
        await GIFTestFixtures.waitUntil { !controller.isAnimating }
        #expect(!controller.isAnimating)
        controller.stop()
        window.close()
    }

    @Test("Only decoded animations mount host observers; delayed GIFs honor the initial inactive host")
    func onlyAnimatedAssetsMountHostProbe() async throws {
        func probes(_ view: NSView) -> Int {
            (view is GIFHostVisibilityView ? 1 : 0) + view.subviews.reduce(0) { $0 + probes($1) }
        }
        func mount(_ view: AnimatedGIFThumbnail) -> (NSHostingView<AnyView>, VisibilityWindow) {
            let host = NSHostingView(rootView: AnyView(view.environment(\._accessibilityReduceMotion, false)))
            let window = VisibilityWindow(contentRect: CGRect(x: -30000, y: -30000, width: 120, height: 100),
                                          styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return (host, window)
        }
        let (emptyHost, emptyWindow) = mount(AnimatedGIFThumbnail(url: nil))
        defer { emptyWindow.contentView = nil; emptyWindow.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probes(emptyHost) == 0)

        let staticAsset = try #require(WorkshopAnimatedGIF.make(from: GIFTestFixtures.png(width: 8, height: 8)))
        let (staticHost, staticWindow) = mount(AnimatedGIFThumbnail(
            url: URL(fileURLWithPath: "/fixture.png"), loadAsset: { _, _ in staticAsset }
        ))
        defer { staticWindow.contentView = nil; staticWindow.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probes(staticHost) == 0)

        var release: CheckedContinuation<WorkshopPreviewAsset?, Never>?
        let controller = GIFAnimationController()
        let (delayedHost, delayedWindow) = mount(AnimatedGIFThumbnail(
            url: URL(fileURLWithPath: "/delayed.gif"), playbackMode: .autoPlay, controller: controller,
            loadAsset: { _, _ in await withCheckedContinuation { release = $0 } }
        ))
        defer { delayedWindow.contentView = nil; controller.stop(); delayedWindow.close() }
        await GIFTestFixtures.waitUntil { release != nil }
        let continuation = try #require(release)
        #expect(probes(delayedHost) == 0)
        // An occluded real host must not play even when NSApp itself is active.
        delayedWindow.contentOccluded = true
        post(NSApplication.didBecomeActiveNotification)
        continuation.resume(returning: GIFTestFixtures.animatedAsset(frameCount: 3))
        await GIFTestFixtures.waitUntil { probes(delayedHost) == 1 }
        #expect(probes(delayedHost) == 1)
        post(NSApplication.didBecomeActiveNotification)
        #expect(!controller.isAnimating)
        delayedWindow.contentOccluded = false
        post(NSWindow.didChangeOcclusionStateNotification, object: delayedWindow)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)
    }

    private func post(_ name: Notification.Name, object: Any? = nil) {
        NotificationCenter.default.post(name: name, object: object)
    }

    @Test("Mounted hidden previews defer loading, reject cancelled results, and reload when their size changes")
    func mountedHiddenPreviewLoadLifecycle() async throws {
        let controller = GIFAnimationController()
        let asset = GIFTestFixtures.staticAsset()
        var requestedSizes: [WorkshopPreviewSize] = []
        var releases: [CheckedContinuation<WorkshopPreviewAsset?, Never>] = []
        func thumbnail(presented: Bool, size: WorkshopPreviewSize = .tile) -> AnyView {
            AnyView(AnimatedGIFThumbnail(
                url: URL(fileURLWithPath: "/visibility.png"), previewSize: size,
                controller: controller, loadAsset: { _, size in
                    requestedSizes.append(size)
                    return await withCheckedContinuation { releases.append($0) }
                }
            ).environment(\.inspectorContentIsVisible, presented)
                .environment(\._accessibilityReduceMotion, false))
        }
        let host = NSHostingView(rootView: thumbnail(presented: false))
        let window = VisibilityWindow(contentRect: CGRect(x: -30000, y: -30000, width: 120, height: 100),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; controller.stop(); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(requestedSizes.isEmpty, "A mounted, collapsed inspector must not fetch a preview")

        host.rootView = thumbnail(presented: true)
        await GIFTestFixtures.waitUntil { releases.count == 1 }
        try #require(releases.count == 1)
        host.rootView = thumbnail(presented: false)
        try await Task.sleep(for: .milliseconds(100))
        releases[0].resume(returning: asset)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.displayedFrame == nil, "A hidden preview must not publish its cancelled load")
        #expect(requestedSizes.count == 1)

        host.rootView = thumbnail(presented: true)
        await GIFTestFixtures.waitUntil { releases.count == 2 }
        try #require(releases.count == 2)
        releases[1].resume(returning: asset)
        await GIFTestFixtures.waitUntil { controller.displayedFrame != nil }
        #expect(controller.displayedFrame != nil)

        host.rootView = thumbnail(presented: true, size: .hero)
        await GIFTestFixtures.waitUntil { releases.count == 3 }
        try #require(releases.count == 3)
        #expect(requestedSizes == [.tile, .tile, .hero])
        releases[2].resume(returning: asset)
    }

    @Test("A cached animation resumes when the mounted inspector returns")
    func cachedAnimationRestoresAfterInspectorReturns() async {
        let controller = GIFAnimationController()
        let asset = GIFTestFixtures.animatedAsset(frameCount: 3)
        var requests = 0
        func thumbnail(presented: Bool) -> AnyView {
            AnyView(AnimatedGIFThumbnail(
                url: URL(fileURLWithPath: "/cached.gif"), playbackMode: .autoPlay,
                controller: controller, loadAsset: { _, _ in requests += 1; return asset }
            ).environment(\.inspectorContentIsVisible, presented)
                .environment(\._accessibilityReduceMotion, false))
        }
        let host = NSHostingView(rootView: thumbnail(presented: true))
        let window = VisibilityWindow(contentRect: CGRect(x: -30000, y: -30000, width: 120, height: 100),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; controller.stop(); window.close() }
        host.layoutSubtreeIfNeeded()
        await GIFTestFixtures.waitUntil { controller.hasAnimatedAsset }
        try? await Task.sleep(for: .milliseconds(100))
        post(NSApplication.didBecomeActiveNotification)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)

        host.rootView = thumbnail(presented: false)
        await GIFTestFixtures.waitUntil { !controller.isAnimating }
        #expect(!controller.isAnimating)
        let previousRequests = requests
        host.rootView = thumbnail(presented: true)
        await GIFTestFixtures.waitUntil { requests > previousRequests }
        try? await Task.sleep(for: .milliseconds(100))
        post(NSApplication.didBecomeActiveNotification)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating, "An immediate cache hit still needs a fresh host visibility result")
    }
}

@Suite("GIF controller stale frame task", .serialized)
@MainActor
struct GIFAnimationControllerStaleTaskTests {
    /// `stop()` already released the slot; a cancelled frame task waking up afterwards must
    /// not unregister the playback that reused the same client id.
    @Test("A cancelled frame task never unregisters the playback that replaced it")
    func staleTaskKeepsReplacementRegistered() async throws {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.animatedAsset(frameCount: 3))
        controller.play(debounced: false)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating)
        // Same turn, no suspension: the stale task can only run after the replacement registered.
        controller.stop()
        controller.beginPlaybackNowForTesting()
        #expect(controller.isAnimating)
        try await Task.sleep(for: .milliseconds(300))
        #expect(GIFPlaybackCoordinator.shared.activeClientIDsForTesting.contains(controller.clientIDForTesting))
        controller.stop()
        #expect(!GIFPlaybackCoordinator.shared.activeClientIDsForTesting.contains(controller.clientIDForTesting))
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
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay],
        ] as CFDictionary
        for index in 0 ..< frameCount {
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
