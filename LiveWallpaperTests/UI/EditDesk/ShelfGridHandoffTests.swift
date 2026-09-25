#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

// `ProbeImage`, `ProbeColor` and `ProbeRenderer` come from `EditDeskFidelityProbeTests.swift`, compiled for Pro only.

/// A titled window is pulled onto a real display when it is ordered in, which also caps its height at that display's.
private final class HandoffWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The library banner names a display the manager knows; AppKit traps when a bare `NSScreen()` is asked these.
private final class HandoffScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xED0C_0002)]
    }

    override var localizedName: String {
        "Handoff Display"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}

/// The real `HomePage` opened on the library, in the Edit Desk window's chrome (full-size content,
/// transparent title bar, unified toolbar). Every row has a solid blue cover in the test process's
/// throwaway cover store, so the grid's tiles can be found by colour in a render.
@MainActor
private struct HandoffHost {
    let window: NSWindow
    let host: NSView
    let manager: ScreenManager
    let router: EditDeskRouter
    let library: SavedLibraryModel
    let suiteName: String?

    /// `onLibrary` false opens on the overview instead; `backdrop` paints behind the page.
    init(
        size: CGSize, count: Int = 60, onboarding: Bool = false, target: Bool = false, onLibrary: Bool = true,
        backdrop: NSColor? = nil
    ) throws {
        let screen = Screen(nsScreen: HandoffScreen())
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: target ? [screen] : []),
            featureCatalog: .unconfigured
        ))
        let blue = NSImage(
            cgImage: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue, size: CGSize(width: 1600, height: 900)),
            size: NSSize(width: 1600, height: 900)
        )
        let rows = (0 ..< count).map { index -> WallpaperBookmark in
            let id = UUID()
            return WallpaperBookmark(
                label: "Handoff \(index)", content: .video(bookmarkData: Data([UInt8(index % 250), 7, 7])), id: id,
                coverFileName: WallpaperCoverStore.shared.store(blue, for: id)
            )
        }
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { rows }
        router = EditDeskRouter(
            initialNavigation: onLibrary ? .bookmarks : nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false }
        )
        if target {
            router.libraryTarget = screen.id
        }
        library = SavedLibraryModel(inputs: inputs)
        var root = AnyView(HomePage(router: router, toasts: EditDeskToastCenter(), library: library).environment(manager))
        if let backdrop {
            root = AnyView(root.background(Color(nsColor: backdrop).ignoresSafeArea()))
        }
        if onboarding {
            let name = "handoff.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            root = AnyView(root.environment(OnboardingProgress(defaults: defaults, legacyDefaults: defaults, workshopAvailable: false)))
            suiteName = name
        } else {
            suiteName = nil
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window = HandoffWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "HandoffToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        host = hosting
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        manager.tearDownForTermination()
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    var stage: EditDeskStageView? {
        Self.views(host).lazy.compactMap { $0 as? EditDeskStageView }.first
    }

    /// Every image the page's layers draw, with its pixel size, the stage's own left out. SwiftUI hands an `Image`'s
    /// `CGImage` to a layer as its contents, the very object, so a picture on screen can be matched by identity.
    func pictures(excluding stage: EditDeskStageView) -> [ObjectIdentifier: CGSize] {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var found: [ObjectIdentifier: CGSize] = [:]
        func walk(_ layer: CALayer) {
            guard layer !== stage.layer else { return }
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = unsafeDowncast(contents as AnyObject, to: CGImage.self)
                found[ObjectIdentifier(image)] = CGSize(width: image.width, height: image.height)
            }
            layer.sublayers?.forEach(walk)
        }
        host.layer.map(walk)
        return found
    }

    /// The library grid's scroll view: the only one as wide as the window.
    var grid: NSScrollView? {
        Self.views(host).lazy.compactMap { $0 as? NSScrollView }
            .first { $0.window != nil && $0.convert($0.bounds, to: nil).width > window.frame.width * 0.9 }
    }

    /// The grid scroll view's frame in the host's top-left coordinates.
    func gridFrame(_ scroll: NSScrollView) -> CGRect {
        let frame = scroll.convert(scroll.bounds, to: host)
        return host.isFlipped ? frame : CGRect(
            x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height
        )
    }

    func settle(seconds: Double, until condition: () -> Bool = { false }) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Landed on the library with the grid mounted, its fade finished and its tiles decoded.
    func settleOnLibrary() async throws {
        await settle(seconds: 3) { stage?.model.progress == 2 && stage?.model.snappedIndex == 2 && grid != nil }
        await settle(seconds: 0.8)
        try #require(stage?.model.snappedIndex == 2, "the page never landed on the library")
        try #require(grid != nil, "the library grid never mounted")
    }

    /// The SwiftUI layers alone: the stage's CALayers are hidden for the capture.
    func renderWithoutStage() throws -> ProbeImage {
        let stageView = stage
        stageView?.isHidden = true
        defer { stageView?.isHidden = false }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try ProbeImage(cgImage: #require(bitmap.cgImage), viewWidth: host.bounds.width)
    }

    /// What AppKit does with a scroll: the stage's local monitor sees it first, and whatever it lets
    /// through goes to the view under the pointer.
    func route(_ event: NSEvent, at point: CGPoint) {
        guard let stage, let passed = stage.forwardGridScroll(event) else { return }
        host.hitTest(host.convert(point, to: host.superview))?.scrollWheel(with: passed)
    }

    /// The view a click at `point` (host coordinates) would reach.
    func hitView(at point: CGPoint) -> NSView? {
        host.hitTest(host.convert(point, to: host.superview))
    }
}

