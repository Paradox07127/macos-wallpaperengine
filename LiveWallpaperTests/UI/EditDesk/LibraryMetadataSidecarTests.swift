import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Library metadata sidecar")
struct LibraryMetadataSidecarTests {
    private actor ProbeCounter {
        var count = 0

        func record() -> Int {
            count += 1
            return count
        }
    }

    private static let sample = LibraryMetadata.Video(
        resolution: CGSize(width: 3840, height: 2160), isHDR: true,
        duration: 92, fileSize: 123_456, probedAt: Date(timeIntervalSince1970: 1234)
    )

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func bookmark(at root: URL, entryName: String? = nil) throws -> WallpaperBookmark {
        let url = root.appendingPathComponent("video.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data([0]).write(to: url)
        }
        return try WallpaperBookmark(label: "Video", content: .video(
            bookmarkData: url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            packageEntryName: entryName
        ))
    }

    @Test("A second read uses the record without probing again")
    func probesOnce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try bookmark(at: root)
        let counter = ProbeCounter()
        let sample = Self.sample
        let store = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in
            _ = await counter.record()
            return sample
        }
        #expect(store.cached(for: bookmark) == nil)
        #expect(await store.metadata(for: bookmark) == .video(sample))
        #expect(store.cached(for: bookmark) == .video(sample))
        #expect(await store.metadata(for: bookmark) == .video(sample))
        #expect(await counter.count == 1)
    }

    @Test("A new instance reads all fields from disk without probing")
    func roundTrips() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try bookmark(at: root)
        let sample = Self.sample
        let writer = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in sample }
        #expect(await writer.metadata(for: bookmark) == .video(sample))
        let counter = ProbeCounter()
        let reader = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in
            _ = await counter.record()
            return nil
        }
        #expect(reader.cached(for: bookmark) == .video(sample))
        #expect(await reader.metadata(for: bookmark) == .video(sample))
        #expect(await counter.count == 0)
    }

    @Test("Web and scene content never probe or create a sidecar")
    func nonVideoIsNotApplicable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = ProbeCounter()
        let store = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in
            _ = await counter.record()
            return nil
        }
        let bookmarks = try [
            WallpaperBookmark(label: "Web", content: .html(
                source: .url(#require(URL(string: "https://example.com"))), config: HTMLConfig()
            )),
            WallpaperBookmark(label: "Scene", content: .scene(SceneDescriptor(
                workshopID: "1", cacheRelativePath: "scene", entryFile: "scene.json", capabilityTier: .imageOnly
            ))),
        ]
        for bookmark in bookmarks {
            #expect(store.cached(for: bookmark) == .notApplicable)
            #expect(await store.metadata(for: bookmark) == .notApplicable)
        }
        #expect(await counter.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Resolution labels use VideoFormatInfo")
    func resolutionLabels() {
        let sizes = [
            CGSize(width: 3840, height: 2160),
            CGSize(width: 1920, height: 1080),
            CGSize(width: 2160, height: 3840),
        ]
        for size in sizes {
            let metadata = LibraryMetadata.video(LibraryMetadata.Video(
                resolution: size, isHDR: false, duration: nil, fileSize: nil, probedAt: Date()
            ))
            #expect(metadata.resolutionShortLabel == VideoFormatInfo.resolutionShortLabel(
                width: Int(size.width), height: Int(size.height)
            ))
        }
        #expect(LibraryMetadata.notApplicable.resolutionShortLabel == nil)
    }

    @Test("Different bookmark IDs for the same resource share a record")
    func sharesResourceIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try bookmark(at: root)
        let second = try bookmark(at: root)
        #expect(first.id != second.id)
        let sample = Self.sample
        let counter = ProbeCounter()
        let store = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in
            _ = await counter.record()
            return sample
        }
        #expect(await store.metadata(for: first) == .video(sample))
        #expect(store.cached(for: second) == .video(sample))
        #expect(await store.metadata(for: second) == .video(sample))
        #expect(await counter.count == 1)
    }

    @Test("Package entry names reach the probe and distinguish records")
    func packagedEntries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try bookmark(at: root, entryName: "first.mp4")
        let same = try bookmark(at: root, entryName: "first.mp4")
        let second = try bookmark(at: root, entryName: "second.mp4")
        let sample = Self.sample
        let counter = ProbeCounter()
        let store = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { url, entry in
            #expect(url.lastPathComponent == "video.mp4")
            #expect(entry == "first.mp4" || entry == "second.mp4")
            _ = await counter.record()
            return sample
        }
        #expect(await store.metadata(for: first) == .video(sample))
        #expect(await store.metadata(for: same) == .video(sample))
        #expect(await store.metadata(for: second) == .video(sample))
        #expect(await counter.count == 2)
        let reader = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in nil }
        #expect(reader.cached(for: first) == .video(sample))
        #expect(reader.cached(for: second) == .video(sample))
    }

    @Test("A failed probe stores nothing and the next read retries")
    func retriesFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try bookmark(at: root)
        let sample = Self.sample
        let counter = ProbeCounter()
        let store = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in
            await counter.record() == 1 ? nil : sample
        }
        #expect(await store.metadata(for: bookmark) == nil)
        #expect(store.cached(for: bookmark) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["video.mp4"])
        #expect(await store.metadata(for: bookmark) == .video(sample))
        #expect(await counter.count == 2)
    }

    @Test("Replacing the file behind a path re-probes instead of serving the old record")
    func revisionInvalidatesRecord() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try bookmark(at: root)
        let counter = ProbeCounter()
        let first = Self.sample
        let second = LibraryMetadata.Video(
            resolution: CGSize(width: 1920, height: 1080), isHDR: false,
            duration: 12, fileSize: 42, probedAt: Date(timeIntervalSince1970: 5678)
        )
        let store = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root)) { _, _ in
            await counter.record() == 1 ? first : second
        }
        #expect(await store.metadata(for: bookmark) == .video(first))

        // Same path, different video: a 1080p file replaces the 4K one it was probed from.
        let url = root.appendingPathComponent("video.mp4")
        try Data([1, 2, 3, 4]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path
        )
        #expect(store.cached(for: bookmark) == nil, "the record keyed on the old revision must not answer for the new file")
        #expect(await store.metadata(for: bookmark) == .video(second))
        #expect(await counter.count == 2)
    }
}
