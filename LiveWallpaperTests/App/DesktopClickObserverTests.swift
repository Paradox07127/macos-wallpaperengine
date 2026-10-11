#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import Testing

@MainActor
private final class RecordingReceiver: SceneDesktopClickReceiving {
    struct Edge: Equatable {
        let location: CGPoint
        let pressLocation: CGPoint
        let isDown: Bool
        let gesture: UInt64
        let dragged: Bool
    }

    var acceptsDesktopClicks = true
    private(set) var edges: [Edge] = []

    func publishDesktopButton(location: CGPoint, pressLocation: CGPoint, isDown: Bool, gesture: UInt64, dragged: Bool) {
        edges.append(Edge(location: location, pressLocation: pressLocation, isDown: isDown,
                          gesture: gesture, dragged: dragged))
    }
}

@MainActor
@Suite("Desktop clicks are observed, judged and routed to the scene under them")
struct DesktopClickObserverTests {
    private static let left = CGRect(x: 0, y: 0, width: 100, height: 100)
    private static let right = CGRect(x: 100, y: 0, width: 100, height: 100)
    private let onDesktop: @MainActor (CGPoint) -> Bool = { _ in true }

    private func makeObserver(_ targets: [(CGRect, RecordingReceiver)]) -> DesktopClickObserver {
        DesktopClickObserver(targets: {
            targets.map { DesktopClickTarget(frame: $0.0, receiver: $0.1) }
        })
    }

    @Test("A desktop press and release reach the receiver as one gesture")
    func pressAndRelease() {
        let receiver = RecordingReceiver()
        let observer = makeObserver([(Self.left, receiver)])
        observer.handle(.down, at: CGPoint(x: 10, y: 20), isDesktop: onDesktop)
        observer.handle(.up, at: CGPoint(x: 11, y: 21), isDesktop: onDesktop)

        #expect(receiver.edges.map(\.isDown) == [true, false])
        guard receiver.edges.count == 2 else { return }
        let (down, up) = (receiver.edges[0], receiver.edges[1])
        #expect(down.gesture != 0)
        #expect(up.gesture == down.gesture)
        #expect(up.pressLocation == CGPoint(x: 10, y: 20))
        #expect(up.location == CGPoint(x: 11, y: 21))
        #expect(!up.dragged)
    }

    @Test("A press that is not on the desktop starts nothing, and its release is ignored")
    func offDesktopPressIgnored() {
        let receiver = RecordingReceiver()
        let observer = makeObserver([(Self.left, receiver)])
        observer.handle(.down, at: CGPoint(x: 10, y: 20), isDesktop: { _ in false })
        observer.handle(.up, at: CGPoint(x: 10, y: 20), isDesktop: onDesktop)

        #expect(receiver.edges.isEmpty)
    }

    @Test("Moving past the drag threshold marks the release as dragged", arguments: [
        (CGFloat(10), true), (CGFloat(2), false),
    ])
    func dragThreshold(distance: CGFloat, expectDragged: Bool) {
        let receiver = RecordingReceiver()
        let observer = makeObserver([(Self.left, receiver)])
        observer.handle(.down, at: CGPoint(x: 50, y: 50), isDesktop: onDesktop)
        observer.handle(.dragged, at: CGPoint(x: 50 + distance, y: 50), isDesktop: onDesktop)
        observer.handle(.up, at: CGPoint(x: 50 + distance, y: 50), isDesktop: onDesktop)

        #expect(receiver.edges.count == 2, "a drag must not publish an extra edge")
        #expect(receiver.edges.last?.dragged == expectDragged)
    }

    @Test("The release goes to the screen that took the press, even when it lands on another screen")
    func routesByPressScreen() {
        let first = RecordingReceiver()
        let second = RecordingReceiver()
        let observer = makeObserver([(Self.left, first), (Self.right, second)])
        observer.handle(.down, at: CGPoint(x: 150, y: 50), isDesktop: onDesktop)
        observer.handle(.up, at: CGPoint(x: 50, y: 50), isDesktop: onDesktop)

        #expect(first.edges.isEmpty)
        #expect(second.edges.map(\.isDown) == [true, false])
        #expect(second.edges.last?.location == CGPoint(x: 50, y: 50))
    }

    @Test("A receiver that does not accept desktop clicks gets nothing")
    func nonAcceptingReceiverSkipped() {
        let receiver = RecordingReceiver()
        receiver.acceptsDesktopClicks = false
        let observer = makeObserver([(Self.left, receiver)])
        observer.handle(.down, at: CGPoint(x: 10, y: 20), isDesktop: onDesktop)
        observer.handle(.up, at: CGPoint(x: 10, y: 20), isDesktop: onDesktop)

        #expect(receiver.edges.isEmpty)
    }

    @Test("Two clicks in a row carry different gesture numbers")
    func distinctGestures() {
        let receiver = RecordingReceiver()
        let observer = makeObserver([(Self.left, receiver)])
        for _ in 0 ..< 2 {
            observer.handle(.down, at: CGPoint(x: 10, y: 20), isDesktop: onDesktop)
            observer.handle(.up, at: CGPoint(x: 10, y: 20), isDesktop: onDesktop)
        }

        #expect(receiver.edges.count == 4)
        guard receiver.edges.count == 4 else { return }
        #expect(receiver.edges[0].gesture != receiver.edges[2].gesture)
    }

    @Test("A new press while a gesture is still open first releases the old one as dragged")
    func unfinishedGestureClosedAsDragged() {
        let first = RecordingReceiver()
        let second = RecordingReceiver()
        let observer = makeObserver([(Self.left, first), (Self.right, second)])
        observer.handle(.down, at: CGPoint(x: 50, y: 50), isDesktop: onDesktop)
        observer.handle(.down, at: CGPoint(x: 150, y: 50), isDesktop: onDesktop)

        #expect(first.edges.map(\.isDown) == [true, false])
        #expect(first.edges.last?.dragged == true)
        #expect(first.edges.last?.gesture == first.edges.first?.gesture)
        #expect(second.edges.map(\.isDown) == [true])
    }

    @Test("Only windows at or below the desktop icon level count as the desktop")
    func desktopWindowLevels() {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let wallpaperLevel = Int(CGWindowLevelForKey(.desktopWindow))
        #expect(DesktopClickObserver.isDesktopWindow(layer: iconLevel))
        #expect(DesktopClickObserver.isDesktopWindow(layer: wallpaperLevel))
        #expect(!DesktopClickObserver.isDesktopWindow(layer: 0))
        #expect(!DesktopClickObserver.isDesktopWindow(layer: 24))
    }
}
#endif
