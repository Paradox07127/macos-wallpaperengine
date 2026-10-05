#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Storage inventory and cache maintenance")
struct AppStorageInventoryTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func parentBucketsExcludeChildrenAndCountHiddenFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let covers = root.appendingPathComponent("Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent(".settings"))
        try Data(repeating: 2, count: 16384).write(to: covers.appendingPathComponent("cover.png"))
        let locations = [AppStorageLocation(kind: .configuration, url: root), .init(kind: .covers, url: covers)]
        let measured = await AppStorageScanner().scan(locations)
        #expect(measured.map(\.fileCount) == [1, 1])
        #expect(measured.allSatisfy { $0.status == .complete && $0.bytes > 0 })
        let whole = await AppStorageScanner().scan([locations[0]])
        #expect(measured.reduce(0) { $0 + $1.bytes } == whole[0].bytes)
    }

    @Test func symlinksDoNotCountExternalFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32768).write(to: external.appendingPathComponent("original.mp4"))
        let link = owned.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let measured = await AppStorageScanner().scan([.init(kind: .support, url: owned), .init(kind: .temporary, url: link)])
        #expect(measured[0].bytes == 0)
        #expect(measured[0].fileCount == 0)
        #expect(measured[1].status == .unavailable)
        #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("original.mp4").path))
    }

    @Test func boundedWalkReportsPartialAndMissingIsDistinct() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0 ..< 4 {
            try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("\(index).bin"))
        }
        let measured = await AppStorageScanner().scan([
            .init(kind: .support, url: root),
            .init(kind: .covers, url: root.appendingPathComponent("absent")),
        ], budget: 1)
        #expect(measured[0].fileCount == 1)
        #expect(measured[0].status == .partial)
        #expect(measured[1].status == .missing)
    }

    @Test func sharedMetadataExcludesExportedVideos() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let videos = root.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("manifest.json"))
        try Data(repeating: 1, count: 32768).write(to: videos.appendingPathComponent("video.mp4"))
        let measured = await AppStorageScanner().scan([.init(kind: .systemMetadata, url: root)], excluding: [videos])
        #expect(measured[0].fileCount == 1)
    }

    @Test func externallyCountedRootsAreExcludedFromOwnedBuckets() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: engine.appendingPathComponent("asset.bin"))
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("keep.bin"))
        let measured = await AppStorageScanner().scan([
            .init(kind: .support, url: root), .init(kind: .legacyScenes, url: engine),
        ], excluding: [engine])
        #expect(measured[0].fileCount == 1)
        #expect(measured[1].bytes == 0)
    }

    @Test func previewCacheCanBeClearedAndReused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WorkshopPreviewDiskCache(directoryURL: root)
        let url = try #require(URL(string: "https://example.test/preview.png"))
        let data = Data([1, 2, 3])
        await cache.store(data, for: url, size: .tile)
        #expect(await cache.data(for: url, size: .tile) == data)
        await cache.clear()
        #expect(await cache.data(for: url, size: .tile) == nil)
        await cache.store(data, for: url, size: .tile)
        #expect(await cache.data(for: url, size: .tile) == data)
    }

    @Test func shaderCacheClearsMemoryAndEverySchemaWithoutTouchingOtherFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WPEShaderTranslationCache(rootURL: root)
        let payload = WPEShaderTranslationCache.Payload(
            schemaVersion: WPEShaderTranslationCache.schemaVersion,
            vertexFunctionName: "vertex", fragmentFunctionName: "fragment",
            mslSource: "source", uniformLayout: [], samplerNames: [], textureSlotCount: 0
        )
        cache.store(payload, for: "fixture")
        #expect(cache.lookup("fixture") == payload)
        let stale = root.appendingPathComponent("v0", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data([1]).write(to: stale.appendingPathComponent("old.json"))
        let retained = root.appendingPathComponent("keep.txt")
        try Data([2]).write(to: retained)
        try cache.clearCache()
        #expect(cache.lookup("fixture") == nil)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
        cache.store(payload, for: "fixture")
        #expect(cache.lookup("fixture") == payload)
    }

    @Test func audioCacheRebuildsAfterClearingWithoutRemovingStagingFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.ogg")
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try Data([1, 2, 3]).write(to: source)
        let transcoder = OggAudioTranscoder(cacheDirectory: cacheRoot, decode: { _, destination, _ in
            try? Data([4, 5, 6]).write(to: destination)
            return destination
        })
        let first = try #require(await transcoder.transcodedM4A(forOgg: source))
        let staged = cacheRoot.appendingPathComponent(".active.m4a.partial")
        try Data([7]).write(to: staged)
        try await transcoder.clearCache()
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: staged.path))
        let next = try #require(await transcoder.transcodedM4A(forOgg: source))
        #expect(FileManager.default.fileExists(atPath: next.path))
    }
}
#endif
