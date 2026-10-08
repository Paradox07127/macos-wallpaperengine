import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Playlist entry titles")
struct PlaylistEntryTitleTests {
    @Test("A playlist row shows the library card's title, not the file name it was queued under")
    func rowUsesLibraryTitle() throws {
        let content = WallpaperContent.video(bookmarkData: Data([7]))
        let bookmark = WallpaperBookmark(label: "Overgrown Cabin", content: content)
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [bookmark] }
        let library = SavedLibraryModel(inputs: inputs)
        let item = try #require(library.items.first { $0.id == "bookmark:\(bookmark.id)" })
        let entry = WallpaperQueueEntry(title: "Minecraft Overgrown Cabin_2_prob4", content: content)

        #expect(WallpaperAutomationSheet.rowTitle(for: entry, in: library) == item.title.translatedWallpaperName)
    }

    @Test("A row with no library match keeps its own title")
    func unmatchedRowKeepsOwnTitle() {
        let library = SavedLibraryModel(inputs: SavedLibraryModel.Inputs())
        let entry = WallpaperQueueEntry(title: "Loose clip", content: .video(bookmarkData: Data([8])))

        #expect(WallpaperAutomationSheet.rowTitle(for: entry, in: library) == "Loose clip")
    }

    @Test("A saved scene variant keeps its own title instead of the first card with its Workshop ID")
    func sceneVariantKeepsItsOwnTitle() {
        func scene(preset: String?) -> WallpaperContent {
            .scene(SceneDescriptor(
                workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "scene.json",
                capabilityTier: .imageOnly, presetID: preset
            ))
        }
        let base = WallpaperBookmark(label: "Lantern Festival", content: scene(preset: nil))
        let variant = WallpaperBookmark(label: "Lantern Festival (Blue)", content: scene(preset: "blue"))
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [base, variant] }
        let library = SavedLibraryModel(inputs: inputs)
        let entry = WallpaperQueueEntry(title: "Lantern Festival (Blue)", content: variant.content)

        let title = WallpaperAutomationSheet.rowTitle(for: entry, in: library)
        #expect(title == "Lantern Festival (Blue)".translatedWallpaperName)
    }

    @Test("A video row names its folder unless the folder is a Workshop item's numeric ID")
    func subtitleOmitsOnlyTheWorkshopFolder() {
        let metadata = RowMetadata(resolution: nil, duration: 30, folder: "Wallpapers")
        let local = WallpaperQueueEntry(title: "Loose clip", content: .video(bookmarkData: Data([8])))
        let origin = WPEOrigin(
            workshopID: "123456789", title: "Rain", originalType: .video,
            sourceFolderBookmark: Data([9]), cacheRelativePath: nil, previewFileName: nil
        )
        let workshop = WallpaperQueueEntry(title: "Rain", content: .video(bookmarkData: Data([9])), origin: origin)

        #expect(WallpaperAutomationSheet.rowSubtitle(metadata, for: local) == "0:30 · Wallpapers")
        #expect(WallpaperAutomationSheet.rowSubtitle(metadata, for: workshop) == "0:30")
    }
}
