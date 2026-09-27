#if !LITE_BUILD
import AppKit
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing
import UniformTypeIdentifiers

// `ProbeImage`, `ProbeColor` and `ProbeRenderer` come from `EditDeskFidelityProbeTests.swift`, compiled for Pro only.

/// A titled window is pulled onto a real display when it is ordered in; this one has to stay off screen.
private final class GridPreviewWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}

/// AppKit traps when a bare `NSScreen()` is asked these.
private final class GridPreviewScreen: NSScreen {
    static let id: CGDirectDisplayID = 0x6D1D_0C01

    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): Self.id]
    }

    override var localizedName: String {
        "Grid Preview"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}

/// Which frame of the test GIF a sample shows: cyan is its first frame, the poster. Judged by hue, so it
/// still reads through the dimming a dragged tile takes.
private enum FrameHue: Equatable {
    /// `blue` is none of the GIF's frames: the saved cover a Workshop tile draws.
    case cyan, yellow, magenta, blue, other

    init(_ color: ProbeColor) {
        let margin = 25
        let (r, g, b) = (color.r, color.g, color.b)
        if g - r > margin, b - r > margin, abs(g - b) < margin {
            self = .cyan
        } else if r - b > margin, g - b > margin, abs(r - g) < margin {
            self = .yellow
        } else if r - g > margin, b - g > margin, abs(r - b) < margin {
            self = .magenta
        } else if b - r > margin, b - g > margin {
            self = .blue
        } else {
            self = .other
        }
    }

    var isPastPoster: Bool {
        self == .yellow || self == .magenta
    }
}

/// Scene folders on disk, bookmarked the way an import leaves them. Two preview GIFs whose frames run
/// cyan → yellow → magenta, and a still PNG preview in the GIFs' first colour.
@MainActor
private struct GridPreviewScenes {
    enum Row: CaseIterable {
        case gif, otherGIF, still
    }

    /// Workshop projects with a preview GIF like `.gif`'s; a host lists them only when asked to.
    enum Project: CaseIterable {
        case covered, plain
    }

    static let frames = [ProbeRenderer.hudCyan, ProbeRenderer.inspectorYellow, ProbeRenderer.heroMagenta]

    let root: URL
    let bookmarks: [Row: WallpaperBookmark]
    let projects: [Project: WPEHistoryEntry]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grid-preview-\(UUID().uuidString)", isDirectory: true)
        var bookmarks: [Row: WallpaperBookmark] = [:]
        for row in Row.allCases {
            let folder = root.appendingPathComponent("\(row)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = row == .still ? "preview.png" : "preview.gif"
            let colors = row == .still ? [Self.frames[0]] : Self.frames
            try Self.encode(colors, as: row == .still ? .png : .gif, to: folder.appendingPathComponent(file))
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let workshopID = "grid-preview-\(row)-\(UUID().uuidString)"
            let origin = WPEOrigin(
                workshopID: workshopID, title: "\(row)", originalType: .scene, sourceFolderBookmark: bookmark,
                cacheRelativePath: nil, previewFileName: file
            )
            let scene = SceneDescriptor(workshopID: workshopID, cacheRelativePath: workshopID, entryFile: "scene.json", capabilityTier: .imageOnly)
            bookmarks[row] = WallpaperBookmark(label: "\(row)", content: .scene(scene), wpeOrigin: origin)
        }
        self.bookmarks = bookmarks
        var projects: [Project: WPEHistoryEntry] = [:]
        for project in Project.allCases {
            let folder = root.appendingPathComponent("\(project)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.encode(Self.frames, as: .gif, to: folder.appendingPathComponent("preview.gif"))
            let origin = try WPEOrigin(
                workshopID: "grid-preview-\(project)-\(UUID().uuidString)", title: "\(project)", originalType: .scene,
                sourceFolderBookmark: folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                cacheRelativePath: nil, previewFileName: "preview.gif"
            )
            projects[project] = WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 0))
        }
        self.projects = projects
    }

    private static func encode(_ colors: [NSColor], as type: UTType, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, colors.count, nil))
        if type == .gif {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for color in colors {
            let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(destination, ProbeRenderer.solid(color, size: CGSize(width: 160, height: 90)), type == .gif ? frame : nil)
        }
        try #require(CGImageDestinationFinalize(destination))
    }
}

