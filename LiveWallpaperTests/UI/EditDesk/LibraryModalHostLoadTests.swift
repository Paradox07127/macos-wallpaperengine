#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Holds `ModalActions`' read of the project's manifest until the test lets it go.
@MainActor
private final class ManifestReadGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class NoBookmarks: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}

@MainActor
@Suite("Library modal host load")
struct LibraryModalHostLoadTests {
    @Test("An open modal ignores other library rows changing but reloads its own changed item")
    func unrelatedLibraryRefreshDoesNotReloadTheOpenItem() async throws {
        func entry(_ id: String, importedAt: Double = 1_727_000_000) -> WPEHistoryEntry {
            WPEHistoryEntry(origin: WPEOrigin(
                workshopID: id, title: "Scene \(id)", originalType: .scene,
                sourceFolderBookmark: Data([4]), cacheRelativePath: nil, previewFileName: nil
            ), importedAt: Date(timeIntervalSince1970: importedAt))
        }
        var entries = [entry("100")]
        var source = SavedLibraryModel.Inputs()
        source.history = { entries }
        let library = SavedLibraryModel(inputs: source)
        let item = try #require(library.items.first)
        var reads = 0
        var inputs = ModalActions.Inputs()
        inputs.item = { id in library.items.first { $0.id == id } }
        inputs.localInfo = { _ in reads += 1; return nil }
        let actions = ModalActions(
            inputs: inputs, bookmarks: BookmarkStore(persistence: NoBookmarks()), thumbnails: ShelfThumbnailCache(),
            apply: { _, _ in }, applyToAll: { _, _ in }
        )
        let stage = EditDeskStageModel()
        let modal = LibraryModalHost(
            library: library, stage: stage, drag: LibraryDragController(), actions: actions,
            requestRename: { _ in }, requestDelete: { _ in }, presentedItemID: .constant(item.id), showDisplay: { _ in }
        )
        var observedItems: [LiveWallpaper.LibraryItem] = []
        let host = NSHostingView(rootView: LibraryModalRefreshObservation(modal: modal, library: library) {
            observedItems = $0
        })
        host.sizingOptions = []
        let window = ParkedTestWindow(
            contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        @MainActor func settle(until ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !ready(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle { reads > 0 && observedItems == library.items }
        try #require(reads == 1, "the modal did not complete its initial load exactly once")
        entries.append(entry("200"))
        library.refresh()
        try await settle { observedItems == library.items }
        try #require(observedItems.count == 2, "the hosted view never observed the added row")
        try await Task.sleep(for: .milliseconds(200))
        #expect(reads == 1, "another row caused the displayed item's manifest to be read again")

        entries[1] = entry("200", importedAt: 1_727_000_001)
        library.refresh()
        try await settle { observedItems == library.items }
        try #require(observedItems == library.items, "the hosted view never observed the other item's update")
        try await Task.sleep(for: .milliseconds(200))
        #expect(reads == 1, "another row's update reloaded the open item")
        entries[0] = entry("100", importedAt: 1_727_000_002)
        library.refresh()
        try await settle { reads > 1 }
        #expect(reads == 2, "the open item's own update did not reload its manifest once")
    }

    private static func solid(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1024, height: 576, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 576))
        return try #require(context.makeImage())
    }

    /// Pixels of `view` that read clearly green and clearly magenta.
    private static func hues(in view: NSView) throws -> (green: Int, magenta: Int) {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var green = 0
        var magenta = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
            if g - max(r, b) > 100 {
                green += 1
            } else if min(r, b) - g > 100 {
                magenta += 1
            }
        }
        return (green, magenta)
    }

    @Test("A cover that lands on the item's display while the modal reads the project does not become the item's picture", .timeLimit(.minutes(1)))
    func aCoverLandingDuringTheLoadStaysOut() async throws {
        let display: CGDirectDisplayID = 7
        let origin = WPEOrigin(
            workshopID: "3413921910", title: "Meteors", originalType: .scene, sourceFolderBookmark: Data([4]),
            cacheRelativePath: nil, previewFileName: nil
        )
        var libraryInputs = SavedLibraryModel.Inputs()
        libraryInputs.history = { [WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 1_727_000_000))] }
        libraryInputs.nowPlaying = { _, entry in entry == nil ? [] : [display] }
        let library = SavedLibraryModel(inputs: libraryInputs)
        let item = try #require(library.items.first)
        try #require(item.onDisplays == [display])

        let gate = ManifestReadGate()
        defer { gate.open() }
        var inputs = ModalActions.Inputs()
        inputs.item = { id in library.items.first { $0.id == id } }
        inputs.localInfo = { _ in
            await gate.wait()
            return nil
        }
        let actions = ModalActions(
            inputs: inputs, bookmarks: BookmarkStore(persistence: NoBookmarks()), thumbnails: ShelfThumbnailCache(),
            apply: { _, _ in }, applyToAll: { _, _ in }
        )
        let shown = try Self.solid(red: 0, green: 1, blue: 0)
        let landed = try Self.solid(red: 1, green: 0, blue: 1)
        let stage = EditDeskStageModel()
        stage.displays = [StageDisplay(
            id: display, fingerprint: "modal-load", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false,
            name: "Studio", badgeText: "", statusText: "", cover: shown, state: .ok
        )]
        let host = LibraryModalHost(
            library: library, stage: stage, drag: LibraryDragController(), actions: actions,
            requestRename: { _ in }, requestDelete: { _ in }, presentedItemID: .constant(item.id), currentCovers: [display],
            showDisplay: { _ in }
        )
        let hosting = NSHostingView(rootView: host.tint(.gray))
        hosting.sizingOptions = []
        let window = ParkedTestWindow(
            contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setContentSize(StageGeometry.designWindow)
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gate.entered, "the modal never read the project")
        stage.displays[0].cover = landed
        gate.open()
        var drawn = try Self.hues(in: hosting)
        while drawn.green + drawn.magenta < 20000, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            drawn = try Self.hues(in: hosting)
        }
        #expect(drawn.green > 20000, Comment(rawValue: "control: the modal drew no picture of the item's display (\(drawn))"))
        #expect(drawn.magenta < 100, Comment(rawValue: "the modal drew the cover that landed during its load (\(drawn))"))
    }
}

private struct LibraryModalRefreshObservation: View {
    let modal: LibraryModalHost
    let library: SavedLibraryModel
    let onUpdate: ([LiveWallpaper.LibraryItem]) -> Void

    var body: some View {
        modal.onChange(of: library.items, initial: true) { _, items in onUpdate(items) }
    }
}
#endif
