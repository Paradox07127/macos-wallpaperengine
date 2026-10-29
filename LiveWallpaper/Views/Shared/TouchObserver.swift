import AppKit

/// Reports where each finger lands in a window and never recognizes, so the touch still reaches AppKit's
/// tap, pan and long-press mouse simulation. Event monitors never see touches; this is their touch counterpart.
@MainActor
final class TouchObserver: NSGestureRecognizer, NSGestureRecognizerDelegate {
    private let onTouch: @MainActor (NSPoint) -> Void

    private init(onTouch: @escaping @MainActor (NSPoint) -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Adds an observer to `window`'s content view, which keeps it alive; `onTouch` gets window coordinates.
    /// nil before macOS 27 or without a content view.
    static func install(in window: NSWindow, onTouch: @escaping @MainActor (NSPoint) -> Void) -> TouchObserver? {
        guard #available(macOS 27, *), let content = window.contentView else { return nil }
        let observer = TouchObserver(onTouch: onTouch)
        content.addGestureRecognizer(observer)
        return observer
    }

    func remove() {
        view?.removeGestureRecognizer(self)
    }

    /// AppKit asks this only for mouse events.
    func gestureRecognizer(_: NSGestureRecognizer, shouldAttemptToRecognizeWith _: NSEvent) -> Bool {
        false
    }

    /// AppKit asks this only for touches; declining keeps the observer out of the touch's recognition.
    func gestureRecognizer(_: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        if let view {
            onTouch(view.convert(touch.location(in: view), to: nil))
        }
        return false
    }
}
