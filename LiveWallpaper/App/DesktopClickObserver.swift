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
        // Global monitor events arrive asynchronously, so each uses its own recorded location rather than `NSEvent.mouseLocation`.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let (type, window, point) = (event.type, event.window, event.locationInWindow)
            MainActor.assumeIsolated {
                self?.handleMonitored(type, at: Self.screenLocation(point, in: window))
            }
        }) {
            monitors.append(global)
        }
        // The global monitor never sees releases delivered to this app, so a press that ends over our own window is closed here.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            let (window, point) = (event.window, event.locationInWindow)
            MainActor.assumeIsolated {
                self?.handle(.up, at: Self.screenLocation(point, in: window), isDesktop: DesktopClickObserver.isDesktop(at:))
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

    private func handleMonitored(_ type: NSEvent.EventType, at location: CGPoint) {
        let kind: Kind
        switch type {
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        default: return
        }
        handle(kind, at: location, isDesktop: Self.isDesktop(at:))
    }

    /// With no window (global monitor) `locationInWindow` is already in Cocoa screen coordinates.
    private static func screenLocation(_ point: CGPoint, in window: NSWindow?) -> CGPoint {
        window?.convertPoint(toScreen: point) ?? point
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
        // A release can land far from its press with no drag event seen in between.
        let moved = hypot(location.x - gesture.pressLocation.x, location.y - gesture.pressLocation.y) > Self.dragThreshold
        gesture.receiver?.publishDesktopButton(location: location, pressLocation: gesture.pressLocation,
                                               isDown: false, gesture: gesture.id, dragged: gesture.dragged || moved)
    }

    /// Finder's desktop icon window, or the system wallpaper window below it when desktop icons are hidden.
    /// Only system processes own windows that low; an unknown owner (nil bundle id and name) is refused.
    static func isDesktopWindow(layer: Int, ownerBundleIdentifier: String?, ownerName: String?) -> Bool {
        guard layer <= Int(CGWindowLevelForKey(.desktopIconWindow)) else { return false }
        // WindowServer has no bundle identifier.
        return ownerBundleIdentifier?.hasPrefix("com.apple.") == true || ownerName == "Window Server"
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
        return isDesktopWindow(layer: layer,
                               ownerBundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                               ownerName: info[kCGWindowOwnerName as String] as? String)
    }
}
#endif
