import AppKit
import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The host must carry no transform of its own: a scale expressed outside its
/// `NSHostingView` never reaches the nested SwiftUI tree, which keeps deriving pointer
/// locations from the outer, unscaled tree.
@Suite("Monitor inspector board preview scale")
@MainActor
struct BoardPreviewScaleTests {
    private let logical = CGSize(width: 1600, height: 900)
    private let displayed = CGSize(width: 400, height: 225)
    private let placement = MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.25, y: 0.25)

    private var scale: CGFloat {
        displayed.width / logical.width
    }

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
        NSPoint(x: point.x * scale, y: displayed.height - point.y * scale)
    }

    /// The board point for a point in the host's own coordinates: the scale lives inside the
    /// host's SwiftUI tree, so only the flip and one division are needed — no AppKit transform.
    private func boardPoint(fromLocal local: NSPoint) -> CGPoint {
        CGPoint(x: local.x / scale, y: (displayed.height - local.y) / scale)
    }

    @Test("the host carries no AppKit transform of its own")
    func hostGeometryIsUnscaled() {
        let (host, container) = makeHost()
        #expect(host.frame.size == displayed)
        #expect(
            host.bounds.size == displayed,
            "a bounds/frame mismatch is invisible to the nested NSHostingView"
        )
        let probe = NSPoint(x: 137, y: 88)
        #expect(host.convert(probe, from: container) == probe)
    }

    @Test("SwiftUI owns the shrinking, and only for a preview")
    func swiftUIOwnsTheScale() {
        #expect(MonitorBoardRootContainer.previewScale(available: displayed, logical: logical) == 0.25)
        // A desktop board has no logical size and must not acquire a scale.
        #expect(MonitorBoardRootContainer.previewScale(available: displayed, logical: nil) == 1)
        #expect(MonitorBoardRootContainer.previewScale(available: .zero, logical: logical) == 1)
        #expect(MonitorBoardRootContainer.previewScale(available: displayed, logical: .zero) == 1)
        #expect(MonitorBoardRootContainer.previewScale(available: logical, logical: logical) == 1)
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
        // Nothing lays out in a headless test, so stand in for the logical size the gesture
        // measures in.
        model.reflow(boardSize: logical)

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