/// One tile found in a render, in host coordinates. `row` counts the rows found, top first.
private struct FoundTile {
    var rect: CGRect
    var row: Int
    var column: Int
    /// Cut by the scroll view's top or bottom edge, so its rect is not the tile's.
    var clipped: Bool
}

@MainActor
private enum TileFinder {
    /// The cover is pure blue; the tile's gradient only darkens it and its 1pt rims only tint it.
    static func isBlue(_ color: ProbeColor) -> Bool {
        color.b >= 100 && color.r < 110 && color.g < 110 && color.b - max(color.r, color.g) >= 60
    }

    /// Runs of matching samples in points; gaps up to `bridge` close (the 1pt inner ring is not blue),
    /// runs shorter than `minimum` drop.
    private static func runs(
        count: Int, scale: CGFloat, from start: CGFloat, to end: CGFloat, bridge: CGFloat = 4, minimum: CGFloat = 30,
        _ matches: (Int) -> Bool
    ) -> [ClosedRange<CGFloat>] {
        let first = max(0, Int((start * scale).rounded(.down)))
        let last = min(count, Int((end * scale).rounded(.up)))
        var found: [ClosedRange<CGFloat>] = []
        var open: Int?
        var lastHit = -1
        for index in first ..< max(first, last) where matches(index) {
            if let start = open, CGFloat(index - lastHit - 1) / scale > bridge {
                found.append(CGFloat(start) / scale ... CGFloat(lastHit + 1) / scale)
                open = index
            } else if open == nil {
                open = index
            }
            lastHit = index
        }
        if let start = open {
            found.append(CGFloat(start) / scale ... CGFloat(lastHit + 1) / scale)
        }
        return found.filter { $0.upperBound - $0.lowerBound >= minimum }
    }

    /// Rows from a column scan through the first column, columns from a row scan through each row's
    /// upper quarter, then each tile's edges where it differs from the page: its rims and ring are
    /// tinted off blue, and the shadow outside stays within a few levels of the page.
    static func tiles(in image: ProbeImage, scroll: CGRect, columnWidth: CGFloat) -> [FoundTile] {
        let scale = image.scale
        let page = image.rgb(px: Int(8 * scale), Int((scroll.minY + 7) * scale))
        func isOffPage(_ color: ProbeColor) -> Bool {
            color.r >= 0 && max(abs(color.r - page.r), abs(color.g - page.g), abs(color.b - page.b)) > 12
        }
        let probeX = Int(((DesignTokens.LibraryGrid.horizontalPadding + columnWidth / 2) * scale).rounded(.down))
        let rows = runs(count: image.height, scale: scale, from: scroll.minY, to: scroll.maxY) { isBlue(image.rgb(px: probeX, $0)) }
        var found: [FoundTile] = []
        var rowIndex = 0
        for row in rows {
            let py = Int(((row.lowerBound + (row.upperBound - row.lowerBound) * 0.25) * scale).rounded(.down))
            let columns = runs(count: image.width, scale: scale, from: 0, to: scroll.maxX) { isBlue(image.rgb(px: $0, py)) }
            // Anything else in the scroll view spans far wider than a column.
            guard let widest = columns.map({ $0.upperBound - $0.lowerBound }).max(), widest < columnWidth * 1.4 else { continue }
            for (column, span) in columns.enumerated() {
                let cx = Int((((span.lowerBound + span.upperBound) / 2) * scale).rounded(.down))
                let down = runs(count: image.height, scale: scale, from: max(scroll.minY, row.lowerBound - 12), to: min(scroll.maxY, row.upperBound + 12)) {
                    isOffPage(image.rgb(px: cx, $0))
                }
                guard let vertical = down.first(where: { $0.overlaps(row) }) else { continue }
                let cy = Int((((vertical.lowerBound + vertical.upperBound) / 2) * scale).rounded(.down))
                let across = runs(count: image.width, scale: scale, from: span.lowerBound - 6, to: span.upperBound + 6) {
                    isOffPage(image.rgb(px: $0, cy))
                }
                guard let horizontal = across.first(where: { $0.overlaps(span) }) else { continue }
                found.append(FoundTile(
                    rect: CGRect(
                        x: horizontal.lowerBound, y: vertical.lowerBound,
                        width: horizontal.upperBound - horizontal.lowerBound, height: vertical.upperBound - vertical.lowerBound
                    ),
                    row: rowIndex, column: column,
                    clipped: vertical.lowerBound <= scroll.minY + 0.5 || vertical.upperBound >= scroll.maxY - 0.5
                ))
            }
            rowIndex += 1
        }
        return found
    }

