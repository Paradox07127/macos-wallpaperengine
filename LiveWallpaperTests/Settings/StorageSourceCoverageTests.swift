#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Wallpaper storage and protected locations")
struct StorageSourceCoverageTests {
    @Test func relatedWallpaperRootsAreCountedOnlyOnce() {
        func source(_ path: String) -> StorageLinkedSource {
            .init(url: URL(fileURLWithPath: path), bookmark: Data())
        }
        let roots = StorageLinkedSources.distinctRoots([
            source("/wallpapers/video.mp4"), source("/wallpapers"), source("/wallpapers"),
            source("/wallpapers/sub/scene.pkg"), source("/wallpapers-other/video.mp4"),
        ])
        #expect(Set(roots.map(\.id)) == ["/wallpapers", "/wallpapers-other/video.mp4"])
    }

    @Test @MainActor func linkedFilesAreMeasuredWithoutDoubleCountingOwnedParents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-storage-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("wallpaper.mp4")
        try Data(repeating: 1, count: 16384).write(to: video)
        try Data(repeating: 2, count: 8192).write(to: root.appendingPathComponent("other.bin"))
        let bookmark = try video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let sources = [StorageLinkedSource(url: video, bookmark: bookmark)]
        let parent = AppStorageLocation(kind: .temporary, url: root)
        let measured = await StorageLinkedSources.scan(sources, locations: [parent], excluding: [])
        let wallpaper = try #require(measured.first { $0.location.kind == .localWallpapers })
        #expect(wallpaper.bytes > 0 && wallpaper.fileCount == 1 && wallpaper.status == .complete)
        #expect(measured.first { $0.location.kind == .temporary }?.fileCount == 1)
        let whole = await AppStorageScanner().scan([parent])
        #expect(measured.reduce(0) { $0 + $1.bytes } == whole[0].bytes)
    }

    @Test @MainActor func unresolvedSourceIsUnavailableRatherThanAZeroSizedWallpaper() async {
        let source = StorageLinkedSource(url: URL(fileURLWithPath: "/unresolved-wallpaper.mp4"), bookmark: Data([0]))
        let measured = await StorageLinkedSources.scan([source], locations: [], excluding: [])
        #expect(measured.count == 1)
        #expect(measured[0].status == .unavailable)
    }

    @Test func protectedDataHasNoFinderOrClearAction() {
        for kind: AppStorageLocation.Kind in [.steamProfiles, .credentials, .application, .support, .webData, .configuration, .preferences] {
            #expect(!kind.canRevealInFinder)
            #expect(!kind.canClear)
        }
        #expect(AppStorageLocation.Kind.localWallpapers.canRevealInFinder)
        #expect(!AppStorageLocation.Kind.localWallpapers.canClear)
        #expect(AppStorageLocation.Kind.allCases.filter(\.canClear).count == 6)
    }

    @Test func bundleAndCredentialsAreDisjointFromSupportData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("protected-storage-\(UUID())", isDirectory: true)
        let bundle = root.appendingPathComponent("Loomscreen.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = root.appendingPathComponent("credentials.key")
        try Data(repeating: 1, count: 8192).write(to: bundle.appendingPathComponent("binary"))
        try Data(repeating: 2, count: 8192).write(to: credentials)
        let measured = await AppStorageScanner().scan([
            .init(kind: .support, url: root), .init(kind: .application, url: bundle), .init(kind: .credentials, url: credentials),
        ])
        #expect(measured.map(\.fileCount) == [0, 1, 1])
        #expect(measured[1].bytes > 0 && measured[2].bytes > 0)
    }
}
#endif
