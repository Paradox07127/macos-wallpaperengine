import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Wallpaper library import", .serialized)
@MainActor
struct LibraryImporterTests {
    private let bookmarks = BookmarkStore(persistence: LibraryImportBookmarkPersistence())

    @Test func addsFilesWithoutTouchingDisplays() throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("clip.mp4")
        let page = folder.appendingPathComponent("index.html")
        let note = folder.appendingPathComponent("notes.txt")
        for url in [video, page, note] {
            try Data("fixture".utf8).write(to: url)
        }
        let importer = LibraryImporter(bookmarks: bookmarks, sceneCapable: true)

        #expect(importer.add([video, page, note]) == LibraryImporter.Outcome(added: 2, failed: 1))
        #expect(bookmarks.bookmarks.count == 2)
        _ = importer.add([video])
        #expect(bookmarks.bookmarks.count == 2, "the same video was saved twice")
    }

    @Test func projectFoldersFollowTheSceneCapability() throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))

        let pro = LibraryImporter(bookmarks: bookmarks, sceneCapable: true).add([folder])
        let lite = LibraryImporter(bookmarks: bookmarks, sceneCapable: false).add([folder])

        #expect(pro == LibraryImporter.Outcome(projectFolders: [folder]))
        #expect(lite == LibraryImporter.Outcome(failed: 1))
        #expect(bookmarks.bookmarks.isEmpty, "a project folder was saved as a web page")
    }

    @Test func plainFolderAddsTheVideosInsideIt() throws {
        let videos = try fixtureFolder()
        let empty = try fixtureFolder()
        defer {
            try? FileManager.default.removeItem(at: videos)
            try? FileManager.default.removeItem(at: empty)
        }
        for name in ["one.mp4", "two.mov"] {
            try Data("fixture".utf8).write(to: videos.appendingPathComponent(name))
        }
        let importer = LibraryImporter(bookmarks: bookmarks, sceneCapable: true)

        #expect(importer.add([videos, empty]) == LibraryImporter.Outcome(added: 2, failed: 1))
        #expect(bookmarks.bookmarks.count == 2)
        #expect(bookmarks.bookmarks.allSatisfy { $0.content.wallpaperType == .video }, "the folder was saved as a web page")
    }

    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@MainActor
private final class LibraryImportBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}
