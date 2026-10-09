import AppKit
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing
import UniformTypeIdentifiers

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

    @Test("The decoded covers are dropped when the last window's image caches are reclaimed")
    func reclaimEmptiesTheDecodedCovers() async throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = try #require(store.store(Self.solidImage(.red), for: UUID()))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Covers/\(fileName)"))
        // Off disk, so only the decoded cache can still answer.
        #expect(await store.cover(named: fileName) != nil)

        LocalImageCacheRegistry.shared.purgeAll()
        #expect(await store.cover(named: fileName) == nil, "the cover cache is not registered with the reclaimer")
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

    @Test("A Workshop cover is named by its project and the import it shows; an ID that is not one file name gets none")
    func workshopCoverNames() {
        let importedAt = Date(timeIntervalSince1970: 1_727_000_000.123)
        #expect(
            WallpaperCoverStore.workshopFileName(workshopID: "3413921910", importedAt: importedAt)
                == "workshop-3413921910-1727000000123.jpg"
        )
        for unsafe in ["", ".", "..", "a/b", "a\\b"] {
            #expect(WallpaperCoverStore.workshopFileName(workshopID: unsafe, importedAt: importedAt) == nil, Comment(rawValue: unsafe))
        }
    }

    @Test("A Workshop cover is stored as a JPEG at most 1024 pixels wide and decodes straight to the size a card asks for")
    func workshopCoverIsASmallJPEG() async throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(
            data: nil, width: 2048, height: 1152, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1152))
        let frame = try #require(context.makeImage())
        let name = try #require(store.storeWorkshopCover(frame, workshopID: "7", importedAt: Date(timeIntervalSince1970: 0)))
        let source = try #require(CGImageSourceCreateWithURL(root.appendingPathComponent("Covers/\(name)") as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(properties?[kCGImagePropertyPixelHeight] as? Int == 576)
        let card = try #require(await store.cover(named: name, maxPixelSize: 256))
        #expect(card.width == 256 && card.height == 144, Comment(rawValue: "\(card.width)×\(card.height)"))
    }

    @Test("A cover's revision is new with every write of it, a cover already on disk has one, a removed one has none")
    func coverRevisions() throws {
        let (writer, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let frame = try #require(context.makeImage())
        let importedAt = Date(timeIntervalSince1970: 0)
        let name = try #require(writer.storeWorkshopCover(frame, workshopID: "7", importedAt: importedAt))
        #expect(writer.revision(of: name) != nil, "the store that wrote the cover has no revision for it")

        // A fresh store only has the directory to go by.
        let store = WallpaperCoverStore(directory: ConfigurationDirectory(root: root))
        var seen = try [#require(store.revision(of: name), "a cover already on disk has no revision")]
        #expect(store.revision(of: "workshop-8-0.jpg") == nil)
        for _ in 0 ..< 2 {
            _ = try #require(store.storeWorkshopCover(frame, workshopID: "7", importedAt: importedAt))
            let revision = try #require(store.revision(of: name))
            #expect(!seen.contains(revision), Comment(rawValue: "a rewrite kept revision \(revision), seen \(seen)"))
            seen.append(revision)
        }
        store.remove(named: name)
        #expect(store.revision(of: name) == nil, "a removed cover kept its revision")
        store.removeAll()
        _ = try #require(store.storeWorkshopCover(frame, workshopID: "7", importedAt: importedAt))
        let afterReset = try #require(store.revision(of: name))
        #expect(!seen.contains(afterReset), Comment(rawValue: "a cover written after a reset reused revision \(afterReset)"))
    }

    @Test("The sweep keeps every cover a bookmark, a scheme or a listed Workshop import names, and deletes the rest")
    func sweepKeepsEveryNamedCover() throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmarkCover = try #require(store.store(Self.solidImage(.red), for: UUID()))
        let schemeCover = try #require(store.store(Self.solidImage(.blue), for: UUID()))
        let orphan = try #require(store.store(Self.solidImage(.green), for: UUID()))
        let frame = try #require(Self.solidImage(.red).cgImage(forProposedRect: nil, context: nil, hints: nil))
        let origin = WPEOrigin(
            workshopID: "42", title: "Rain", originalType: .scene, sourceFolderBookmark: Data([1]),
            cacheRelativePath: nil, previewFileName: nil
        )
        let imported = WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 1_727_000_000))
        let current = try #require(store.storeWorkshopCover(frame, workshopID: "42", importedAt: imported.importedAt))
        let replaced = try #require(store.storeWorkshopCover(frame, workshopID: "42", importedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let bookmark = WallpaperBookmark(label: "Saved", content: .video(bookmarkData: Data([2])), coverFileName: bookmarkCover)
        let scheme = ScreenScheme(
            name: "Desk", configuration: ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([3]))),
            overlay: .default, coverFileName: schemeCover
        )

        store.removeOrphans(keeping: WallpaperCoverStore.keptFileNames(bookmarks: [bookmark], schemes: [scheme], workshopImports: [imported]))

        let names = try Set(FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Covers").path))
        #expect(names.contains(current), "the sweep deleted the cover of the Workshop import the library lists")
        #expect(names.isSuperset(of: [bookmarkCover, schemeCover]), "the sweep deleted a bookmark's or a scheme's cover")
        #expect(!names.contains(replaced) && !names.contains(orphan), Comment(rawValue: "the sweep kept covers nothing names: \(names)"))
    }

    @Test("The Edit Desk's library sweeps against the one keep-set")
    func librarySweepsWithOneKeepSet() throws {
        let model = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/SavedLibraryModel.swift")
        #expect(model.contains("inputs.savedCoverFileNames = { WallpaperCoverStore.keptFileNames() }"), "the Edit Desk's library sweeps against a set of its own")
        let sweeps = try RepositoryRoot.swiftFiles(under: "LiveWallpaper").flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .filter { $0.contains("removeOrphans(") && !$0.contains("func removeOrphans") }
                .map { "\(RepositoryRoot.relativePath(of: file)): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        let own = sweeps.filter { !$0.contains("removeOrphans(keeping: WallpaperCoverStore.keptFileNames())") && !$0.contains("removeOrphans(keeping: $0)") }
        #expect(own.isEmpty, Comment(rawValue: "sweeps with a keep-set of their own: \(own)"))
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
struct LibrarySortOrderTests {
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

    private func sorted(_ order: SavedLibraryModel.Sort) -> [String] {
        order.sorted(Self.entries, name: \.name, date: \.date, type: \.type).map(\.name)
    }

    @Test("Recent is newest first")
    func recentIsNewestFirst() {
        #expect(sorted(.recentlyUsed) == ["beta", "gamma", "Alpha"])
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