    static func isBlue(_ image: ProbeImage, at point: CGPoint) -> Bool {
        isBlue(image.rgb(px: Int((point.x * image.scale).rounded(.down)), Int((point.y * image.scale).rounded(.down))))
    }
}

/// Largest of the four edge offsets: how far a card sits from a tile, as the eye reads it.
private func edgeOffset(_ a: CGRect, _ b: CGRect) -> CGFloat {
    max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
}

private func describe(_ rect: CGRect) -> String {
    String(format: "(%.2f, %.2f, %.2f×%.2f)", rect.minX, rect.minY, rect.width, rect.height)
}

private func scrollEvent(y: Int32, phase: CGScrollPhase) throws -> NSEvent {
    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: 0, wheel3: 0))
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    return try #require(NSEvent(cgEvent: event))
}

private func sample(_ image: ProbeImage, at point: CGPoint) -> ProbeColor {
    image.rgb(px: Int((point.x * image.scale).rounded(.down)), Int((point.y * image.scale).rounded(.down)))
}

/// How much of `layer` lies over `backdrop` in `sample`: 0 is the backdrop alone, 1 the layer alone.
private func coverage(_ sample: ProbeColor, layer: ProbeColor, backdrop: ProbeColor) -> CGFloat {
    let full = [layer.r - backdrop.r, layer.g - backdrop.g, layer.b - backdrop.b].map { CGFloat($0) }
    let seen = [sample.r - backdrop.r, sample.g - backdrop.g, sample.b - backdrop.b].map { CGFloat($0) }
    let norm = full.reduce(0) { $0 + $1 * $1 }
    return norm > 0 ? zip(full, seen).reduce(0) { $0 + $1.0 * $1.1 } / norm : 0
}

/// While `holding`, a cover decode waits instead of returning, so a tile shows only what the cache already has.
@MainActor
private final class DecodeGate {
    var holding = false

