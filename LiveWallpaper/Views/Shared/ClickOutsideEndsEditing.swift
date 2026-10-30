import AppKit

/// AppKit moves the keyboard on a click only when the clicked view accepts first responder, and SwiftUI's
/// hosting views never do, so a text field stays in editing after a click elsewhere on a SwiftUI page.
@MainActor
enum ClickOutsideEndsEditing {
    private static var monitor: Any?
    private static var keyWindowObserver: (any NSObjectProtocol)?
    private static var keyWindowContentObservation: NSKeyValueObservation?

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
        guard let content = NSApp.keyWindow?.contentView,
              !content.gestureRecognizers.contains(where: { $0 is TouchTap }) else { return }
        content.addGestureRecognizer(TouchTap())
    }

    /// Fires only when a finger lifts without having moved, so a touch that starts a scroll leaves editing alone.
    private final class TouchTap: NSClickGestureRecognizer, NSGestureRecognizerDelegate {
        init() {
            super.init(target: nil, action: nil)
            target = self
            action = #selector(tapped)
            allowedTouchTypes = .direct
            // Recognizing must not hold back AppKit's tap, pan and long-press mouse simulation.
            delaysPrimaryMouseButtonEvents = false
            delegate = self
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func tapped() {
            endEditing(onClickAt: location(in: nil), in: view?.window)
        }

        /// AppKit asks this only for mouse events; the event monitor already handles those clicks.
        func gestureRecognizer(_: NSGestureRecognizer, shouldAttemptToRecognizeWith _: NSEvent) -> Bool {
            false
        }

        func gestureRecognizer(_: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith _: NSGestureRecognizer) -> Bool {
            true
        }
    }
}
