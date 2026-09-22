import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Playlist navigation availability")
struct PlaylistNavigationAvailabilityTests {
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
