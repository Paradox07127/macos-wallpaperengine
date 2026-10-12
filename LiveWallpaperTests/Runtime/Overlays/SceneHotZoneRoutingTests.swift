#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@MainActor
@Suite("Scene hot-zone routing", .serialized, .timeLimit(.minutes(1)))
struct SceneHotZoneRoutingTests {
    private func event(_ kind: SceneHotZoneEvent.Kind, _ x: CGFloat, _ y: CGFloat) -> SceneHotZoneEvent {
        SceneHotZoneEvent(kind: kind, screenLocation: CGPoint(x: x, y: y), timestamp: 1)
    }

    @Test("Interaction keeps the scene window click-through at the passive wallpaper level")
    func clickCaptureKeepsWindowPassive() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let window = VideoWallpaperWindow(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let session = SceneWallpaperSession(window: window, renderActor: WPEDisplayRenderActor(backing: .renderThread),
                                            surface: surface)
        defer { session.cleanup() }

        session.setClickCaptureEnabled(true)
        #expect(window.ignoresMouseEvents, "the wallpaper would swallow clicks meant for desktop icons")
        #expect(window.level.rawValue == Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    }

    @Test("A drawable-UV zone maps to the screen rect it covers, flipping to a bottom-left origin", arguments: [
        (CGRect(x: 100, y: 200, width: 400, height: 300), CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.2),
         CGRect(x: 200, y: 410, width: 200, height: 60)),
        (CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
         CGRect(x: -1920, y: 240, width: 960, height: 540)),
        (CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 1, height: 1),
         CGRect(x: -1920, y: -300, width: 1920, height: 1080)),
    ])
    func zoneToScreenRect(viewFrame: CGRect, zone: CGRect, expected: CGRect) {
        #expect(SceneHotZoneRouter.screenRect(forZone: zone, in: viewFrame) == expected)
    }

    @Test("A press dragged past the threshold releases as one dragged gesture")
    func dragPastThreshold() {
        var router = SceneHotZoneRouter()
        let down = router.pointerFrame(for: event(.down, 50, 50), uv: SIMD2(0.1, 0.1))
        let dragged = router.pointerFrame(for: event(.dragged, 60, 50), uv: SIMD2(0.2, 0.1))
        let up = router.pointerFrame(for: event(.up, 60, 50), uv: SIMD2(0.2, 0.1))

        #expect(down.isDown && down.gesture != 0 && !down.dragged)
        #expect(down.clickPosition == SIMD2(0.1, 0.1))
        #expect(dragged.isDown && dragged.dragged)
        #expect(!up.isDown)
        #expect(up.gesture == down.gesture)
        #expect(up.dragged, "the scene would synthesize a click for a drag")
        #expect(up.position == SIMD2(0.2, 0.1))
    }

    @Test("A press released in place, or nudged under the threshold, is not dragged; the next press starts fresh")
    func clickInPlace() {
        var router = SceneHotZoneRouter()
        let first = router.pointerFrame(for: event(.down, 50, 50), uv: SIMD2(0.1, 0.1))
        _ = router.pointerFrame(for: event(.dragged, 53, 50), uv: SIMD2(0.1, 0.1))
        let up = router.pointerFrame(for: event(.up, 53, 50), uv: SIMD2(0.1, 0.1))
        #expect(!up.dragged)
        #expect(up.gesture == first.gesture)

        _ = router.pointerFrame(for: event(.down, 50, 50), uv: SIMD2(0.1, 0.1))
        _ = router.pointerFrame(for: event(.dragged, 90, 50), uv: SIMD2(0.3, 0.1))
        _ = router.pointerFrame(for: event(.up, 90, 50), uv: SIMD2(0.3, 0.1))
        let next = router.pointerFrame(for: event(.down, 50, 50), uv: SIMD2(0.1, 0.1))
        #expect(!next.dragged, "a drag would leak into the next press and swallow its click")
        #expect(next.gesture != first.gesture)
    }

    @Test("Right presses set and clear the right button and its click position")
    func rightPress() {
        var router = SceneHotZoneRouter()
        let down = router.pointerFrame(for: event(.rightDown, 50, 50), uv: SIMD2(0.3, 0.4))
        let up = router.pointerFrame(for: event(.rightUp, 50, 50), uv: SIMD2(0.3, 0.4))
        #expect(down.isRightDown && !down.isDown)
        #expect(down.clickPosition == SIMD2(0.3, 0.4))
        #expect(!up.isRightDown)
    }

    @Test("Routed presses become mailbox edges in view UV; moves only move the pointer")
    func routeIntoMailbox() {
        let mailbox = WPEPointerMailbox()
        let viewFrame = CGRect(x: -200, y: 0, width: 200, height: 100)
        mailbox.publishGeometry(.init(viewFrameInScreen: viewFrame))
        mailbox.setClickCaptureEnabled(true)
        var router = SceneHotZoneRouter()

        let movePublished = router.route(event(.moved, -150, 25), to: mailbox, viewFrame: viewFrame)
        #expect(!movePublished)
        #expect(mailbox.read().pointerFrame.position == SIMD2(0.25, 0.75))
        let downPublished = router.route(event(.down, -100, 50), to: mailbox, viewFrame: viewFrame)
        // Outside the view: clamped, as the native view reports it.
        let upPublished = router.route(event(.up, 50, 150), to: mailbox, viewFrame: viewFrame)
        #expect(downPublished && upPublished)

        let edges = mailbox.takeButtonEvents(through: mailbox.read().buttonCursor).edges
        #expect(edges.map(\.frame.isDown) == [true, false])
        #expect(edges.first?.frame.position == SIMD2(0.5, 0.5))
        #expect(edges.last?.frame.position == SIMD2(1, 0))
        #expect(edges.map(\.fromDesktop) == [false, false])
    }
}
#endif
