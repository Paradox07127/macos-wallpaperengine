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
}
