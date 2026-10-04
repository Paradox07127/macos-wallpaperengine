import Foundation
import LiveWallpaperProWPE
import Testing

struct WPEPathSafetyDottedNameTests {
    @Test(arguments: ["light like feather..mp4", "videos/a..b.mp4", "..hidden.mp4", "trail..", "a/..b/c"])
    func relativePathAcceptsDotsInsideAName(path: String) {
        #expect(WPEPathSafety.isSafeRelativePath(path))
    }

    @Test(arguments: ["..", "../x", "a/../b", "a/..", "/abs", ".", "", "a\0b", "..\\x", "a\\..\\b"])
    func relativePathRejectsTraversalAndAbsolutePaths(path: String) {
        #expect(!WPEPathSafety.isSafeRelativePath(path))
    }

    @Test(arguments: ["My..Wallpaper", "light like feather..", "..start"])
    func componentAcceptsDotsInsideAName(name: String) {
        #expect(WPEPathSafety.isSafePathComponent(name))
        #expect(WPEPathSafety.isSafeProjectID(name))
        #expect(WPEPathSafety.isSafeCacheRelativePath("wpe-cache/\(name)"))
    }

    @Test(arguments: ["..", ".", "", "a/b", "a\\b", "../x", "a\0b"])
    func componentRejectsSeparatorsAndDotNames(name: String) {
        #expect(!WPEPathSafety.isSafePathComponent(name))
        #expect(!WPEPathSafety.isSafeProjectID(name))
    }

    @Test(arguments: ["wpe-cache/..", "wpe-cache/../x", "wpe-cache/a/../b", "wpe-cache//x", "wpe-cache/a\\b", "other/x"])
    func cachePathRejectsTraversal(path: String) {
        #expect(!WPEPathSafety.isSafeCacheRelativePath(path))
    }

    @Test func resourceURLResolvesADoubleDotFileName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-path-safety-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(WPEPathSafety.resourceURL(root: root, relativePath: "light like feather..mp4"))
        #expect(url.lastPathComponent == "light like feather..mp4")
        #expect(WPEPathSafety.contains(url, in: root.standardizedFileURL.resolvingSymlinksInPath()))
    }
}
