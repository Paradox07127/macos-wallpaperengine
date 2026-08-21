import AppKit
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

// MARK: - Fixture board

/// 800×600 with `referenceWidth` 0, so the geometry scale is exactly 1 and every
/// rect below is arithmetic on Apple's own cell pitch (194×206, inset 12/18).
private enum PointerBoard {
    static let size = CGSize(width: 800, height: 600)

    /// Now Playing, small (2×1 cells) at the board origin.
    /// raw (0, 0, 388, 206) → render (12, 18, 364, 170).
    static let nowPlayingRenderCenter = CGPoint(x: 194, y: 103)
    /// CPU, small (1×1) at normalized (0.5, 0.5).
    /// raw (400, 300, 194, 206) → render (412, 318, 170, 170).
    static let cpuRenderCenter = CGPoint(x: 497, y: 403)
    /// Inside the board, inside neither widget.
    static let emptySpot = CGPoint(x: 700, y: 550)

    static func configuration(mouseInteractionEnabled: Bool = false) -> MonitorBoardConfiguration {
        var board = MonitorBoardConfiguration(widgets: [
            MonitorWidgetPlacement(kind: .nowPlaying, size: .small, x: 0, y: 0),
            MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.5, y: 0.5),
        ])
        board.mouseInteractionEnabled = mouseInteractionEnabled
        return board
    }

    /// SwiftUI lays the board out y-down; the unflipped host view is y-up.
    static func local(_ boardPoint: CGPoint) -> NSPoint {
        NSPoint(x: boardPoint.x, y: size.height - boardPoint.y)
    }

    @MainActor
    static func makeHost(mouseInteractionEnabled: Bool = false) -> HostView {
        let host = HostView(
            frame: NSRect(origin: .zero, size: size),
            configuration: configuration(mouseInteractionEnabled: mouseInteractionEnabled)
        )
        // A superview so `hitTest` exercises its real coordinate conversion.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(host)
        return host
    }
}

// MARK: - Pointer scope

@Suite("Monitor board pointer scope")
struct BoardPointerScopeTests {

    @MainActor
    @Test("widgetsOnly accepts the pointer only inside a widget that asked for it")
    func widgetsOnlyGate() {
        let host = PointerBoard.makeHost()
        host.setPointerScope(.widgetsOnly)

        #expect(host.acceptsPointer(atLocalPoint: PointerBoard.local(PointerBoard.nowPlayingRenderCenter)))
        // The desktop below has to keep every click that is not on that tile —
        // this is the whole point of filtering in AppKit rather than SwiftUI.
        #expect(!host.acceptsPointer(atLocalPoint: PointerBoard.local(PointerBoard.emptySpot)))
        // CPU never asks for the pointer, so its rect is not a hit region.
        #expect(!host.acceptsPointer(atLocalPoint: PointerBoard.local(PointerBoard.cpuRenderCenter)))
    }

    @MainActor
    @Test("none rejects every point and wholeBoard accepts every point")
    func scopeExtremes() {
        let host = PointerBoard.makeHost()

        host.setPointerScope(.none)
        for point in [PointerBoard.nowPlayingRenderCenter, PointerBoard.cpuRenderCenter, PointerBoard.emptySpot] {
            #expect(!host.acceptsPointer(atLocalPoint: PointerBoard.local(point)))
        }

        host.setPointerScope(.wholeBoard)
        for point in [PointerBoard.nowPlayingRenderCenter, PointerBoard.cpuRenderCenter, PointerBoard.emptySpot] {
            #expect(host.acceptsPointer(atLocalPoint: PointerBoard.local(point)))
        }
    }

