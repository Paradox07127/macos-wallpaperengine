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

    @Test("Scene cleanup stops the surface pointer publisher")
    func cleanupStopsPointerPublisher() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let window = VideoWallpaperWindow(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        window.contentView = surface.mtkView
        let actor = WPEDisplayRenderActor(backing: .main)
        surface.attach(client: WPERenderSurfaceClientShim(renderActor: actor, backing: .main))
        let session = SceneWallpaperSession(window: window, renderActor: actor, surface: surface)
        let geometry = WPEPointerPublisher.geometry(of: surface.mtkView)
        try #require(geometry != .none)
        let center = CGPoint(x: geometry.viewFrameInScreen.midX, y: geometry.viewFrameInScreen.midY)

        session.cleanup()

        var republished = true
        for _ in 0 ..< 100 {
            surface.mailbox.publishGeometry(.none)
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
            try await Task.sleep(for: .milliseconds(20))
            republished = surface.mailbox.sample(screenLocation: center).isInsideView
            if !republished {
                break
            }
        }
        #expect(!republished, "a torn-down scene would keep its geometry observers and mouse monitors")
    }

    @Test("Moving a span canvas moves the hot-zone panels with it")
    func spanViewportMoveRelaysOutPanels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let window = VideoWallpaperWindow(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let session = SceneWallpaperSession(window: window, renderActor: WPEDisplayRenderActor(backing: .renderThread),
                                            surface: surface)
        defer { session.cleanup() }
        let zone = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        session.setClickCaptureEnabled(true)
        surface.mailbox.publishInteractiveZones([zone])
        let first = CGRect(x: 1000, y: 2000, width: 400, height: 200)
        let moved = CGRect(x: 3000, y: 4000, width: 800, height: 400)
        session.updateSpanViewport(first, density: 1, interactiveFrames: [first])
        session.updateSpanViewport(moved, density: 1, interactiveFrames: [moved])
        let expected = TestHostWindowParking.parkedFrame(SceneHotZoneRouter.screenRect(forZone: zone, in: moved))
        #expect(NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.frame == expected },
                "the panel would stay at the previous canvas and swallow desktop clicks there")
    }

    @Test("A mirrored canvas gets hot-zone panels on every mirrored screen, not just the largest one")
    func mirroredViewportPlacesPanelsOnEachScreen() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let window = VideoWallpaperWindow(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let session = SceneWallpaperSession(window: window, renderActor: WPEDisplayRenderActor(backing: .renderThread),
                                            surface: surface)
        defer { session.cleanup() }
        let zone = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        session.setClickCaptureEnabled(true)
        surface.mailbox.publishInteractiveZones([zone])
        let canvas = CGRect(x: 1000, y: 2000, width: 800, height: 400)
        let small = CGRect(x: 3000, y: 4000, width: 400, height: 200)
        session.updateSpanViewport(canvas, density: 1, interactiveFrames: [canvas, small], mirrorFrames: [canvas, small])
        for frame in [canvas, small] {
            let expected = TestHostWindowParking.parkedFrame(SceneHotZoneRouter.screenRect(forZone: zone, in: frame))
            #expect(NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.frame == expected },
                    "a mirrored screen would have no panel, so its clickable objects would never receive a press")
        }
    }

    @Test("Each mirrored screen gets its own copy of every zone, scaled to that screen and clipped to the clip frames")
    func mirroredZonesProjectPerScreen() {
        let zone = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let large = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let small = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let onLarge = CGRect(x: 0, y: 720, width: 1280, height: 720)
        let onSmall = CGRect(x: 2560, y: 540, width: 960, height: 540)
        #expect(SceneWallpaperSession.hotZoneScreenRects([zone], viewFrame: large, mirrorFrames: [large, small], clips: [large, small])
            == [onLarge, onSmall], "the smaller screen would get no panel or one sized for the larger screen")
        #expect(SceneWallpaperSession.hotZoneScreenRects([zone], viewFrame: large, mirrorFrames: [large, small], clips: [small])
            == [onSmall], "a screen with clicks off would still swallow presses")
        #expect(SceneWallpaperSession.hotZoneScreenRects([zone], viewFrame: large, mirrorFrames: [], clips: nil) == [onLarge])
    }

    @Test("A hot-zone press on a mirrored screen resolves against that screen; elsewhere against the view")
    func mirroredEventViewFrame() {
        let large = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let small = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        #expect(SceneWallpaperSession.hotZoneViewFrame(at: CGPoint(x: 3000, y: 100), viewFrame: large, mirrorFrames: [large, small])
            == small, "a release dragged off the smaller screen would clamp against the larger one")
        #expect(SceneWallpaperSession.hotZoneViewFrame(at: CGPoint(x: 9000, y: 100), viewFrame: large, mirrorFrames: [large, small])
            == large)
        #expect(SceneWallpaperSession.hotZoneViewFrame(at: CGPoint(x: 3000, y: 100), viewFrame: large, mirrorFrames: []) == large)
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

    private func sceneView() -> WPEInteractiveMTKView {
        WPEInteractiveMTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), device: nil)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    @Test("A touch pan on the scene view writes the same pointer frames as a mouse press, drag and release")
    func sceneViewTouchPanMatchesMouse() throws {
        let mouseView = sceneView()
        let touchView = sceneView()
        var mouseFrames: [WPEPointerFrame] = []
        var touchFrames: [WPEPointerFrame] = []
        mouseView.onPointerFrameChange = { mouseFrames.append($0) }
        touchView.onPointerFrameChange = { touchFrames.append($0) }
        mouseView.clickCaptureEnabled = true
        touchView.clickCaptureEnabled = true
        let start = CGPoint(x: 50, y: 25)
        let end = CGPoint(x: 150, y: 75)

        try mouseView.mouseDown(with: mouseEvent(.leftMouseDown, at: start))
        try mouseView.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end))
        try mouseView.mouseUp(with: mouseEvent(.leftMouseUp, at: end))
        touchView.touchPan(.began, atWindowLocation: start)
        #expect(touchView.pointerFrame.isDown, "a touch press would not hold the scene's button down")
        touchView.touchPan(.changed, atWindowLocation: end)
        touchView.touchPan(.ended, atWindowLocation: end)

        let ungestured = { (frames: [WPEPointerFrame]) in
            frames.map { frame in
                var copy = frame
                copy.gesture = 0
                return copy
            }
        }
        #expect(ungestured(touchFrames) == ungestured(mouseFrames), "a touch drag would land somewhere a mouse drag does not")
        #expect(touchFrames.map(\.position) == [SIMD2(0.25, 0.75), SIMD2(0.75, 0.25), SIMD2(0.75, 0.25)])
        #expect(touchFrames.first?.gesture != 0 && touchFrames.first?.gesture == touchFrames.last?.gesture)
        #expect(touchView.pointerIsInsideView == mouseView.pointerIsInsideView)
    }

    @Test("With Interaction off the scene view's touch pan neither begins nor moves the pointer")
    func sceneViewTouchPanRespectsInteraction() throws {
        let view = sceneView()
        view.touchPan(.began, atWindowLocation: CGPoint(x: 50, y: 25))
        view.touchPan(.changed, atWindowLocation: CGPoint(x: 150, y: 75))
        #expect(view.pointerFrame == .neutral, "a touch would reach a scene whose Interaction is off")

        guard #available(macOS 27, *) else { return }
        let pan = try #require(view.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }.first)
        #expect(pan.maximumNumberOfTouches == 1)
        let click = try mouseEvent(.leftMouseDown, at: .zero)
        #expect(!view.gestureRecognizer(pan, shouldAttemptToRecognizeWith: click), "the pan would compete with mouse drags")
        #expect(!view.gestureRecognizerShouldBegin(pan), "the pan would swallow touches while Interaction is off")
        view.clickCaptureEnabled = true
        #expect(view.gestureRecognizerShouldBegin(pan))
    }

    @Test("Turning Interaction off mid-press releases the scene's button for a mouse and a touch")
    func sceneViewInteractionOffReleasesPress() throws {
        let mouseView = sceneView()
        let touchView = sceneView()
        var mouseFrames: [WPEPointerFrame] = []
        var touchFrames: [WPEPointerFrame] = []
        mouseView.onPointerFrameChange = { mouseFrames.append($0) }
        touchView.onPointerFrameChange = { touchFrames.append($0) }
        mouseView.clickCaptureEnabled = true
        touchView.clickCaptureEnabled = true

        try mouseView.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 25)))
        touchView.touchPan(.began, atWindowLocation: CGPoint(x: 50, y: 25))
        mouseView.clickCaptureEnabled = false
        touchView.clickCaptureEnabled = false

        for (view, frames) in [(mouseView, mouseFrames), (touchView, touchFrames)] {
            #expect(!view.pointerFrame.isDown, "the scene would keep the button held after Interaction turned off")
            #expect(frames.map(\.isDown) == [true, false], "the scene would never hear the release")
            #expect(frames.last?.gesture == frames.first?.gesture && frames.last?.position == SIMD2(0.25, 0.75))
        }
    }

    @Test("Turning Interaction off with both buttons held releases them in one pointer frame")
    func sceneViewInteractionOffReleasesRightPress() throws {
        let view = sceneView()
        var frames: [WPEPointerFrame] = []
        view.onPointerFrameChange = { frames.append($0) }
        view.clickCaptureEnabled = true

        try view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 50, y: 25)))
        try view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: CGPoint(x: 50, y: 25)))
        view.clickCaptureEnabled = false

        #expect(!view.pointerFrame.isRightDown, "the mailbox would keep native clicks suppressed after Interaction turned off")
        #expect(!view.pointerFrame.isDown)
        #expect(frames.map(\.isRightDown) == [false, true, false], "the release would be split across frames or never heard")
    }

    @Test("A scene-view touch drag reaches the pointer publisher only while its monitors are installed")
    func sceneViewTouchDragFeedsPublisher() {
        let view = sceneView()
        view.clickCaptureEnabled = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = view
        let mailbox = WPEPointerMailbox()
        let publisher = WPEPointerPublisher(mailbox: mailbox, view: view, throttleFPS: 0)
        publisher.start()
        defer { publisher.stop() }

        view.touchPan(.began, atWindowLocation: CGPoint(x: 50, y: 25))
        #expect(mailbox.read().pointerSample.position == SIMD2(0.25, 0.75), "the follow pointer would ignore the finger")
        view.touchPan(.changed, atWindowLocation: CGPoint(x: 150, y: 75))
        #expect(mailbox.read().pointerSample.position == SIMD2(0.75, 0.25))

        publisher.setMouseMonitoringEnabled(false)
        #expect(view.onTouchDragLocation == nil, "a gated-off publisher would still feed touches")
        publisher.setMouseMonitoringEnabled(true)
        #expect(view.onTouchDragLocation != nil)
        publisher.stop()
        #expect(view.onTouchDragLocation == nil)
    }
}
#endif