/// The real `HomePage` opened on the library over one display, in the Edit Desk window's chrome, ordered in off
/// screen so synthesized mouse events reach SwiftUI's gestures. SwiftUI's hover cannot be synthesized here, so a
/// test settles the pointer on a tile through the page's `LibraryGridPreview`, where the tile's `settledHover` reports.
@MainActor
private final class GridPreviewHost {
    static let size = CGSize(width: 1280, height: 820)
    static let midWindow = CGPoint(x: 640, y: 420)
    /// The strip's thumbnails are centred in its panel under the window's top.
    static let stripRow = FloatLayerGeometry.panelTop + FloatLayerGeometry.panelHeight / 2

    struct Tile {
        let id: String
        let center: CGPoint
        /// Above the tile's bottom gradient and title, where it shows its picture alone.
        let sample: CGPoint
        /// The tile's own long edge in backing pixels.
        let pixelSize: Int
    }

    let window: NSWindow
    let host: NSView
    let manager: ScreenManager
    let library: SavedLibraryModel
    let preview = LibraryGridPreview()
    private let scenes: GridPreviewScenes
    /// The covered project's cover in the shared store, which the page's own thumbnail cache reads.
    private var savedCover: String?
    /// Settings → hover to play preview, as the page reads it.
    var autoplay = true
    /// Every frame load the grid asked for, by its long edge in pixels.
    private(set) var loads: [Int] = []

