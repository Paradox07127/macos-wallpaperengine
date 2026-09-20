#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Local wallpaper directory reading")
@MainActor
struct LocalWallpaperLibraryTests {
    @Test("Unbookmarked projects are read from disk without the history limit")
    func readsAllProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = Set<String>()
        for index in 1 ... 25 {
            let folder = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = #"{"title":"Local wallpaper","type":"video","file":"video.mp4"}"#
            try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data().write(to: folder.appendingPathComponent("video.mp4"))
            let entry = try #require(try LocalWallpaperLibrary.readEntry(in: folder, makeBookmark: { _ in Data([1]) }))
            ids.insert(entry.id)
            #expect(entry.origin.title == "Local wallpaper")
        }
        #expect(ids.count == 25)
    }

    @Test("A manifest without its downloaded content is not a local wallpaper")
    func missingContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"title":"Missing","type":"video","file":"missing.mp4"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        #expect(throws: (any Error).self) {
            try LocalWallpaperLibrary.readEntry(in: folder, makeBookmark: { _ in Data([1]) })
        }
    }
}
#endif