    func pass() async {
        while holding {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func coverItem(_ index: Int) -> LiveWallpaper.LibraryItem {
    let bookmark = WallpaperBookmark(label: "", content: .video(bookmarkData: Data([1])), coverFileName: "cover-\(index).png")
    return LiveWallpaper.LibraryItem(
        id: "bookmark:\(bookmark.id)", title: "Tile \(index)", kind: .video, source: .bookmark(bookmark),
        isSteam: false, createdAt: bookmark.createdAt, lastUsedAt: nil, onDisplays: [],
        thumbnail: .bookmark(bookmark), metadata: nil, isVariant: false, parentID: nil, isSupported: true
    )
}

/// The shelf hands its cards to the library grid and takes them back: where the stage lands them
/// against where the grid really draws its tiles, and what the grid does when the stage carries
/// them off again.
@MainActor
@Suite("Shelf and library grid handoff", .serialized)
struct ShelfGridHandoffTests {
    static let sizes = [CGSize(width: 1040, height: 700), CGSize(width: 1280, height: 820), CGSize(width: 1728, height: 1080)]
    static let designSize = CGSize(width: 1280, height: 820)

    /// Every tile the grid draws whole has the stage's card for it, within half a point; the plain
    /// library is the control, the onboarding card and the display banner push the grid down.
    @Test("The stage lands each card on the tile the library grid really draws", .timeLimit(.minutes(3)))
    func landingMatchesTheRenderedGrid() async throws {
        for (onboarding, target) in [(false, false), (true, false), (false, true)] {
            for size in Self.sizes {
                let label = "\(Int(size.width))×\(Int(size.height))\(onboarding ? " with the onboarding card" : "")\(target ? " with the display banner" : "")"
                let host = try HandoffHost(size: size, onboarding: onboarding, target: target)
                defer { host.close() }
                try await host.settleOnLibrary()
                let stage = try #require(host.stage)
                let scroll = try #require(host.grid)
                let model = stage.model
                let columnWidth = StageGeometry.gridCellSize(windowWidth: size.width, size: model.gridTileSize).width
                let found = try TileFinder.tiles(in: host.renderWithoutStage(), scroll: host.gridFrame(scroll), columnWidth: columnWidth)
                let columns = (found.map(\.column).max() ?? -1) + 1
                try #require(found.count >= 4, Comment(rawValue: "\(label): found \(found.count) tiles"))
                var worst: (offset: CGFloat, index: Int, card: CGRect, tile: CGRect)?
                var missing: [Int] = []
                for tile in found {
                    let index = tile.row * columns + tile.column
                    guard let card = stage.cardLayers[model.shelfItems[index].id]?.layer.frame else {
                        missing.append(index)
                        continue
                    }
                    guard !tile.clipped else { continue }
                    let offset = edgeOffset(card, tile.rect)
                    if offset > (worst?.offset ?? -1) {
                        worst = (offset, index, card, tile.rect)
                    }
                }
                #expect(missing.isEmpty, Comment(rawValue: "\(label): the grid draws tiles \(missing) the stage has no card for"))
                if let worst {
                    #expect(
                        worst.offset <= 0.5,
                        Comment(rawValue: "\(label): card \(worst.index) lands at \(describe(worst.card)), its tile is at \(describe(worst.tile)) — \(String(format: "%.2f", worst.offset))pt off")
                    )
                }
            }
        }
    }

    /// The cards sit on the tiles when the stage takes a swipe back from the library, so the grid has
    /// to be gone the frame the cards start to move: no finger travel moves hidden cards under it.
    @Test("A return swipe takes the grid away on its first step", .timeLimit(.minutes(1)))
    func returnSwipeHidesTheGridAtOnce() async throws {
        let host = try HandoffHost(size: Self.designSize)
        defer { host.close() }
        try await host.settleOnLibrary()
        let stage = try #require(host.stage)
        let scroll = try #require(host.grid)
        let columnWidth = StageGeometry.gridCellSize(windowWidth: Self.designSize.width, size: stage.model.gridTileSize).width
        let atRest = try host.renderWithoutStage()
        let tile = try #require(TileFinder.tiles(in: atRest, scroll: host.gridFrame(scroll), columnWidth: columnWidth).first)
        let centre = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        let showsAtRest = TileFinder.isBlue(atRest, at: centre)
        try #require(showsAtRest, "control: the grid does not show its first tile at rest")
        try #require(host.hitView(at: centre)?.isDescendant(of: scroll) == true, "control: a click on the first tile misses the grid at rest")

        try host.route(scrollEvent(y: 8, phase: .began), at: centre)
        var steps = 0
        while stage.model.progress >= 2, steps < 8 {
            try host.route(scrollEvent(y: 8, phase: .changed), at: centre)
            steps += 1
        }
        let moved = stage.model.progress
        try #require(moved < 2, "the swipe never reached the stage")
        await host.settle(seconds: 0.1)
        let showsWhileMoving = try TileFinder.isBlue(host.renderWithoutStage(), at: centre)
        #expect(
            !showsWhileMoving,
            Comment(rawValue: "the grid still shows over cards the swipe has already moved to p = \(moved)")
        )
        #expect(
            host.hitView(at: centre)?.isDescendant(of: scroll) != true,
            Comment(rawValue: "the grid still takes clicks while the cards move under it at p = \(moved)")
        )
    }

