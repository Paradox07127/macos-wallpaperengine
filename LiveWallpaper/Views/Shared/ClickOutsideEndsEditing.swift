import AppKit

/// AppKit moves the keyboard on a click only when the clicked view accepts first responder, and SwiftUI's
/// hosting views never do, so a text field stays in editing after a click elsewhere on a SwiftUI page.
@MainActor
enum ClickOutsideEndsEditing {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { endEditing(for: event) }
            return event
        }
    }

    private static func endEditing(for event: NSEvent) {
        guard let window = event.window, let editor = window.firstResponder as? NSTextView,
              let content = window.contentView, let root = content.superview else { return }
        let field = editor.isFieldEditor ? editor.delegate as? NSView : editor.enclosingScrollView ?? editor
        // The stage's hitTest reads `NSApp.currentEvent`, which is this event while monitors run.
        guard let field, let hit = root.hitTest(event.locationInWindow),
              hit.isDescendant(of: content), !hit.isDescendant(of: field) else { return }
        window.makeFirstResponder(nil)
    }
}
