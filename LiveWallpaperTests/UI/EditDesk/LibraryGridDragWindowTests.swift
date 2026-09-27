#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

// `ProbeImage` and `ProbeRenderer` come from `EditDeskFidelityProbeTests.swift`, compiled for Pro only.

/// A titled window is pulled onto a real display when it is ordered in; this one has to stay off screen.
private final class GridDragWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}

private enum GridDragDisplays {
    static let left: CGDirectDisplayID = 0x6D1D_0001
    static let right: CGDirectDisplayID = 0x6D1D_0002
}

/// AppKit traps when a bare `NSScreen()` is asked these.
private final class GridDragLeftScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): GridDragDisplays.left]
    }

    override var localizedName: String {
        "Grid Drag Left"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}

private final class GridDragRightScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 1920, y: 0, width: 1920, height: 1080)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): GridDragDisplays.right]
    }

    override var localizedName: String {
        "Grid Drag Right"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}

/// The real `HomePage` opened on the library over two displays side by side, in the Edit Desk window's chrome,
/// ordered in off screen so synthesized mouse and key events reach SwiftUI's gestures. Every row's cover is blue;
/// once `settleOnLibrary` returns the left display's cover is red and the right one's magenta.
@MainActor
private final class GridDragHost {
    /// The strip's thumbnails are 84pt tall, centred in its 104pt panel.
    static let stripRow = FloatLayerGeometry.panelTop + FloatLayerGeometry.panelHeight / 2

    struct Strip {
        let left: CGPoint
        let right: CGPoint
        /// The right thumbnail's cover, top to bottom through its middle.
        let rightSpan: (top: CGFloat, bottom: CGFloat)
    }

    let window: NSWindow
    let host: NSView
    let manager: ScreenManager
    let router: EditDeskRouter
    let toasts = EditDeskToastCenter()
    private let size: CGSize

