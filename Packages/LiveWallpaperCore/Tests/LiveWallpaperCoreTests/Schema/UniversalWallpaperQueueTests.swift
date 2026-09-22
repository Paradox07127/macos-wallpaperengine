import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Universal wallpaper queue")
struct UniversalWallpaperQueueTests {
    @Test("Legacy primary placement, cursor and packaged entry survive migration and encoding")
    func legacyMigration() throws {
        var config = ScreenConfiguration(screenID: 7, wallpaper: .video(bookmarkData: Data([1]), packageEntryName: "main.mp4"), playlistBookmarks: [Data([2]), Data([3])], playlistCursorIndex: 2)
        config.playlistPrimaryIndex = 1
        let legacy = try JSONEncoder().encode(config)
        var decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: legacy)
        #expect(decoded.effectiveWallpaperQueue.map(\.content.activeVideoBookmarkData) == [Data([2]), Data([1]), Data([3])])
        #expect(decoded.effectiveWallpaperQueue[1].content.packageVideoEntryName == "main.mp4")
        #expect(decoded.playlistCursorIndex == 2)
        decoded.wallpaperQueue = decoded.effectiveWallpaperQueue
        #expect(try JSONDecoder().decode(ScreenConfiguration.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

    @Test("Video, packaged video, web and scene entries round-trip and preserve display preferences")
    func mixedQueueRoundTrip() throws {
        let contents: [WallpaperContent] = [
            .video(bookmarkData: Data([1])), .video(bookmarkData: Data([2]), packageEntryName: "media.mp4"),
            .html(source: .inline("<p>hello</p>"), config: .default),
            .scene(SceneDescriptor(workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "scene.json", capabilityTier: .imageOnly)),
        ]
        let entries = contents.map { WallpaperQueueEntry(title: "Sample", content: $0) }
        var config = ScreenConfiguration(screenID: 7, wallpaper: contents[0], playbackSpeed: 0.5, fitMode: .aspectFit, frameRateLimit: .fps30)
        config.wallpaperQueue = entries
        config.scheduleFallback = entries[0]
        config.scheduleSlots = [ScheduleSlot(startHour: 22, endHour: 6, label: "Night", wallpaper: entries[3])]
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        for entry in entries {
            let selected = decoded.applyingAutomationEntry(entry)
            #expect(selected.activeWallpaper == entry.content)
            #expect(selected.fitMode == .aspectFit && selected.playbackSpeed == 0.5 && selected.frameRateLimit == .fps30)
            #expect(selected.wallpaperQueue == entries)
            #expect(selected.canNavigatePlaylist)
        }
    }

    @Test("Leaving a scene for a web queue entry remembers its customization")
    func remembersSceneBeforeWeb() {
        let scene = SceneDescriptor(workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "scene.json", capabilityTier: .imageOnly)
        let config = ScreenConfiguration(screenID: 1, wallpaper: .scene(scene))
        let web = config.applyingAutomationEntry(WallpaperQueueEntry(title: "Web", content: .html(source: .inline("hello"), config: .default)))
        #expect(web.savedSceneCustomizations.contains(scene))
    }

    @Test("An explicitly empty queue does not resurrect the legacy video list")
    func emptyQueue() {
        var config = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]), playlistBookmarks: [Data([2])])
        config.wallpaperQueue = []
        #expect(config.effectiveWallpaperQueue.isEmpty)
        #expect(!config.canNavigatePlaylist)
    }

    @Test("Refreshing a packaged bookmark also refreshes queue, schedule and fallback references")
    func refreshedBookmark() {
        let entry = WallpaperQueueEntry(title: "Packaged", content: .video(bookmarkData: Data([1]), packageEntryName: "a.mp4"))
        var config = ScreenConfiguration(screenID: 1, wallpaper: entry.content)
        config.wallpaperQueue = [entry]
        config.scheduleFallback = entry
        config.scheduleSlots = [ScheduleSlot(startHour: 0, endHour: 24, label: "", wallpaper: entry)]
        let updated = config.withUpdatedActiveBookmark(Data([2]))
        for entry in [updated.wallpaperQueue?.first, updated.scheduleFallback, updated.scheduleSlots?.first?.wallpaper].compactMap(\.self) {
            #expect(entry.content == .video(bookmarkData: Data([2]), packageEntryName: "a.mp4"))
        }
    }
}
