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

        #expect(importer.add([video, page, note]) == LibraryImporter.Outcome(added: 2, failed: 1, failures: [.init(url: note, reason: .unsupportedFormat)]))
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
        #expect(lite == LibraryImporter.Outcome(failed: 1, failures: [.init(url: folder, reason: .scenesUnavailable)]))
        #expect(bookmarks.bookmarks.isEmpty, "a project folder was saved as a web page")
    }

    @Test func plainFolderAddsTheVideosInsideIt() throws {
        let videos = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: videos) }
        let empty = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: empty) }
        for name in ["one.mp4", "two.mov"] {
            try Data("fixture".utf8).write(to: videos.appendingPathComponent(name))
        }
        let importer = LibraryImporter(bookmarks: bookmarks, sceneCapable: true)

        #expect(importer.add([videos, empty]) == LibraryImporter.Outcome(added: 2, failed: 1, failures: [.init(url: empty, reason: .noWallpaperInFolder)]))
        #expect(bookmarks.bookmarks.count == 2)
        #expect(bookmarks.bookmarks.allSatisfy { $0.content.wallpaperType == .video }, "the folder was saved as a web page")
    }

    @Test func sameLocalPageIsSavedOnce() throws {
        let site = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: site) }
        let otherSite = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: otherSite) }
        try Data("<html></html>".utf8).write(to: site.appendingPathComponent("index.html"))
        let plain = try site.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let named = try site.bookmarkData(options: [], includingResourceValuesForKeys: [.nameKey], relativeTo: nil)
        try #require(plain != named)
        func page(_ bookmark: Data, index: String = "index.html") -> WallpaperContent {
            .html(source: .folder(bookmarkData: bookmark, indexFileName: index), config: .default)
        }

        #expect(ApplyRouter.saveIfNew(page(plain), label: "Site", in: bookmarks) != nil)
        #expect(ApplyRouter.saveIfNew(page(named), label: "Site", in: bookmarks) == nil, "the same page was saved twice")
        #expect(bookmarks.bookmarks.count == 1)
        // Controls: another page in the same folder, and another folder, are different wallpapers.
        #expect(ApplyRouter.saveIfNew(page(named, index: "other.html"), label: "Other page", in: bookmarks) != nil)
        let elsewhere = try otherSite.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #expect(ApplyRouter.saveIfNew(page(elsewhere), label: "Other site", in: bookmarks) != nil)
    }

    @Test func sameLocalFileIsSavedOnce() throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("page.html")
        let otherFile = folder.appendingPathComponent("other.html")
        for url in [file, otherFile] {
            try Data("<html></html>".utf8).write(to: url)
        }
        let plain = try file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let named = try file.bookmarkData(options: [], includingResourceValuesForKeys: [.nameKey], relativeTo: nil)
        try #require(plain != named)
        func page(_ bookmark: Data) -> WallpaperContent {
            .html(source: .file(bookmarkData: bookmark), config: .default)
        }

        #expect(ApplyRouter.saveIfNew(page(plain), label: "Page", in: bookmarks) != nil)
        #expect(ApplyRouter.saveIfNew(page(named), label: "Page", in: bookmarks) == nil, "the same page was saved twice")
        #expect(bookmarks.bookmarks.count == 1)
        // Control: another file in the same folder is a different wallpaper.
        let other = try otherFile.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #expect(ApplyRouter.saveIfNew(page(other), label: "Other page", in: bookmarks) != nil)
    }

    @Test func mixedImportKeepsEachFailureAndWhy() throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("clip.mp4")
        let note = folder.appendingPathComponent("notes.txt")
        for url in [video, note] {
            try Data("fixture".utf8).write(to: url)
        }
        let empty = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: empty) }
        let locked = try fixtureFolder()
        try Data("fixture".utf8).write(to: locked.appendingPathComponent("hidden.mp4"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
        }
        try #require(
            (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) == nil,
            "the locked folder is still readable, so the test can't tell a read failure from an empty folder"
        )

        let outcome = LibraryImporter(bookmarks: bookmarks, sceneCapable: true).add([video, note, empty, locked])

        #expect(outcome.added == 1)
        #expect(outcome.failed == 3)
        #expect(outcome.failures.map(\.url) == [note, empty, locked])
        #expect(outcome.failures.map(\.reason) == [.unsupportedFormat, .noWallpaperInFolder, .folderUnreadable])
        let lines = try #require(outcome.failureSummary).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("notes.txt") == true)
    }

    @Test func pageWhoseBookmarkFailsIsReportedAsNoAccess() throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("missing.html")

        let outcome = LibraryImporter(bookmarks: bookmarks, sceneCapable: true).add([missing])

        #expect(outcome.failures.map(\.reason) == [.noAccess], "a page the app couldn't bookmark was reported as an unsupported format")
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
