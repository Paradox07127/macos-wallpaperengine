#if !LITE_BUILD
import AppKit

struct DesktopClickTarget {
    /// Cocoa global coordinates.
    let frame: CGRect
    let receiver: any SceneDesktopClickReceiving
}

@MainActor
final class DesktopClickObserver {
    enum Kind { case down, dragged, up }

    private struct Gesture {
        weak var receiver: (any SceneDesktopClickReceiving)?
        let id: UInt64
        let pressLocation: CGPoint
        var dragged = false
    }

    private static let dragThreshold: CGFloat = 4

    private let targets: @MainActor () -> [DesktopClickTarget]
    private var monitors: [Any] = []
    private var gesture: Gesture?

    init(targets: @escaping @MainActor () -> [DesktopClickTarget]) {
        self.targets = targets
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMonitored(type) }
        }) {
            monitors.append(global)
        }
        // The global monitor never sees releases delivered to this app, so a press that ends over our own window is closed here.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(.up, at: NSEvent.mouseLocation, isDesktop: DesktopClickObserver.isDesktop(at:))
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        gesture = nil
    }

    func handle(_ kind: Kind, at location: CGPoint, isDesktop: @MainActor (CGPoint) -> Bool) {
        switch kind {
        case .down:
            begin(at: location, isDesktop: isDesktop)
        case .dragged:
            guard let pressLocation = gesture?.pressLocation,
                  hypot(location.x - pressLocation.x, location.y - pressLocation.y) > Self.dragThreshold
            else { return }
            gesture?.dragged = true
        case .up:
            finish(at: location)
        }
    }

    private func handleMonitored(_ type: NSEvent.EventType) {
        let kind: Kind
        switch type {
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        default: return
        }
        handle(kind, at: NSEvent.mouseLocation, isDesktop: Self.isDesktop(at:))
    }

    private func begin(at location: CGPoint, isDesktop: @MainActor (CGPoint) -> Bool) {
        if gesture != nil {
            // The old release was never seen; marking it dragged keeps the scene from synthesizing a click.
            gesture?.dragged = true
            finish(at: location)
        }
        let hits = targets().filter { $0.frame.contains(location) }
        guard hits.count == 1, hits[0].receiver.acceptsDesktopClicks, isDesktop(location) else { return }
        let receiver = hits[0].receiver
        let id = WPEPointerGesture.next()
        gesture = Gesture(receiver: receiver, id: id, pressLocation: location)
        receiver.publishDesktopButton(location: location, pressLocation: location, isDown: true,
                                      gesture: id, dragged: false)
    }

    private func finish(at location: CGPoint) {
        guard let gesture else { return }
        self.gesture = nil
        gesture.receiver?.publishDesktopButton(location: location, pressLocation: gesture.pressLocation,
                                               isDown: false, gesture: gesture.id, dragged: gesture.dragged)
    }

    /// Finder's desktop icon window, or the system wallpaper window below it when desktop icons are hidden.
    static func isDesktopWindow(layer: Int) -> Bool {
        layer <= Int(CGWindowLevelForKey(.desktopIconWindow))
    }

    static func isDesktop(at location: CGPoint) -> Bool {
        // Returns the window that actually takes the mouse there, skipping click-through overlays.
        let number = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let info = infos.first,
              let layer = info[kCGWindowLayer as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return false }
        return isDesktopWindow(layer: layer)
    }
}
#endif
