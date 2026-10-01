import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Playlist navigation availability")
struct PlaylistNavigationAvailabilityTests {
    @Test("Library shuffle persists independently and older configurations get a default interval")
    func libraryShuffleRoundTrip() throws {
        var config = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]), playlistBookmarks: [Data([2])])
        config.wallpaperMode = .libraryShuffle
        config.libraryShuffleRotationMinutes = 30
        config.playlistRotationMinutes = 120
        let failed = WallpaperQueueEntry(id: "failed", title: "Failed", content: .html(source: .inline("bad"), config: .default))
        config.automationFailures[failed.id] = WallpaperAutomationFailure(entry: failed, failedAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ScreenConfiguration.self, from: data) == config)
        #expect(!config.canNavigatePlaylist)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "libraryShuffleRotationMinutes")
        legacy["wallpaperMode"] = "single"
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.libraryShuffleRotationMinutes == 15)
        #expect(decoded.wallpaperMode == .playlist)
        #expect(decoded.playlistRotationMinutes == 120)
        legacy["libraryShuffleRotationMinutes"] = -1
        #expect(try JSONDecoder().decode(ScreenConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)).libraryShuffleRotationMinutes == 1)
    }

    @Test("A single video hides stepping; adding another shows it; schedule mode hides it")
    func activeVideoQueue() {
        var config = ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([1])))
        #expect(!config.canNavigatePlaylist)
        config.playlistBookmarks = [Data([2])]
        #expect(config.canNavigatePlaylist)
        config.wallpaperMode = .schedule
        #expect(!config.canNavigatePlaylist)
        config.wallpaperMode = .playlist
        config.playlistBookmarks = []
        #expect(!config.canNavigatePlaylist)
    }

    @Test("A remembered video list never enables stepping on a scene or web wallpaper")
    func dormantQueueDoesNotReplaceOtherWallpaperTypes() {
        var config = ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([1])),
                                         playlistBookmarks: [Data([2])])
        config.setHTMLWallpaper(source: .inline("hello"))
        #expect(config.combinedPlaylist.count == 2)
        #expect(!config.canNavigatePlaylist)
        config.setSceneWallpaper(SceneDescriptor(workshopID: "scene", cacheRelativePath: "wpe-cache/scene",
                                                 entryFile: "scene.pkg", capabilityTier: .imageOnly), origin: nil)
        #expect(config.combinedPlaylist.count == 2)
        #expect(!config.canNavigatePlaylist)
        let activated = config.activateSavedVideoWallpaper()
        #expect(activated)
        #expect(config.canNavigatePlaylist)
    }
}