    init(size: CGSize) {
        self.size = size
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [
                Screen(nsScreen: GridDragLeftScreen()), Screen(nsScreen: GridDragRightScreen()),
            ]),
            featureCatalog: .unconfigured
        ))
        let blue = NSImage(
            cgImage: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue, size: CGSize(width: 1600, height: 900)),
            size: NSSize(width: 1600, height: 900)
        )
        // The bookmark bytes resolve to nothing, so an apply stops at its source check and never reaches a display.
        let rows = (0 ..< 6).map { index -> WallpaperBookmark in
            let id = UUID()
            return WallpaperBookmark(
                label: "Grid drag \(index)", content: .video(bookmarkData: Data([UInt8(index), 9, 9])), id: id,
                coverFileName: WallpaperCoverStore.shared.store(blue, for: id)
            )
        }
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { rows }
        router = EditDeskRouter(initialNavigation: .bookmarks, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let library = SavedLibraryModel(inputs: inputs)
        let hosting = NSHostingView(rootView: HomePage(router: router, toasts: toasts, library: library).environment(manager))
        hosting.sizingOptions = []
        window = GridDragWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "GridDragToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        // Without it a synthesized key press reaches no key-equivalent handler, and the page's Escape stays silent.
        window.makeKey()
        host = hosting
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        manager.tearDownForTermination()
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

    /// Landed on the library with the grid mounted, and the displays' covers painted.
    func settleOnLibrary() async throws {
        await settle(seconds: 3) { stage?.model.progress == 2 && stage?.model.snappedIndex == 2 && grid != nil }
        await settle(seconds: 0.8)
        let model = try #require(stage?.model)
        let landed = model.snappedIndex == 2
        try #require(landed, "the page never landed on the library")
        let mounted = grid != nil
        try #require(mounted, "the library grid never mounted")
        for (id, color) in [(GridDragDisplays.left, ProbeRenderer.previewRed), (GridDragDisplays.right, ProbeRenderer.heroMagenta)] {
            let found = model.displays.firstIndex { $0.id == id }
            let index = try #require(found, "the stage has no display \(id)")
            model.displays[index].cover = ProbeRenderer.solid(color, size: CGSize(width: 192, height: 108))
        }
    }

    func tileCenter(_ index: Int) throws -> CGPoint {
        let frame = try tileFrame(index)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Above the tile's bottom gradient and title, where it shows its cover alone.
    func tileSample(_ index: Int) throws -> CGPoint {
        let frame = try tileFrame(index)
        return CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.3)
    }

    private func tileFrame(_ index: Int) throws -> CGRect {
        let model = try #require(stage?.model)
        return StageGeometry.gridFrame(index: index, windowWidth: size.width, size: model.gridTileSize)
    }

    /// The SwiftUI layers alone: the stage's own layers are hidden for the capture.
    func render() throws -> ProbeImage {
        let stageView = stage
        stageView?.isHidden = true
        defer { stageView?.isHidden = false }
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        let bitmap = try #require(rep)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = bitmap.cgImage
        return try ProbeImage(cgImage: #require(image), viewWidth: host.bounds.width)
    }

    /// Thumbnail-wide runs of each display's cover along the row through the strip's middle.
    func stripRuns() throws -> (red: [ProbeRun], magenta: [ProbeRun]) {
        let image = try render()
        return (
            image.runs(inRow: Self.stripRow) { $0.isRed }.filter { $0.width >= 40 },
            image.runs(inRow: Self.stripRow) { $0.isMagenta }.filter { $0.width >= 40 }
        )
    }

    /// The strip once it has slid in: one thumbnail per display, found by its cover. nil when it never shows.
    func strip() async throws -> Strip? {
        await settle(seconds: 0.5)
        var found: (red: [ProbeRun], magenta: [ProbeRun])?
        await settle(seconds: 2) {
            found = try? stripRuns()
            return found?.red.count == 1 && found?.magenta.count == 1
        }
        guard let found, let left = found.red.first, let right = found.magenta.first,
              found.red.count == 1, found.magenta.count == 1 else { return nil }
        let rightX = right.x + right.width / 2
        let column = try render().verticalSpan(inColumn: rightX) { $0.isMagenta }
        let span = try #require(column)
        return Strip(
            left: CGPoint(x: left.x + left.width / 2, y: Self.stripRow),
            right: CGPoint(x: rightX, y: Self.stripRow),
            rightSpan: span
        )
    }

    /// An apply reached `id`: the rows' bookmarks resolve to nothing, so each apply ends in that display's failure toast.
    func applied(to id: CGDirectDisplayID) -> Bool {
        toasts.toasts.contains { $0.style == .failure && $0.screenID == id }
    }

    /// The stage stays locked while the detail is open.
    var detailOpen: Bool {
        stage?.model.interactionBlocked == true
    }

    var leavingLibrary: Bool {
        stage?.model.leavingLibrary == true
    }

    /// The right display's thumbnail sits on the strip's row.
    var stripShows: Bool {
        (try? stripRuns().magenta.isEmpty) == false
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

    /// Through `NSApp`, so local event monitors see it the way a real key press would reach them.
    func escape() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else { return }
        NSApp.sendEvent(event)
    }

    /// `point` has a top-left origin; window coordinates start bottom-left.
    private func send(_ type: NSEvent.EventType, _ point: CGPoint) async {
        guard let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [],
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

private enum TileSample {
    static func isBlue(_ image: ProbeImage, _ point: CGPoint) -> Bool {
        image.rgb(px: Int((point.x * image.scale).rounded(.down)), Int((point.y * image.scale).rounded(.down))).isBlue
    }
}

private extension CGPoint {
    func moved(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

/// One mouse wheel notch the way that, at the grid's top, the stage takes to fold the library away.
private func wheelNotch() throws -> NSEvent {
    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
    return try #require(NSEvent(cgEvent: event))
}

/// A library grid tile dragged onto the S5 strip of displays the detail modal uses. Results are bound before
/// `#expect`: a failing expectation reflects every value in its expression, and reflecting the host's AppKit views traps.
@Suite("Library grid drag in a window", .serialized)
@MainActor
struct LibraryGridDragWindowTests {
    private static let size = CGSize(width: 1280, height: 820)
    private static let midWindow = CGPoint(x: 640, y: 420)

    @Test("A grid tile dragged onto a display in the strip applies there; a click still opens the detail", .timeLimit(.minutes(1)))
    func tileDropAppliesToThatDisplay() async throws {
        let host = GridDragHost(size: Self.size)
        defer { host.close() }
        try await host.settleOnLibrary()
        let before = try host.stripRuns()
        #expect(before.red.isEmpty && before.magenta.isEmpty, "control: a cover colour already sits where the strip rides")
        NSCursor.crosshair.push()
        defer { NSCursor.pop() }
        let tile = try host.tileCenter(0)
        await host.press(tile)
        await host.drag(through: [tile.moved(3, 0), tile.moved(20, -10), Self.midWindow])
        let found = try await host.strip()
        let strip = try #require(found, "a tile drag never brought the display strip in")
        let tookCursor = NSCursor.current == NSCursor.closedHand
        #expect(tookCursor, "the drag never took the cursor")
        let dragging = try host.render()
        let draggedTileDimmed = try !TileSample.isBlue(dragging, host.tileSample(0))
        let otherTileBlue = try TileSample.isBlue(dragging, host.tileSample(1))
        #expect(draggedTileDimmed, "the dragged tile did not dim under the ghost")
        #expect(otherTileBlue, "control: a tile nobody drags is not blue in the render")
        // Where the modal hangs its strip: the thumbnail centred in the panel under the window's top.
        let top = FloatLayerGeometry.panelTop + (FloatLayerGeometry.panelHeight - FloatLayerGeometry.thumbnailHeight) / 2
        #expect(abs(strip.rightSpan.top - top) <= 3, Comment(rawValue: "thumbnail top \(strip.rightSpan.top), expected \(top)"))
        let height = strip.rightSpan.bottom - strip.rightSpan.top
        #expect(abs(height - FloatLayerGeometry.thumbnailHeight) <= 3, Comment(rawValue: "thumbnail height \(height)"))
        await host.drag(through: [strip.right])
        await host.release(strip.right)
        let appliedRight = await host.settle { host.applied(to: GridDragDisplays.right) }
        #expect(appliedRight, "the drop on the right display applied nothing there")
        let appliedLeft = host.applied(to: GridDragDisplays.left)
        #expect(!appliedLeft, "the drop also applied to the display it missed")
        let openedDetail = host.detailOpen
        #expect(!openedDetail, "the drag also counted as a click and opened the detail")
        let stripGone = await host.settle { !host.stripShows }
        #expect(stripGone, "the strip stayed up after the drop")
        let poppedOnce = NSCursor.current == NSCursor.crosshair
        #expect(poppedOnce, "the drop did not pop the drag's cursor exactly once")

        try await host.click(host.tileCenter(1))
        let clickOpens = await host.settle { host.detailOpen }
        #expect(clickOpens, "a click on a tile no longer opens its detail")
    }

    @Test("Escape during a tile drag takes the strip away, applies nothing and keeps the library open", .timeLimit(.minutes(1)))
    func escapeCancelsATileDrag() async throws {
        let host = GridDragHost(size: Self.size)
        defer { host.close() }
        try await host.settleOnLibrary()
        let tile = try host.tileCenter(0)
        await host.press(tile)
        await host.drag(through: [tile.moved(3, 0), tile.moved(20, -10), Self.midWindow])
        let found = try await host.strip()
        let strip = try #require(found, "a tile drag never brought the display strip in")
        let locked = host.stage?.model.interactionBlocked == true
        #expect(locked, "the tile drag left the stage free to take the wheel")
        host.escape()
        let stripGone = await host.settle { !host.stripShows }
        #expect(stripGone, "Escape left the strip up")
        let leftLibrary = host.leavingLibrary
        #expect(!leftLibrary, "Escape during a drag reached the page and left the library")
        await host.drag(through: [strip.right])
        await host.release(strip.right)
        await host.settle(seconds: 0.6)
        let applied = host.applied(to: GridDragDisplays.right)
        #expect(!applied, "the cancelled drag still applied")
        let stripBack = host.stripShows
        #expect(!stripBack, "the rest of the cancelled gesture brought the strip back")

        host.escape()
        let escapeReachesPage = await host.settle { host.leavingLibrary }
        #expect(escapeReachesPage, "control: with no drag running, Escape never reached the page, so this harness proves nothing")
    }

    @Test("A wheel notch at the grid's top during a tile drag stays with the grid, and the drop still applies", .timeLimit(.minutes(1)))
    func wheelDuringATileDragKeepsTheLibrary() async throws {
        let host = GridDragHost(size: Self.size)
        defer { host.close() }
        try await host.settleOnLibrary()
        let stage = try #require(host.stage)
        let tile = try host.tileCenter(0)
        await host.press(tile)
        await host.drag(through: [tile.moved(3, 0), tile.moved(20, -10), Self.midWindow])
        let found = try await host.strip()
        let strip = try #require(found, "a tile drag never brought the display strip in")

        let notch = try wheelNotch()
        let passedOn = stage.forwardGridScroll(notch) === notch
        #expect(passedOn, "the stage took a wheel notch in the middle of a tile drag")
        await host.settle(seconds: 0.5)
        let progress = stage.model.progress
        let leaving = host.leavingLibrary
        #expect(progress == 2 && !leaving, Comment(rawValue: "the wheel under the drag moved the stage to \(progress)"))
        await host.drag(through: [strip.right])
        await host.release(strip.right)
        let applied = await host.settle { host.applied(to: GridDragDisplays.right) }
        #expect(applied, "the drop after the wheel applied nothing")

        await host.settle { !stage.model.interactionBlocked }
        let control = try wheelNotch()
        let taken = stage.forwardGridScroll(control) == nil
        #expect(taken, "control: with the drag over, the same notch never reached the stage, so this proves nothing")
    }
}
#endif
