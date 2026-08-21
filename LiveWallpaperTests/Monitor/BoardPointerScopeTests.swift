import AppKit
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

// MARK: - Monitor board

/// 800×600 with `referenceWidth` 0, so the geometry scale is exactly 1 and every
/// rect below is arithmetic on Apple's own cell pitch (194×206, inset 12/18).
private enum PointerBoard {
    static let size = CGSize(width: 800, height: 600)

    /// CPU, small (1×1) at normalized (0.5, 0.5).
    /// raw (400, 300, 194, 206) → render (412, 318, 170, 170).
    static let cpuRenderCenter = CGPoint(x: 497, y: 403)
    /// Inside the board, outside every widget.
    static let emptySpot = CGPoint(x: 700, y: 550)

    static func configuration(mouseInteractionEnabled: Bool = false) -> MonitorBoardConfiguration {
        var board = MonitorBoardConfiguration(widgets: [
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

@Suite("Monitor board pointer scope")
struct BoardPointerScopeTests {

    /// Board tiles are display-only. The Now Playing layer was the only thing
    /// that ever claimed the pointer on its own, and it has its own host now.
    @MainActor
    @Test("a passive board takes no pointer anywhere")
    func passiveBoardTakesNothing() {
        let host = PointerBoard.makeHost()
        #expect(host.pointerScope == .none)
        for point in [PointerBoard.cpuRenderCenter, PointerBoard.emptySpot] {
            #expect(!host.acceptsPointer(atLocalPoint: PointerBoard.local(point)))
        }
    }

    @MainActor
    @Test("wholeBoard accepts every point and widgetsOnly accepts none")
    func scopeExtremes() {
        let host = PointerBoard.makeHost()

        host.setPointerScope(.wholeBoard)
        for point in [PointerBoard.cpuRenderCenter, PointerBoard.emptySpot] {
            #expect(host.acceptsPointer(atLocalPoint: PointerBoard.local(point)))
        }

        // The board never resolves to this scope any more; if something forced
        // it, the board still has to refuse rather than swallow desktop clicks.
        host.setPointerScope(.widgetsOnly)
        #expect(!host.acceptsPointer(atLocalPoint: PointerBoard.local(PointerBoard.cpuRenderCenter)))
    }

    @MainActor
    @Test("editing and Mouse Interaction are the only ways in")
    func scopeResolution() {
        let passive = PointerBoard.configuration()
        #expect(HostView.pointerScope(for: passive, isEditing: false) == .none)
        #expect(HostView.pointerScope(for: passive, isEditing: true) == .wholeBoard)

        let optedIn = PointerBoard.configuration(mouseInteractionEnabled: true)
        #expect(HostView.pointerScope(for: optedIn, isEditing: false) == .wholeBoard)
    }
}

// MARK: - Music layer

@Suite("Music layer pointer gate")
struct MusicLayerPointerGateTests {
    private static let size = CGSize(width: 800, height: 600)
    /// Medium (3×1 cells) at the origin: raw (0, 0, 582, 206) → render
    /// (12, 18, 558, 170), so its centre is (291, 103) in board coordinates.
    private static let layerCenter = CGPoint(x: 291, y: 103)
    private static let outside = CGPoint(x: 700, y: 550)

    private static func local(_ boardPoint: CGPoint) -> NSPoint {
        NSPoint(x: boardPoint.x, y: size.height - boardPoint.y)
    }

    @MainActor
    private func makeHost(
        options: NowPlayingOptions = NowPlayingOptions(),
        phase: MonitorNowPlayingPhase? = .playing
    ) -> MusicHostView {
        let host = MusicHostView(
            frame: NSRect(origin: .zero, size: Self.size),
            configuration: MusicOverlayConfiguration(
                enabled: true, size: .medium, x: 0, y: 0, options: options.applied(to: [:])
            )
        )
        if let phase {
            var snapshot = MonitorSnapshot()
            snapshot.nowPlaying = MonitorNowPlayingState(
                phase: phase,
                title: phase.hasTrack ? "Weightless Horizon" : ""
            )
            host.push(snapshot)
        }
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.addSubview(host)
        return host
    }

    @MainActor
    @Test("the transport controls take the pointer, the rest of the display does not")
    func controlsTakeOnlyTheirOwnRect() {
        let host = makeHost()
        #expect(host.wantsPointer)
        #expect(host.acceptsPointer(atLocalPoint: Self.local(Self.layerCenter)))
        // Everything else has to fall through to the desktop.
        #expect(!host.acceptsPointer(atLocalPoint: Self.local(Self.outside)))
    }

    /// An invisible layer that still eats desktop clicks reads as the desktop
    /// being broken, and there is nothing on screen to explain it.
    @MainActor
    @Test("a layer with nothing to draw holds no hit region")
    func noTrackReleasesThePointer() {
        for phase in [MonitorNowPlayingPhase.noPlayer, .awaitingFirstEvent] {
            let host = makeHost(phase: phase)
            #expect(!host.wantsPointer, "\(phase) draws nothing")
            #expect(!host.acceptsPointer(atLocalPoint: Self.local(Self.layerCenter)))
        }

        // Never pushed a snapshot at all: same answer, no crash.
        let silent = makeHost(phase: nil)
        #expect(!silent.acceptsPointer(atLocalPoint: Self.local(Self.layerCenter)))

        // A paused track is still on screen and still controllable.
        let paused = makeHost(phase: .paused)
        #expect(paused.acceptsPointer(atLocalPoint: Self.local(Self.layerCenter)))
    }

    @MainActor
    @Test("a layer with both pointer affordances off asks for nothing")
    func inertLayerTakesNothing() {
        var inert = NowPlayingOptions()
        inert.showControls = false
        inert.seekOnProgressDrag = false
        let host = makeHost(options: inert)

        #expect(!host.wantsPointer)
        #expect(!host.acceptsPointer(atLocalPoint: Self.local(Self.layerCenter)))
    }

    @MainActor
    @Test("moving the layer moves its hit region with it")
    func hitRegionFollowsTheConfiguration() {
        let host = makeHost()
        #expect(host.acceptsPointer(atLocalPoint: Self.local(Self.layerCenter)))

        host.apply(configuration: MusicOverlayConfiguration(
            enabled: true, size: .medium, x: 0.5, y: 0.5
        ))
        #expect(!host.acceptsPointer(atLocalPoint: Self.local(Self.layerCenter)))
        #expect(host.acceptsPointer(atLocalPoint: Self.local(CGPoint(x: 400 + 291, y: 300 + 103))))
    }
}
