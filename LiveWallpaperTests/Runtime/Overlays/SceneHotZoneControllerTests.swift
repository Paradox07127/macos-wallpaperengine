#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
struct SceneHotZoneControllerTests {
    @MainActor
    private final class Recorder {
        var events: [SceneHotZoneEvent] = []
    }

    private let zoneA = CGRect(x: 100, y: 200, width: 300, height: 150)
    private let zoneB = CGRect(x: 600, y: 50, width: 80, height: 40)

    private func makeController() -> (SceneHotZoneController, Recorder) {
        let recorder = Recorder()
        let controller = SceneHotZoneController { recorder.events.append($0) }
        return (controller, recorder)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in panel: NSPanel) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 42,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func visiblePanels(_ controller: SceneHotZoneController) -> [NSPanel] {
        controller.panelsForTesting.filter(\.isVisible)
    }

    @Test func panelCountFollowsZones() {
        let (controller, _) = makeController()
        defer { controller.tearDown() }

        controller.update(zones: [zoneA, zoneB, CGRect(x: 0, y: 0, width: 0.5, height: 50)])
        #expect(visiblePanels(controller).map(TestHostWindowParking.logicalFrame) == [zoneA, zoneB])
        for panel in controller.panelsForTesting {
            #expect(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) }, "panel would be on a real display")
        }

        controller.update(zones: [zoneB])
        #expect(controller.panelsForTesting.count == 1)
        #expect(visiblePanels(controller).map(TestHostWindowParking.logicalFrame) == [zoneB])

        controller.update(zones: [])
        #expect(visiblePanels(controller).isEmpty)
    }

    @Test func panelSitsJustAboveDesktopIconsWithoutActivating() throws {
        let (controller, _) = makeController()
        defer { controller.tearDown() }
        controller.update(zones: [zoneA])
        let panel = try #require(controller.panelsForTesting.first)

        #expect(panel.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        #expect(panel.ignoresMouseEvents == false)
        #expect(panel.hidesOnDeactivate == false)
        #expect(panel.canHide == false)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.sharingType == WallpaperCapturePolicy.windowSharingType)
        #expect(panel.animationBehavior == .none)
    }

    @Test func pressedPanelHoldsItsFrameUntilRelease() throws {
        let (controller, _) = makeController()
        defer { controller.tearDown() }
        controller.update(zones: [zoneA])
        let panel = try #require(controller.panelsForTesting.first)
        let view = try #require(panel.contentView)

        try view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 5, y: 5), in: panel))
        #expect(controller.isPressed)
        controller.update(zones: [zoneB])
        #expect(TestHostWindowParking.logicalFrame(panel) == zoneA)
        #expect(panel.isVisible)

        try view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 5, y: 5), in: panel))
        #expect(!controller.isPressed)
        #expect(TestHostWindowParking.logicalFrame(panel) == zoneB)
        #expect(visiblePanels(controller).map(TestHostWindowParking.logicalFrame) == [zoneB])
    }

    @Test func disablingWhilePressedSynthesizesRelease() throws {
        let (controller, recorder) = makeController()
        defer { controller.tearDown() }
        controller.update(zones: [zoneA])
        let panel = try #require(controller.panelsForTesting.first)
        let view = try #require(panel.contentView)

        try view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: CGPoint(x: 10, y: 20), in: panel))
        controller.isEnabled = false

        #expect(!controller.isPressed)
        #expect(visiblePanels(controller).isEmpty)
        let last = try #require(recorder.events.last)
        #expect(last.kind == .rightUp)
        #expect(last.screenLocation == CGPoint(x: zoneA.minX + 10, y: zoneA.minY + 20))

        controller.isEnabled = true
        #expect(visiblePanels(controller).map(TestHostWindowParking.logicalFrame) == [zoneA])
    }

    @Test func eventsCarryKindAndScreenLocation() throws {
        let (controller, recorder) = makeController()
        defer { controller.tearDown() }
        controller.update(zones: [zoneA, zoneB])
        let panel = try #require(controller.panelsForTesting.last)
        let view = try #require(panel.contentView)
        let point = CGPoint(x: 7, y: 3)

        try view.mouseMoved(with: mouseEvent(.mouseMoved, at: point, in: panel))
        try view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: panel))
        try view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: point, in: panel))
        try view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: panel))
        try view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: point, in: panel))
        try view.rightMouseUp(with: mouseEvent(.rightMouseUp, at: point, in: panel))

        let expected = CGPoint(x: zoneB.minX + point.x, y: zoneB.minY + point.y)
        #expect(recorder.events == [SceneHotZoneEvent.Kind.moved, .down, .dragged, .up, .rightDown, .rightUp].map {
            SceneHotZoneEvent(kind: $0, screenLocation: expected, timestamp: 42)
        })
    }
}
#endif
