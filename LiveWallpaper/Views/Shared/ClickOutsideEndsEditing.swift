import AppKit

/// AppKit moves the keyboard on a click only when the clicked view accepts first responder, and SwiftUI's
/// hosting views never do, so a text field stays in editing after a click elsewhere on a SwiftUI page.
@MainActor
enum ClickOutsideEndsEditing {
    private static var monitor: Any?
    private static var keyWindowObserver: (any NSObjectProtocol)?
    private static var keyWindowContentObservation: NSKeyValueObservation?
    private static let touchObservers = NSHashTable<TouchObserver>.weakObjects()

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { endEditing(onClickAt: event.locationInWindow, in: event.window) }
            return event
        }
        guard #available(macOS 27, *) else { return }
        // A field can only start editing in a key window, so observing every window that becomes key covers them all.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated(observeKeyWindowContent)
        }
        observeKeyWindowContent()
    }

    /// A content view swapped in after the window became key needs an observer of its own.
    private static func observeKeyWindowContent() {
        keyWindowContentObservation = NSApp.keyWindow?.observe(\.contentView, options: .initial) { _, _ in
            MainActor.assumeIsolated(observeKeyWindowTouches)
        }
    }

    /// The window whose text editing a click at `point` (window coordinates) ends; nil leaves editing alone.
    static func windowEndingEditing(onClickAt point: NSPoint, in window: NSWindow?) -> NSWindow? {
        guard let window, let editor = window.firstResponder as? NSTextView,
              let content = window.contentView, let root = content.superview else { return nil }
        let field = editor.isFieldEditor ? editor.delegate as? NSView : editor.enclosingScrollView ?? editor
        // For a mouse click the stage's hitTest reads `NSApp.currentEvent`, which is that click while monitors run.
        guard let field, let hit = root.hitTest(point),
              hit.isDescendant(of: content), !hit.isDescendant(of: field) else { return nil }
        return window
    }

    private static func endEditing(onClickAt point: NSPoint, in window: NSWindow?) {
        windowEndingEditing(onClickAt: point, in: window)?.makeFirstResponder(nil)
    }

    private static func observeKeyWindowTouches() {
        guard let window = NSApp.keyWindow, let content = window.contentView,
              !touchObservers.allObjects.contains(where: { $0.view === content }) else { return }
        let observer = TouchObserver.install(in: window) { [weak window] point in
            endEditing(onClickAt: point, in: window)
        }
        touchObservers.add(observer)
    }
}