    /// The gate above only matters if `hitTest` actually consults it: a nil from
    /// here is what lets the event reach the window underneath.
    @MainActor
    @Test("hitTest returns nil wherever the scope declines the pointer")
    func hitTestHonoursTheGate() {
        let host = PointerBoard.makeHost()

        host.setPointerScope(.widgetsOnly)
        #expect(host.hitTest(PointerBoard.local(PointerBoard.emptySpot)) == nil)
        #expect(host.hitTest(PointerBoard.local(PointerBoard.cpuRenderCenter)) == nil)

        host.setPointerScope(.none)
        #expect(host.hitTest(PointerBoard.local(PointerBoard.nowPlayingRenderCenter)) == nil)
    }

    /// Guards the y-flip: the board's top-left tile must not answer to a point
    /// mirrored into the bottom-left of the window.
    @MainActor
    @Test("the hit region is not vertically mirrored")
    func hitRegionOrientation() {
        let host = PointerBoard.makeHost()
        host.setPointerScope(.widgetsOnly)
        let center = PointerBoard.nowPlayingRenderCenter
        let mirrored = NSPoint(x: center.x, y: center.y)

        #expect(host.acceptsPointer(atLocalPoint: PointerBoard.local(center)))
        #expect(!host.acceptsPointer(atLocalPoint: mirrored))
    }

    @MainActor
    @Test("scope resolution: editing and Mouse Interaction widen it to the whole board")
    func scopeResolution() {
        let withPointerWidget = PointerBoard.configuration()
        #expect(HostView.pointerScope(for: withPointerWidget, isEditing: false) == .widgetsOnly)
        #expect(HostView.pointerScope(for: withPointerWidget, isEditing: true) == .wholeBoard)

        var optedIn = withPointerWidget
        optedIn.mouseInteractionEnabled = true
        #expect(HostView.pointerScope(for: optedIn, isEditing: false) == .wholeBoard)

        let monitorOnly = MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .cpu)])
        #expect(HostView.pointerScope(for: monitorOnly, isEditing: false) == .none)

        // Now Playing with both pointer affordances off asks for nothing.
        var inert = NowPlayingOptions()
        inert.showControls = false
        inert.seekOnProgressDrag = false
        let inertBoard = MonitorBoardConfiguration(widgets: [
            MonitorWidgetPlacement(kind: .nowPlaying, options: inert.applied(to: [:])),
        ])
        #expect(HostView.pointerScope(for: inertBoard, isEditing: false) == .none)
    }
}

// MARK: - Catalog scope

@Suite("Monitor board catalog scope")
struct BoardCatalogScopeTests {

    @MainActor
    @Test("each overlay module offers only the kinds it owns")
    func moduleOwnedKinds() {
        let monitor = MonitorOverlayModule.monitor.ownedKinds
        let music = MonitorOverlayModule.music.ownedKinds

        #expect(!monitor.contains(.nowPlaying))
        #expect(monitor.contains(.cpu))
        #expect(music == [.nowPlaying])
        // Between them they still cover the catalog — no kind becomes unaddable.
        #expect(Set(monitor + music) == Set(MonitorWidgetKind.allCases))
    }

    @MainActor
    @Test("a board refuses a kind its module does not own")
    func addWidgetRespectsAllowedKinds() {
        let model = InteractionModel(configuration: MonitorBoardConfiguration(widgets: []))
        model.allowedKinds = MonitorOverlayModule.monitor.ownedKinds
        model.reflow(boardSize: CGSize(width: 800, height: 600))
        model.setEditing(true)

        // Adding Now Playing to a Monitor host used to appear for 250 ms and
        // then vanish, because the write-back filters it out again.
        #expect(!model.addWidget(kind: .nowPlaying))
        #expect(model.placements.isEmpty)

        #expect(model.addWidget(kind: .cpu))
        #expect(model.placements.map(\.kind) == [.cpu])
    }

    @MainActor
    @Test("the inspector preview keeps the whole catalog")
    func previewKeepsEveryKind() {
        let model = InteractionModel(configuration: MonitorBoardConfiguration(widgets: []))
        #expect(model.allowedKinds == MonitorWidgetKind.allCases)
    }
}
