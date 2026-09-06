import AppKit
import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The inspector draws a whole desktop into a few hundred points. Doing that
/// with a SwiftUI `scaleEffect` moved the drawing but not the hit region, so
/// every tile's pointer target stayed out at the desktop's coordinates and a
/// drag grabbed nothing. The host scales its own `bounds` instead, which is the
/// one form of scaling AppKit also applies to event coordinates.
@Suite("Monitor inspector board preview scale")
@MainActor
struct BoardPreviewScaleTests {
    private let logical = CGSize(width: 1600, height: 900)
    private let displayed = CGSize(width: 400, height: 225)
    private let placement = MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.25, y: 0.25)

    private var geometry: MonitorBoardGeometry {
        MonitorBoardGeometry(boardSize: logical)
    }

    /// The tile's untrimmed cell, which is what a drag's origin is measured in.
    private var rawRect: CGRect {
        CGRect(
            origin: LayoutEngine.pixelOrigin(
                normalized: CGPoint(x: placement.x, y: placement.y), boardSize: logical
            ),
            size: geometry.pixelSize(for: placement.kind, size: placement.size)
        )
    }

    /// What the user actually sees and aims at, gutters removed.
    private var renderRect: CGRect {
        geometry.renderRect(forRawRect: rawRect)
    }

    private func makeHost() -> (host: HostView, container: NSView) {
        let host = HostView(
            frame: NSRect(origin: .zero, size: displayed),
            configuration: MonitorBoardConfiguration(widgets: [placement]),
            preview: MonitorBoardPreview(mode: .names)
        )
        host.logicalSize = logical
        let container = NSView(frame: NSRect(origin: .zero, size: displayed))
        container.addSubview(host)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        return (host, container)
    }

    /// Where a board point ends up on screen: shrunk by the preview scale, and
    /// flipped, because SwiftUI lays the board out y-down and the host is y-up.
    private func visualPoint(inBoard point: CGPoint) -> NSPoint {
        let scale = displayed.width / logical.width
        return NSPoint(x: point.x * scale, y: displayed.height - point.y * scale)
    }

    /// The inverse of the flip, in the host's own coordinates.
    private func boardPoint(fromLocal local: NSPoint) -> CGPoint {
        CGPoint(x: local.x, y: logical.height - local.y)
    }

    @Test("the board lays out at the desktop's size while the view draws small")
    func boundsCarryTheLogicalSize() {
        let (host, _) = makeHost()
        #expect(host.frame.size == displayed)
        #expect(host.bounds.size == logical)
        // The ratio the name tile reads to keep its label above a screen-point floor.
        #expect(host.frame.width / host.bounds.width == 0.25)
    }

    @Test("a point visually inside a tile lands in that tile's own rect")
    func visualPointMapsIntoTheTile() {
        let (host, container) = makeHost()
        host.setEditing(true)
        host.setPointerScope(.wholeBoard)

        let tile = renderRect
        let visual = visualPoint(inBoard: CGPoint(x: tile.midX, y: tile.midY))
        let local = host.convert(visual, from: container)
        #expect(host.acceptsPointer(atLocalPoint: local))

        let landed = boardPoint(fromLocal: local)
        #expect(tile.contains(landed), "\(visual) on screen mapped to \(landed), outside \(tile)")

        // The control: a point the user can see is off the tile must miss it.
        let beside = visualPoint(inBoard: CGPoint(x: tile.maxX + 200, y: tile.midY))
        #expect(!tile.contains(boardPoint(fromLocal: host.convert(beside, from: container))))
    }

    @Test("dragging by a visual distance moves the widget by the desktop distance")
    func dragFollowsThePointer() throws {
        let (host, container) = makeHost()
        host.setEditing(true)
        host.setPointerScope(.wholeBoard)

        let model = host.interactionModel
        // The board's SwiftUI subtree lays out into `bounds`, which is what the
        // gesture measures in; nothing lays out in a headless test, so stand in
        // for it with the same size the host hands SwiftUI.
        model.reflow(boardSize: host.bounds.size)

        var edited: MonitorBoardConfiguration?
        host.onConfigurationEdited = { edited = $0 }

        let raw = rawRect
        let grabVisual = visualPoint(inBoard: CGPoint(x: raw.midX, y: raw.midY))
        let grab = boardPoint(fromLocal: host.convert(grabVisual, from: container))
        model.beginDrag(
            placement.id,
            grabOffset: CGSize(width: grab.x - raw.minX, height: grab.y - raw.minY)
        )

        // 40 points to the right on screen is 160 points of desktop at 1:4.
        let dropVisual = NSPoint(x: grabVisual.x + 40, y: grabVisual.y)
        model.updateDrag(
            pointInBoard: boardPoint(fromLocal: host.convert(dropVisual, from: container)),
            bypassSnap: true
        )
        model.endDrag(bypassSnap: true)
        host.flushPendingEdits()

        let moved = try #require(edited?.widgets.first)
        let origin = LayoutEngine.pixelOrigin(
            normalized: CGPoint(x: moved.x, y: moved.y), boardSize: logical
        )
        #expect(abs(origin.x - (raw.minX + 160)) < 1, "landed at \(origin), wanted x \(raw.minX + 160)")
        #expect(abs(origin.y - raw.minY) < 1)
    }

    /// A desktop board has no logical size of its own, and must not acquire a
    /// scale from this.
    @Test("a board without a logical size is drawn 1:1")
    func desktopBoardIsUnscaled() {
        let host = HostView(
            frame: NSRect(origin: .zero, size: logical),
            configuration: MonitorBoardConfiguration(widgets: [placement])
        )
        let container = NSView(frame: NSRect(origin: .zero, size: logical))
        container.addSubview(host)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.size == logical)
    }
}