    /// Esc and the nav pill leave from wherever the grid is scrolled to: the first frame of the flight
    /// has to put each card on the tile the user was looking at, with its picture.
    @Test("Leaving a scrolled library starts every card from the tile on screen", .timeLimit(.minutes(1)))
    func leavingAScrolledGridStartsFromItsTiles() async throws {
        for leave in ["Esc", "nav pill"] {
            let host = try HandoffHost(size: Self.designSize)
            defer { host.close() }
            try await host.settleOnLibrary()
            let stage = try #require(host.stage)
            let scroll = try #require(host.grid)
            let model = stage.model
            let scrolled: CGFloat = 500
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scrolled))
            scroll.reflectScrolledClipView(scroll.contentView)
            await host.settle(seconds: 0.5)
            let cell = StageGeometry.gridCellSize(windowWidth: Self.designSize.width, size: model.gridTileSize)
            let pitch = cell.height + DesignTokens.LibraryGrid.spacing
            let firstRowTop = StageGeometry.gridTop + DesignTokens.LibraryGrid.verticalPadding - scrolled
            let found = try TileFinder.tiles(in: host.renderWithoutStage(), scroll: host.gridFrame(scroll), columnWidth: cell.width)
                .filter { !$0.clipped }
            let columns = StageGeometry.gridColumns(windowWidth: Self.designSize.width, size: model.gridTileSize)
            try #require(found.count >= columns, Comment(rawValue: "control: \(found.count) whole tiles on screen at \(scrolled)pt"))
            let onScreen = found.map { tile in
                (index: Int(((tile.rect.minY - firstRowTop) / pitch).rounded()) * columns + tile.column, rect: tile.rect)
            }
            // Cards the stage held while landed carry the shelf's decode; the rest only ever had the tile's own.
            let restingGrid = model.visibleGridRange
            let anyRequest = ShelfThumbnailCache.Request.bookmark(WallpaperBookmark(label: "", content: .video(bookmarkData: Data([1]))))
            let tilePixels = LibraryGridTile.Thumbnail(anyRequest, tileWidth: cell.width, scale: NSScreen.main?.backingScaleFactor ?? 2).pixelSize

