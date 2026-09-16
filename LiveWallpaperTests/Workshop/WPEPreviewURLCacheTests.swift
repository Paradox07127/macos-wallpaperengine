#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import os
import Testing

@MainActor
@Suite("Installed preview URL cache", .serialized)
struct WPEPreviewURLCacheTests {
    private struct Resolution: Sendable {
        let workshopID: String
        let onMainThread: Bool
    }

    private nonisolated static func entry(_ id: String, bookmark: String, preview: String? = "preview.png") -> WPEHistoryEntry {
        WPEHistoryEntry(origin: WPEOrigin(
            workshopID: id, title: id, originalType: .scene,
            sourceFolderBookmark: Data(bookmark.utf8), cacheRelativePath: nil, previewFileName: preview
        ), importedAt: Date(timeIntervalSince1970: 0))
    }

    private nonisolated static func url(_ origin: WPEOrigin) -> URL? {
        origin.previewFileName.map { URL(fileURLWithPath: "/fixtures/\(origin.workshopID)/\($0)") }
    }

    @Test("Each preview is resolved once, off the main thread, then served synchronously")
    func prefetchResolvesOnce() async {
        let log = OSAllocatedUnfairLock(initialState: [Resolution]())
        let cache = WPEPreviewURLCache(resolve: { origin in
            log.withLock { $0.append(Resolution(workshopID: origin.workshopID, onMainThread: Thread.isMainThread)) }
            return Self.url(origin)
        })
        let first = Self.entry("1", bookmark: "a")
        let second = Self.entry("2", bookmark: "b")
        #expect(cache.url(for: first.origin) == nil)

        cache.prefetch([first, second])
        // Still in flight: a page reloading before the batch lands must not queue it twice.
        cache.prefetch([first, second])
        await GIFTestFixtures.waitUntil { cache.url(for: second.origin) != nil }
        cache.prefetch([first, second])
        await Task.yield()

        let resolutions = log.withLock { $0 }
        #expect(Set(resolutions.map(\.workshopID)) == ["1", "2"])
        #expect(resolutions.count == 2)
        #expect(resolutions.allSatisfy { !$0.onMainThread })
        #expect(cache.url(for: first.origin) == Self.url(first.origin))
        #expect(cache.url(for: second.origin) == Self.url(second.origin))
    }

    @Test("An origin without a preview is remembered as none and never re-resolved")
    func missingPreviewIsRemembered() async {
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let cache = WPEPreviewURLCache(resolve: { origin in
            calls.withLock { $0.append(origin.workshopID) }
            return Self.url(origin)
        })
        let none = Self.entry("none", bookmark: "a", preview: nil)
        let some = Self.entry("some", bookmark: "b")

        cache.prefetch([none, some])
        await GIFTestFixtures.waitUntil { cache.url(for: some.origin) != nil }
        cache.prefetch([none])
        await Task.yield()

        #expect(cache.url(for: none.origin) == nil)
        #expect(calls.withLock { $0 }.filter { $0 == "none" }.count == 1)
    }

    @Test("Changing the preview file under the same bookmark resolves a new path")
    func changedPreviewFileReResolves() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = WPEPreviewURLCache(resolve: { origin in
            calls.withLock { $0 += 1 }
            return Self.url(origin)
        })
        let before = Self.entry("1", bookmark: "a", preview: "first.png")
        let after = Self.entry("1", bookmark: "a", preview: "second.png")

        cache.prefetch([before])
        await GIFTestFixtures.waitUntil { cache.url(for: before.origin) != nil }
        cache.prefetch([after])
        await GIFTestFixtures.waitUntil { cache.url(for: after.origin) != nil }

        #expect(calls.withLock { $0 } == 2)
        #expect(cache.url(for: after.origin)?.lastPathComponent == "second.png")
        #expect(cache.url(for: before.origin)?.lastPathComponent == "first.png")
    }
}
#endif
