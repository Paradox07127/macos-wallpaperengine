import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Wallpaper cover store", .serialized)
struct WallpaperCoverStoreTests {
    private static func solidImage(_ color: NSColor, size: NSSize = NSSize(width: 8, height: 6)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private static func makeStore() throws -> (WallpaperCoverStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (WallpaperCoverStore(directory: ConfigurationDirectory(root: root)), root)
    }

    @Test("A stored cover reads back and lands under the entry's id")
    func storeAndRead() async throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let fileName = try #require(store.store(Self.solidImage(.red), for: id))
        #expect(fileName == "\(id.uuidString).png")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Covers/\(fileName)").path
        ))
        #expect(await store.cover(named: fileName) != nil)
    }

    @Test("A cover read through a fresh store comes off disk, not the cache")
    func readsFromDisk() async throws {
        let (writer, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let fileName = try #require(writer.store(Self.solidImage(.blue), for: id))
        // A second store instance shares the directory but not the NSCache, so a
        // hit here proves the PNG actually reached disk.
        let reader = WallpaperCoverStore(directory: ConfigurationDirectory(root: root))
        #expect(await reader.cover(named: fileName) != nil)
    }

    @Test("Re-storing an entry overwrites its cover rather than leaving a second file")
    func reStoreOverwrites() throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        _ = store.store(Self.solidImage(.red), for: id)
        _ = store.store(Self.solidImage(.green, size: NSSize(width: 12, height: 9)), for: id)

        let covers = root.appendingPathComponent("Covers", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: covers.path)
        #expect(names == ["\(id.uuidString).png"])
    }

    @Test("Removing a cover deletes the file and drops the cached image")
    func removeDeletesFileAndCache() async throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let fileName = try #require(store.store(Self.solidImage(.red), for: id))
        #expect(await store.cover(named: fileName) != nil)

        store.remove(named: fileName)
        #expect(await store.cover(named: fileName) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Covers/\(fileName)").path
        ))
    }

    @Test("The orphan sweep keeps named covers and deletes the rest")
    func orphanSweep() throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let kept = UUID()
        let orphan = UUID()
        let keptName = try #require(store.store(Self.solidImage(.red), for: kept))
        let orphanName = try #require(store.store(Self.solidImage(.blue), for: orphan))

        store.removeOrphans(keeping: [keptName])

        let covers = root.appendingPathComponent("Covers", isDirectory: true)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: covers.path))
        #expect(names == [keptName])
        #expect(!names.contains(orphanName))
    }

    @Test("An empty keep-set clears every cover")
    func orphanSweepWithNothingLive() throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = store.store(Self.solidImage(.red), for: UUID())
        store.removeOrphans(keeping: [])

        let covers = root.appendingPathComponent("Covers", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: covers.path).isEmpty)
    }

    @Test("Sweeping a directory that was never written does not throw")
    func orphanSweepWithNoDirectory() async throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.removeOrphans(keeping: ["nothing.png"])
        #expect(await store.cover(named: "nothing.png") == nil)
    }

    @Test("Removing everything takes the directory with it")
    func removeAll() async throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = try #require(store.store(Self.solidImage(.red), for: UUID()))
        store.removeAll()
        #expect(await store.cover(named: fileName) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Covers").path
        ))
    }

    @Test func concurrentColdReadsPreserveImages() async throws {
        let (writer, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = try (0 ..< 50).map { _ in
            try #require(writer.store(Self.solidImage(.blue), for: UUID()))
        }
        let reader = WallpaperCoverStore(directory: ConfigurationDirectory(root: root))
        let tasks = names.map { name in Task { await reader.cover(named: name) } }
        for (name, task) in zip(names, tasks) {
            let expected = try #require(NSImage(contentsOf: root.appendingPathComponent("Covers/\(name)")))
            let actual = try #require(await task.value)
            #expect(actual.size == expected.size)
            #expect(abs(actual.size.width / actual.size.height - 8.0 / 6.0) < 0.0001)
        }
    }

    @Test func replacingCoverInvalidatesQueuedColdRead() async throws {
        let (writer, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let name = try #require(writer.store(Self.solidImage(.red), for: id))
        let gate = PreviewWorkGate(limit: 1)
        let reader = WallpaperCoverStore(directory: ConfigurationDirectory(root: root), readGate: gate)
        let blocker = CoverReadBlocker()
        let holder = Task { await gate.run { await blocker.wait() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.activeCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(await gate.activeCount == 1)
        let pending = Task { await reader.cover(named: name) }
        while await gate.queuedCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await gate.queuedCount == 1)
        _ = reader.store(Self.solidImage(.green, size: NSSize(width: 12, height: 9)), for: id)
        #expect(await pending.value?.size == NSSize(width: 12, height: 9))
        await blocker.open()
        await holder.value
        #expect(await reader.cover(named: name)?.size == NSSize(width: 12, height: 9))
        reader.remove(named: name)
        #expect(await reader.cover(named: name) == nil)
    }

    private actor CoverReadBlocker {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened {
                return
            }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }
}

@Suite("Saved library sort order")
struct SavedLibrarySortOrderTests {
    private struct Entry {
        let name: String
        let date: Date
        let type: WallpaperType
    }

    private static let entries = [
        Entry(name: "beta", date: Date(timeIntervalSince1970: 300), type: .html),
        Entry(name: "Alpha", date: Date(timeIntervalSince1970: 100), type: .video),
        Entry(name: "gamma", date: Date(timeIntervalSince1970: 200), type: .video),
    ]

    private func sorted(_ order: SavedLibrarySortOrder) -> [String] {
        order.sorted(Self.entries, name: \.name, date: \.date, type: \.type).map(\.name)
    }

    @Test("Recent is newest first")
    func recentIsNewestFirst() {
        #expect(sorted(.recent) == ["beta", "gamma", "Alpha"])
    }

    @Test("Name collates case-insensitively, the way Finder lists files")
    func nameUsesStandardCollation() {
        // `<` on String would put every capital ahead of every lowercase and
        // file "Alpha" after "gamma".
        #expect(sorted(.name) == ["Alpha", "beta", "gamma"])
    }

    @Test("Type groups by kind and orders by name inside a group")
    func typeGroupsThenNames() {
        let result = sorted(.type)
        let videoNames = result.filter { $0 == "Alpha" || $0 == "gamma" }
        #expect(videoNames == ["Alpha", "gamma"])
        let indices = result.enumerated().filter { videoNames.contains($0.element) }.map(\.offset)
        #expect(indices[1] - indices[0] == 1)
    }
}

@MainActor
@Suite("Wallpaper cover framing")
struct WallpaperCoverFramingTests {
    private static let canvas = NSRect(x: 0, y: 0, width: 1600, height: 900)
    private static let source = NSSize(width: 1200, height: 900)

    private func rect(_ mode: VideoFitMode, displayWidth: CGFloat = 3200) -> NSRect {
        WallpaperCoverCapture.placementRect(
            for: Self.source,
            in: Self.canvas,
            fitMode: mode,
            displayWidth: displayWidth
        )
    }

    @Test("Fill covers the canvas and overflows on the long axis")
    func fillCoversAndOverflows() {
        let r = rect(.aspectFill)
        #expect(r.width >= Self.canvas.width)
        #expect(r.height >= Self.canvas.height)
        #expect(r.midX == Self.canvas.midX)
        #expect(r.midY == Self.canvas.midY)
    }

    @Test("Fit letterboxes instead of cropping, the way the desktop shows it")
    func fitLetterboxes() {
        let r = rect(.aspectFit)
        // 4:3 inside 16:9 fits by height, leaving pillarboxes left and right.
        #expect(r.height == Self.canvas.height)
        #expect(r.width < Self.canvas.width)
        #expect(r.minX > Self.canvas.minX)
        #expect(abs(r.width / r.height - Self.source.width / Self.source.height) < 0.001)
    }

    @Test("Stretch fills the canvas exactly, aspect ratio and all")
    func stretchFillsExactly() {
        #expect(rect(.stretch) == Self.canvas)
    }

    @Test("Center scales by the canvas-to-display ratio, not by source pixels")
    func centerScalesToCanvas() {
        // The cover is half the display's width, so a centred source draws at half size;
        // pinning to source pixels would overflow.
        let r = rect(.center, displayWidth: 3200)
        #expect(r.width == Self.source.width / 2)
        #expect(r.height == Self.source.height / 2)
        #expect(r.midX == Self.canvas.midX)
    }

    @Test("A degenerate source falls back to the whole canvas rather than dividing by zero")
    func degenerateSourceFallsBack() {
        let r = WallpaperCoverCapture.placementRect(
            for: NSSize(width: 0, height: 0),
            in: Self.canvas,
            fitMode: .aspectFit,
            displayWidth: 3200
        )
        #expect(r == Self.canvas)
    }
}