            switch leave {
            case "Esc":
                _ = model.escape()
            default:
                host.router.select(.home)
                await host.settle(seconds: 0.2)
            }
            try #require(model.progress == 2, "the stage moved before its first frame could be read")
            var worst: (offset: CGFloat, index: Int)?
            var missing: [Int] = []
            for tile in onScreen {
                guard let card = stage.cardLayers[model.shelfItems[tile.index].id]?.layer.frame else {
                    missing.append(tile.index)
                    continue
                }
                let offset = edgeOffset(card, tile.rect)
                if offset > (worst?.offset ?? -1) {
                    worst = (offset, tile.index)
                }
            }
            #expect(missing.isEmpty, Comment(rawValue: "\(leave): tiles \(missing) on screen have no card to fly back"))
            if let worst {
                #expect(
                    worst.offset <= 0.5,
                    Comment(rawValue: "\(leave): card \(worst.index) starts \(String(format: "%.2f", worst.offset))pt from its tile on screen")
                )
            }
            await host.settle(seconds: 0.2)
            let bare = onScreen.map(\.index).filter { model.shelfItems[$0].thumbnail == nil }
            #expect(bare.isEmpty, Comment(rawValue: "\(leave): cards \(bare) fly back without the picture their tile showed"))
            let redecoded = onScreen.map(\.index).filter { index in
                !restingGrid.contains(index) && model.shelfItems[index].thumbnail.map { CGFloat($0.width) } != tilePixels.width
            }
            #expect(
                redecoded.isEmpty,
                Comment(rawValue: "\(leave): cards \(redecoded) wait for a fresh decode instead of taking the \(Int(tilePixels.width))px picture their tile showed")
            )
        }
    }

    /// A return swipe pushed back to the library lands there again with the grid as it was; the next
    /// swipe then goes all the way home. Neither may stop between states.
    @Test("A return swipe pushed back keeps the grid, and the next one goes home", .timeLimit(.minutes(1)))
    func returnSwipePushedBackKeepsTheGrid() async throws {
        let host = try HandoffHost(size: Self.designSize)
        defer { host.close() }
        try await host.settleOnLibrary()
        let stage = try #require(host.stage)
        let scroll = try #require(host.grid)
        let model = stage.model
        let columnWidth = StageGeometry.gridCellSize(windowWidth: Self.designSize.width, size: model.gridTileSize).width
        let tile = try #require(TileFinder.tiles(in: host.renderWithoutStage(), scroll: host.gridFrame(scroll), columnWidth: columnWidth).first)
        let centre = CGPoint(x: tile.rect.midX, y: tile.rect.midY)

        /// One trackpad event a frame, so the release velocity is measured over real time.
        func swipe(_ steps: [Int32], phase: CGScrollPhase = .changed) async throws {
            for y in steps {
                try host.route(scrollEvent(y: y, phase: phase), at: centre)
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        /// Offscreen there is no display link, so the frames are stepped here until nothing moves.
        func land() {
            for _ in 0 ..< 300 {
                stage.advance(dt: 1.0 / 60)
                if !stage.debugNeedsDisplayLink {
                    return
                }
            }
        }

        // Down to 1.83: past the first step, short of the handoff point where the grid would unmount.
        try await swipe([8], phase: .began)
        try await swipe(Array(repeating: 8, count: 8))
        try #require(model.progress < 2 && model.progress > StageGeometry.libraryHandoffProgress, Comment(rawValue: "the swipe stopped at \(model.progress)"))
        await host.settle(seconds: 0.1)
        let showsMidSwipe = try TileFinder.isBlue(host.renderWithoutStage(), at: centre)
        #expect(!showsMidSwipe, Comment(rawValue: "the grid shows over the moving cards at \(model.progress)"))
        try #require(host.grid === scroll, "the grid unmounted above the handoff point")

        // Pushed back up and released: the library again, with the same grid at the same scroll.
        try await swipe(Array(repeating: -8, count: 10))
        try await swipe([0], phase: .ended)
        land()
        #expect(model.progress == 2 && model.snappedIndex == 2, Comment(rawValue: "the pushed-back swipe stopped at \(model.progress)"))
        await host.settle(seconds: 0.3)
        #expect(host.grid === scroll, "the grid was rebuilt by a swipe that never left it")
        #expect(scroll.contentView.bounds.minY == 0, Comment(rawValue: "the grid moved to \(scroll.contentView.bounds.minY)"))
        let showsAfterPushBack = try TileFinder.isBlue(host.renderWithoutStage(), at: centre)
        #expect(showsAfterPushBack, "the grid never came back after the swipe was pushed back")

        // The next swipe goes home and settles there.
        try await swipe([8], phase: .began)
        try await swipe(Array(repeating: 8, count: 24))
        try await swipe([0], phase: .ended)
        land()
        #expect(model.progress == 1 && model.snappedIndex == 1, Comment(rawValue: "the second swipe stopped at \(model.progress)"))
        await host.settle(seconds: 0.3)
        #expect(host.grid == nil, "the grid stayed mounted on the shelf")
    }

    /// The grid takes each card over with the very picture the card is drawing, decoded at the tile's own size, so
    /// nothing is swapped in once the tiles show. Counted over the grid's first screen.
    @Test("Each tile the grid mounts shows the picture its card landed with, at the tile's own size", .timeLimit(.minutes(3)))
    func handoffKeepsTheCardsPicture() async throws {
        // The crate keeps the most shelf-sized pictures cached beside the grid's, so it presses the cache hardest.
        for (style, size) in [ShelfStyle.facingIn, .crate].flatMap({ style in Self.sizes.map { (style, $0) } }) {
            let label = "\(Int(size.width))×\(Int(size.height)) \(style)"
            let host = try HandoffHost(size: size, onLibrary: false)
            defer { host.close() }
            await host.settle(seconds: 2) { host.stage != nil }
            // Past the page's `onAppear`, which sets the style from the settings.
            await host.settle(seconds: 0.3)
            let stage = try #require(host.stage)
            let model = stage.model
            model.shelfStyle = style
            model.setProgress(1, animated: false)
            // The shelf has been open a while, so its own pictures are in.
            await host.settle(seconds: 3) {
                !model.visibleShelfRange.isEmpty && model.visibleShelfRange.allSatisfy { model.shelfItems[$0].thumbnail != nil }
            }
            await host.settle(seconds: 0.3)
            host.router.select(.library)
            await host.settle(seconds: 1) { stage.debugStaggerToGrid }
            try #require(stage.debugStaggerToGrid, Comment(rawValue: "\(label): the nav pill never started the flight"))
            // A frame's wall time per step, so the decodes race the flight as they would on screen.
            var frames = 0
            while model.snappedIndex != 2, frames < 240 {
                stage.advance(dt: 1.0 / 60)
                try await Task.sleep(for: .milliseconds(16))
                frames += 1
            }
            try #require(model.snappedIndex == 2, Comment(rawValue: "\(label): never handed over"))
            // What each card of the grid's first screen draws on the frame the grid takes over.
            let cards = model.visibleGridRange.map { index -> (index: Int, image: CGImage?) in
                let image = model.shelfItems[index].thumbnail
                let drawn = stage.cardLayers[model.shelfItems[index].id]?.thumbnail.contents as AnyObject?
                return (index, drawn === image ? image : nil)
            }
            let request = try #require(host.library.visibleItems.first?.thumbnail)
            let tilePixels = LibraryGridTile.Thumbnail(
                request, tileWidth: StageGeometry.gridCellSize(windowWidth: size.width, size: model.gridTileSize).width,
                scale: NSScreen.main?.backingScaleFactor ?? 2
            ).pixelSize
            await host.settle(seconds: 1) { host.grid != nil }
            try #require(host.grid != nil, Comment(rawValue: "\(label): the grid never mounted"))
            let mounted = host.pictures(excluding: stage)
            // By now every tile has run its own decode: a picture it had to wait for has replaced the card's.
            await host.settle(seconds: 0.5)
            let settled = host.pictures(excluding: stage)
            let tileSized = settled.values.filter { $0 == tilePixels }.count
            try #require(
                tileSized >= cards.count,
                Comment(rawValue: "\(label): control: the page's layers show \(tileSized) tile-sized pictures for \(cards.count) tiles")
            )
            var same = 0
            var other: [String] = []
            for card in cards {
                if let image = card.image, CGFloat(image.width) == tilePixels.width,
                   mounted[ObjectIdentifier(image)] != nil, settled[ObjectIdentifier(image)] != nil {
                    same += 1
                } else {
                    let drawn = card.image.map { "\($0.width)×\($0.height)" } ?? "none"
                    let shown = card.image.map { mounted[ObjectIdentifier($0)] != nil ? "shown" : "not shown" } ?? ""
                    other.append("\(card.index): card \(drawn) \(shown)")
                }
            }
            func sizes(_ pictures: [ObjectIdentifier: CGSize]) -> [String: Int] {
                Dictionary(grouping: pictures.values) { "\(Int($0.width))×\(Int($0.height))" }.mapValues(\.count)
            }
            print("HANDOFF-SAME-PICTURE \(label): \(same)/\(cards.count) after \(frames) frames; mounted \(sizes(mounted)), settled \(sizes(settled)); \(other)")
            #expect(
                other.isEmpty,
                Comment(rawValue: "\(label): \(other.count) of \(cards.count) tiles do not show the picture their card landed with: \(other)")
            )
        }
    }

    /// A tile showing the shelf's 400×224 copy while its own size decodes keeps its column's frame: the copy's
    /// proportions, 400:224 rather than 16:9, must not size it.
    @Test("A tile showing the shelf's copy keeps the grid's own frame", .timeLimit(.minutes(1)))
    func shelfCopyKeepsTheTileFrame() async throws {
        let blue = ProbeRenderer.solid(ProbeRenderer.thumbnailBlue, size: CGSize(width: 1600, height: 900))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for size in Self.sizes {
            let label = "\(Int(size.width))×\(Int(size.height))"
            let gate = DecodeGate()
            var sources = ShelfThumbnailCache.Sources()
            sources.cover = { _ in
                await gate.pass()
                return blue
            }
            let cache = ShelfThumbnailCache(sources: sources)
            let items = (0 ..< 12).map(coverItem)
            // The shelf's copies are in; every tile's own decode then waits, so the tiles show nothing but those copies.
            for request in items.compactMap(\.thumbnail) {
                _ = await cache.image(request, pixelSize: CGSize(width: 400, height: 224), scale: scale)
            }
            gate.holding = true
            defer { gate.holding = false }
            let cell = StageGeometry.gridCellSize(windowWidth: size.width)
            let grid = ScrollView {
                LibraryGalleryGrid(size: .small, aspect: .wide, initialWidth: size.width - 2 * DesignTokens.LibraryGrid.horizontalPadding) {
                    ForEach(items) { item in
                        LibraryGridTile(
                            item: item, thumbnail: item.thumbnail.map { LibraryGridTile.Thumbnail($0, tileWidth: cell.width, scale: scale) },
                            thumbnails: cache, badges: LibraryCardBadges()
                        )
                    }
                }
                .libraryGridPadding()
            }
            .background(DesignTokens.EditDesk.Colors.background)
            let hosting = NSHostingView(rootView: grid.frame(width: size.width, height: size.height))
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = HandoffWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.orderBack(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline {
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let image = try ProbeImage(cgImage: #require(bitmap.cgImage), viewWidth: size.width)
            let columns = StageGeometry.gridColumns(windowWidth: size.width)
            let found = TileFinder.tiles(in: image, scroll: CGRect(origin: .zero, size: size), columnWidth: cell.width)
                .filter { !$0.clipped }
            try #require(found.count >= columns, Comment(rawValue: "\(label): found \(found.count) whole tiles"))
            var worst: (offset: CGFloat, index: Int, drawn: CGRect, frame: CGRect)?
            for tile in found {
                let index = tile.row * columns + tile.column
                let frame = StageGeometry.gridFrame(index: index, windowWidth: size.width).offsetBy(dx: 0, dy: -StageGeometry.gridTop)
                let offset = max(
                    edgeOffset(tile.rect, frame), abs(tile.rect.width - frame.width), abs(tile.rect.height - frame.height)
                )
                if offset > (worst?.offset ?? -1) {
                    worst = (offset, index, tile.rect, frame)
                }
            }
            let measured = try #require(worst)
            #expect(
                measured.offset <= 0.5,
                Comment(rawValue: "\(label): tile \(measured.index) draws \(describe(measured.drawn)) on the shelf's copy against the grid's \(describe(measured.frame)), \(String(format: "%.2f", measured.offset))pt off")
            )
        }
    }

    /// Under the cards the library's own page colour fills in over the flight's last stretch: none of it at p = 1.6,
    /// all of it by the handoff, never backing off in between, from the grid's top to the window's bottom.
    @Test("The library's page colour fills in under the cards before the grid takes over", .timeLimit(.minutes(1)))
    func pageColourFillsInUnderTheCards() async throws {
        let size = Self.designSize
        let host = try HandoffHost(size: size, backdrop: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        defer { host.close() }
        try await host.settleOnLibrary()
        let stage = try #require(host.stage)
        let scroll = try #require(host.grid)
        // The grid's own background, in its left margin where no tile sits.
        let page = try sample(host.renderWithoutStage(), at: CGPoint(x: 8, y: host.gridFrame(scroll).minY + 7))
        // Hidden as a return swipe hides it, so what lies under the cards shows.
        stage.model.report(leavingLibrary: true)
        var renders: [(progress: Double, image: ProbeImage)] = []
        for progress in [1.5, 1.6, 1.7, 1.8, 1.9, 1.95, 2] {
            stage.model.report(progress: progress)
            await host.settle(seconds: 0.15)
            let image = try host.renderWithoutStage()
            renders.append((progress, image))
        }
        let centre = CGPoint(x: size.width / 2, y: 330)
        let backdrop = sample(renders[0].image, at: centre)
        try #require(backdrop.isRed, Comment(rawValue: "control: the backdrop at p = 1.5 reads \(backdrop)"))
        let alphas = renders.map { (progress: $0.progress, alpha: coverage(sample($0.image, at: centre), layer: page, backdrop: backdrop)) }
        let described = alphas.map { String(format: "%.2f:%.2f", $0.progress, $0.alpha) }.joined(separator: " ")
        print("UNDERLAY progress:alpha \(described)")
        let at = Dictionary(uniqueKeysWithValues: alphas.map { ($0.progress, $0.alpha) })
        #expect((at[1.6] ?? 1) <= 0.02, Comment(rawValue: "the page colour already shows at p = 1.6: \(described)"))
        #expect((at[2] ?? 0) >= 0.98, Comment(rawValue: "the page colour is not all there at p = 2: \(described)"))
        #expect((at[1.8] ?? 0) > 0.2 && (at[1.8] ?? 1) < 0.8, Comment(rawValue: "the page colour does not fill in across the stretch: \(described)"))
        for (earlier, later) in zip(alphas, alphas.dropFirst()) {
            #expect(
                later.alpha >= earlier.alpha - 0.02,
                Comment(rawValue: "the page colour backs off from p = \(earlier.progress) to \(later.progress): \(described)")
            )
        }
        let landed = renders[renders.count - 1].image
        for point in [CGPoint(x: 12, y: StageGeometry.gridTop + 1), CGPoint(x: 12, y: size.height - 2)] {
            let alpha = coverage(sample(landed, at: point), layer: page, backdrop: backdrop)
            #expect(alpha >= 0.98, Comment(rawValue: "at p = 2 the page colour covers only \(alpha) of \(point)"))
        }
        let above = CGPoint(x: 12, y: StageGeometry.gridTop - 2)
        let spill = coverage(sample(landed, at: above), layer: page, backdrop: backdrop)
        #expect(spill <= 0.02, Comment(rawValue: "the page colour reaches above the grid's top, \(spill) at \(above)"))
    }
}
#endif