    /// `listsProjects`: the library also lists the Workshop projects, `.covered` with a blue saved cover.
    init(listsProjects: Bool = false) throws {
        scenes = try GridPreviewScenes()
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [Screen(nsScreen: GridPreviewScreen())]),
            featureCatalog: .unconfigured
        ))
        let bookmarks = scenes.bookmarks
        let rows = GridPreviewScenes.Row.allCases.compactMap { bookmarks[$0] }
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { rows }
        if listsProjects {
            let entries = scenes.projects
            let projects = GridPreviewScenes.Project.allCases.compactMap { entries[$0] }
            let covered = try #require(entries[.covered])
            savedCover = try #require(WallpaperCoverStore.shared.storeWorkshopCover(
                ProbeRenderer.solid(ProbeRenderer.thumbnailBlue, size: CGSize(width: 1024, height: 576)),
                workshopID: covered.origin.workshopID, importedAt: covered.importedAt
            ))
            inputs.history = { projects }
            inputs.workshopCoverRevision = { entry in
                WallpaperCoverStore.workshopFileName(workshopID: entry.origin.workshopID, importedAt: entry.importedAt)
                    .flatMap { WallpaperCoverStore.shared.revision(of: $0) }
            }
        }
        library = SavedLibraryModel(inputs: inputs)
        let router = EditDeskRouter(initialNavigation: .bookmarks, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let page = HomePage(router: router, toasts: EditDeskToastCenter(), library: library, gridPreview: preview)
        let hosting = NSHostingView(rootView: page.environment(manager))
        hosting.sizingOptions = []
        window = GridPreviewWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "GridPreviewToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(Self.size)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        window.makeKey()
        host = hosting
        preview.autoplayEnabled = { [weak self] in self?.autoplay ?? true }
        preview.load = { [weak self] origin, maxPixelSize in
            self?.loads.append(maxPixelSize)
            return await ShelfPreviewFrames.load(origin, maxPixelSize: maxPixelSize)
        }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        manager.tearDownForTermination()
        try? FileManager.default.removeItem(at: scenes.root)
        if let savedCover {
            WallpaperCoverStore.shared.remove(named: savedCover)
        }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    var stage: EditDeskStageView? {
        Self.views(host).lazy.compactMap { $0 as? EditDeskStageView }.first
    }

    /// The library grid's scroll view: the only one as wide as the window.
    private var grid: NSScrollView? {
        Self.views(host).lazy.compactMap { $0 as? NSScrollView }
            .first { $0.window != nil && $0.convert($0.bounds, to: nil).width > window.frame.width * 0.9 }
    }

    /// Polls until `condition` holds or `seconds` pass; returns whether it held.
    @discardableResult
    func settle(seconds: Double = 2, until condition: () -> Bool = { false }) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Landed on the library with the grid mounted, every tile's picture drawn and the display's cover red.
    func settleOnLibrary() async throws {
        await settle(seconds: 3) { stage?.model.progress == 2 && stage?.model.snappedIndex == 2 && grid != nil }
        let model = try #require(stage?.model)
        let landed = model.snappedIndex == 2
        try #require(landed, "the page never landed on the library")
        let mounted = grid != nil
        try #require(mounted, "the library grid never mounted")
        let drawn = await settle(seconds: 3) {
            GridPreviewScenes.Row.allCases.allSatisfy { (try? hue(at: tile($0).sample)) == .cyan }
        }
        try #require(drawn, "the tiles never drew their previews' first frame")
        let found = model.displays.firstIndex { $0.id == GridPreviewScreen.id }
        let index = try #require(found, "the stage has no display")
        model.displays[index].cover = ProbeRenderer.solid(ProbeRenderer.previewRed, size: CGSize(width: 192, height: 108))
    }

    func tile(_ row: GridPreviewScenes.Row) throws -> Tile {
        let bookmark = try #require(scenes.bookmarks[row])
        return try tile(id: "bookmark:\(bookmark.id)")
    }

    func tile(_ project: GridPreviewScenes.Project) throws -> Tile {
        let entry = try #require(scenes.projects[project])
        return try tile(id: "workshop:\(entry.id)")
    }

    private func tile(id: String) throws -> Tile {
        let model = try #require(stage?.model)
        let found = library.visibleItems.firstIndex { $0.id == id }
        let index = try #require(found, "no tile for \(id)")
        let item = library.visibleItems[index]
        let frame = StageGeometry.gridFrame(index: index, windowWidth: Self.size.width, size: model.gridTileSize)
        let thumbnail = try #require(HomePage.gridThumbnail(
            for: item, stageWidth: model.stageSize.width, size: model.gridTileSize, scale: NSScreen.main?.backingScaleFactor ?? 2
        ))
        return Tile(
            id: item.id, center: CGPoint(x: frame.midX, y: frame.midY),
            sample: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.3),
            pixelSize: Int(max(thumbnail.pixelSize.width, thumbnail.pixelSize.height))
        )
    }

    /// The SwiftUI layers alone: the stage's own layers are hidden for the capture.
    func render(_ rect: CGRect? = nil) throws -> ProbeImage {
        let stageView = stage
        stageView?.isHidden = true
        defer { stageView?.isHidden = false }
        host.layoutSubtreeIfNeeded()
        let area = rect ?? host.bounds
        let rep = host.bitmapImageRepForCachingDisplay(in: area)
        let bitmap = try #require(rep)
        host.cacheDisplay(in: area, to: bitmap)
        let image = bitmap.cgImage
        return try ProbeImage(cgImage: #require(image), viewWidth: area.width)
    }

    func hue(at point: CGPoint) throws -> FrameHue {
        let image = try render(CGRect(x: point.x.rounded(.down) - 2, y: point.y.rounded(.down) - 2, width: 4, height: 4))
        return FrameHue(image.rgb(px: image.width / 2, image.height / 2))
    }

    /// What `point` shows over `seconds`, sampled as fast as the captures allow.
    func hues(at point: CGPoint, for seconds: Double) async -> [FrameHue] {
        var seen: [FrameHue] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let hue = try? hue(at: point) {
                seen.append(hue)
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return seen
    }

    /// `point` shows a frame past the GIF's first within `seconds`.
    func plays(at point: CGPoint, within seconds: Double = 2) async -> Bool {
        await settle(seconds: seconds) { (try? hue(at: point))?.isPastPoster == true }
    }

    /// The display's red cover sits on the strip's row.
    var stripShows: Bool {
        guard let image = try? render() else { return false }
        return !image.runs(inRow: Self.stripRow) { $0.isRed }.filter { $0.width >= 40 }.isEmpty
    }

    /// The stage stays locked while the detail is open.
    var detailOpen: Bool {
        stage?.model.interactionBlocked == true
    }

    func click(_ point: CGPoint) async {
        await press(point)
        await release(point)
    }

    func press(_ point: CGPoint) async {
        await send(.leftMouseDown, point)
    }

    func drag(through points: [CGPoint]) async {
        for point in points {
            await send(.leftMouseDragged, point)
        }
    }

    func release(_ point: CGPoint) async {
        await send(.leftMouseUp, point)
    }

    /// `point` has a top-left origin; window coordinates start bottom-left.
    private func send(_ type: NSEvent.EventType, _ point: CGPoint) async {
        guard let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: Self.size.height - point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else {
            Issue.record("could not build a \(type) event")
            return
        }
        window.sendEvent(event)
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private extension CGPoint {
    func moved(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

/// Hover to play on the library grid, by the shelf's rule. Results are bound before `#expect`: a failing expectation
/// reflects every value in its expression, and reflecting the host's AppKit views traps.
@Suite("Library grid GIF preview in a window", .serialized)
@MainActor
struct LibraryGridPreviewTests {
    enum Control: String, CaseIterable, Sendable {
        case settingOff, reduceMotion, stillPreview
    }

    @Test("A tile's hover report moves the settled tile; a late exit from a tile the pointer already left changes nothing")
    func settledTileFollowsHoverReports() {
        let preview = LibraryGridPreview()
        preview.settle("a", hovering: true)
        #expect(preview.settledID == "a")
        preview.settle("b", hovering: true)
        #expect(preview.settledID == "b")
        preview.settle("a", hovering: false)
        #expect(preview.settledID == "b", "a stale exit cleared the tile now under the pointer")
        preview.settle("b", hovering: false)
        #expect(preview.settledID == nil)
    }

    @Test("A settled GIF tile plays at its own pixel size; settling on another moves the preview there; leaving stops it", .timeLimit(.minutes(1)))
    func settledTilePlaysItsGIF() async throws {
        let host = try GridPreviewHost()
        defer { host.close() }
        try await host.settleOnLibrary()
        let gif = try host.tile(.gif)
        let other = try host.tile(.otherGIF)
        let before = await host.hues(at: gif.sample, for: 0.4)
        let stillBefore = !before.isEmpty && before.allSatisfy { $0 == .cyan }
        #expect(stillBefore, Comment(rawValue: "control: with no tile settled the GIF tile showed \(before)"))

        host.preview.settledID = gif.id
        let played = await host.plays(at: gif.sample)
        #expect(played, "the settled GIF tile never played")
        let sizes = host.loads
        #expect(sizes == [gif.pixelSize], Comment(rawValue: "frames asked for at \(sizes), the tile is \(gif.pixelSize) px"))

        host.preview.settledID = other.id
        let moved = await host.plays(at: other.sample)
        #expect(moved, "the next settled tile never played")
        let first = await host.hues(at: gif.sample, for: 0.5)
        let firstStill = !first.isEmpty && first.allSatisfy { $0 == .cyan }
        #expect(firstStill, Comment(rawValue: "two tiles played at once; the first showed \(first)"))

        host.preview.settledID = nil
        let back = await host.settle(seconds: 1) { (try? host.hue(at: other.sample)) == .cyan }
        let after = await host.hues(at: other.sample, for: 0.5)
        let stopped = back && !after.isEmpty && after.allSatisfy { $0 == .cyan }
        #expect(stopped, Comment(rawValue: "after the pointer left, the tile showed \(after)"))
    }

    @Test("No tile plays with the setting off, under Reduce Motion or on a still preview; undoing the control plays", .timeLimit(.minutes(1)), arguments: Control.allCases)
    func previewStaysStill(_ control: Control) async throws {
        let host = try GridPreviewHost()
        defer { host.close() }
        try await host.settleOnLibrary()
        let gif = try host.tile(.gif)
        let target = try control == .stillPreview ? host.tile(.still) : gif
        switch control {
        case .settingOff: host.autoplay = false
        case .reduceMotion: host.preview.reduceMotion = true
        case .stillPreview: break
        }
        host.preview.settledID = target.id
        let seen = await host.hues(at: target.sample, for: 0.6)
        let still = !seen.isEmpty && seen.allSatisfy { $0 == .cyan }
        #expect(still, Comment(rawValue: "\(control): the tile showed \(seen)"))
        let loads = host.loads.count
        #expect(loads == 0, Comment(rawValue: "\(control) still decoded the preview"))

        // Undone, the same page plays the GIF: the stillness above is the control's doing, not the harness's.
        host.autoplay = true
        host.preview.reduceMotion = false
        host.preview.settledID = nil
        await host.settle(seconds: 0.1)
        host.preview.settledID = gif.id
        let played = await host.plays(at: gif.sample)
        #expect(played, Comment(rawValue: "\(control) undone, the GIF tile still never played"))
    }

    @Test("A playing tile still drags out the display strip and holds its poster while dragged; a click still opens its detail", .timeLimit(.minutes(1)))
    func playingTileStillDragsAndClicks() async throws {
        let host = try GridPreviewHost()
        defer { host.close() }
        try await host.settleOnLibrary()
        let gif = try host.tile(.gif)
        let stripBefore = host.stripShows
        #expect(!stripBefore, "control: the display's cover already sits where the strip rides")
        host.preview.settledID = gif.id
        let played = await host.plays(at: gif.sample)
        try #require(played, "the settled GIF tile never played")

        await host.press(gif.center)
        await host.drag(through: [gif.center.moved(3, 0), gif.center.moved(20, -10), GridPreviewHost.midWindow])
        let stripShows = await host.settle { host.stripShows }
        #expect(stripShows, "dragging a playing tile never brought the display strip in")
        let dragged = await host.hues(at: gif.sample, for: 0.6)
        let heldPoster = !dragged.isEmpty && dragged.allSatisfy { $0 == .cyan }
        #expect(heldPoster, Comment(rawValue: "the dragged tile kept playing: \(dragged)"))
        await host.release(GridPreviewHost.midWindow)
        let stripGone = await host.settle { !host.stripShows }
        #expect(stripGone, "the strip stayed up after the release")
        let opened = host.detailOpen
        #expect(!opened, "the drag also counted as a click and opened the detail")

        let playsAgain = await host.plays(at: gif.sample)
        #expect(playsAgain, "the tile never played again after the drag, so the click below does not start on a playing tile")
        await host.click(gif.center)
        let clickOpens = await host.settle { host.detailOpen }
        #expect(clickOpens, "a click on a playing tile no longer opens its detail")
        let covered = host.preview.covered
        #expect(covered, "the detail over the grid leaves the preview free to play")
    }

    @Test("A Workshop tile showing its saved cover plays its scene's GIF on a settled hover, as its shelf card does; leaving puts the cover back", .timeLimit(.minutes(1)))
    func savedCoverTilePlaysItsSceneGIF() async throws {
        let host = try GridPreviewHost(listsProjects: true)
        defer { host.close() }
        try await host.settleOnLibrary()
        let covered = try host.tile(.covered)
        let plain = try host.tile(.plain)
        let drawn = await host.settle(seconds: 3) {
            (try? host.hue(at: covered.sample)) == .blue && (try? host.hue(at: plain.sample)) == .cyan
        }
        let coveredHue = try? host.hue(at: covered.sample)
        #expect(drawn, Comment(rawValue: "the covered tile shows \(String(describing: coveredHue)), not its saved cover, or the plain one lacks its GIF's first frame"))
        let cards = host.stage?.model.shelfItems ?? []
        let coveredCardNamesGIF = cards.first { $0.id == covered.id }?.previewOrigin != nil
        #expect(coveredCardNamesGIF, "the covered project's shelf card names no GIF to play over its cover")

        host.preview.settledID = covered.id
        let played = await host.plays(at: covered.sample)
        #expect(played, "the settled covered tile never played its scene's GIF")
        let sizes = host.loads
        #expect(sizes == [covered.pixelSize], Comment(rawValue: "frames asked for at \(sizes), the tile is \(covered.pixelSize) px"))

        host.preview.settledID = nil
        let back = await host.settle(seconds: 1) { (try? host.hue(at: covered.sample)) == .blue }
        let after = await host.hues(at: covered.sample, for: 0.5)
        let onCover = back && !after.isEmpty && after.allSatisfy { $0 == .blue }
        #expect(onCover, Comment(rawValue: "after the pointer left, the covered tile showed \(after), not its saved cover"))
    }

    @Test("A settled tile searched out of the grid forgets the pointer: searched back in, it stays on its poster", .timeLimit(.minutes(1)))
    func searchedOutTileForgetsItsHover() async throws {
        let host = try GridPreviewHost()
        defer { host.close() }
        try await host.settleOnLibrary()
        let gif = try host.tile(.gif)
        let other = try host.tile(.otherGIF)
        host.preview.settledID = gif.id
        let played = await host.plays(at: gif.sample)
        try #require(played, "control: the settled GIF tile never played")

        host.library.query = "still"
        let forgot = await host.settle { host.preview.settledID == nil }
        #expect(forgot, "the tile searched out from under the pointer is still the settled one")

        host.library.query = ""
        let back = await host.settle(seconds: 3) {
            (try? host.hue(at: other.sample)) == .cyan && (try? host.hue(at: gif.sample)) == .cyan
        }
        try #require(back, "the searched-back grid never drew its tiles again")
        let seen = await host.hues(at: gif.sample, for: 0.6)
        let still = !seen.isEmpty && seen.allSatisfy { $0 == .cyan }
        #expect(still, Comment(rawValue: "searched back in with the pointer elsewhere, the tile showed \(seen)"))
    }
}
#endif
