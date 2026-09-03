import Foundation
import Testing
@testable import LiveWallpaper

/// Exercises the direct Apple Aerials path inside the signed sandboxed test host.
/// Running without host entitlements can make these checks false-green; machines without the store skip dependent cases.
struct AppleAerialsFastPathTests {

    /// The user-picked Aerials folder is the enumeration root, and
    /// `FileManager.enumerator(at:)` yields nothing when that root is a symlink.
    @Test("A recursive scan rooted at a symlink still finds the .mov files")
    func recursiveScanThroughSymlinkRoot() throws {
        let fixture = try makeMovFixture()
        defer { fixture.cleanup() }

        let assets = try AppleAerialsLibrary.scanAssets(
            in: fixture.link, recursively: true, bookmarkCreator: { _ in Data() }
        )

        #expect(assets.map(\.id) == ["clip"])
    }

    @Test("A recursive scan rooted at a real directory finds the .mov files")
    func recursiveScanThroughRealRoot() throws {
        let fixture = try makeMovFixture()
        defer { fixture.cleanup() }

        let assets = try AppleAerialsLibrary.scanAssets(
            in: fixture.directory, recursively: true, bookmarkCreator: { _ in Data() }
        )

        #expect(assets.map(\.id) == ["clip"])
    }

    /// `<directory>/nested/clip.mov` plus `<link>` -> `<directory>`.
    private func makeMovFixture() throws -> (directory: URL, link: URL, cleanup: () -> Void) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0x00]).write(to: nested.appendingPathComponent("clip.mov"))
        let link = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: directory)
        return (directory, link, {
            try? fileManager.removeItem(at: link)
            try? fileManager.removeItem(at: directory)
        })
    }

    @Test("realHomeDirectory resolves the true home, not the sandbox container")
    func realHomeIsNotContainer() {
        let real = AppleAerialsLibrary.realHomeDirectory().path
        #expect(!real.contains("/Library/Containers/"), "realHomeDirectory returned a container path: \(real)")
        #expect(real != NSHomeDirectory(), "real home must differ from the sandbox container")
    }

    @Test("Direct read + security-scoped bookmark round-trip for the standard aerials store")
    func directReadAndBookmarkWork() throws {
        guard let dir = AppleAerialsLibrary.defaultReadableDirectory() else {
            return
        }
        _ = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)

        let videos = dir.appendingPathComponent("videos", isDirectory: true)
        let movDir = FileManager.default.fileExists(atPath: videos.path(percentEncoded: false)) ? videos : dir
        guard let mov = (try? FileManager.default.contentsOfDirectory(
            at: movDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension.lowercased() == "mov" }) else {
            return
        }

        let bookmark = try DirectoryBookmarks.createReadOnlyBookmark(for: mov)
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #expect(resolved.standardizedFileURL == mov.standardizedFileURL)
        let ok = resolved.startAccessingSecurityScopedResource()
        defer { if ok { resolved.stopAccessingSecurityScopedResource() } }
        #expect(ok, "resolved security-scoped bookmark should grant access")
    }

    @Test("Fast path authorizes + populates assets with no folder-grant")
    @MainActor
    func fastPathPopulatesAssets() async {
        guard AppleAerialsLibrary.defaultReadableDirectory() != nil else {
            return
        }
        let library = AppleAerialsLibrary()
        #expect(library.isAuthorized, "standard store should authorize without a Powerbox grant")
        await library.refresh()
        #expect(library.lastScanError == nil, "scan error: \(library.lastScanError ?? "none")")
        #expect(!library.assets.isEmpty, "fast path should discover aerials from the standard store")
    }
}
