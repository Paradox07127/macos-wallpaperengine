import AppKit

/// `hitTest` returning nil still consumes the click; only `ignoresMouseEvents` reaches Finder, and it is per-window, so stay click-through until the pointer is over a live control.
enum OverlayPointerGate {
    /// `pointerIsOverLiveArea` comes from the host view's own hit-region test,
    /// so the window flag and the view filter can never disagree.
    static func windowTakesMouseEvents(
        scope: PointerScope,
        pointerIsOverLiveArea: Bool
    ) -> Bool {
        switch scope {
        case .none:
            return false
        case .wholeBoard:
            return true
        case .widgetsOnly:
            return pointerIsOverLiveArea
        }
    }

    /// Mid-drag the pointer routinely leaves the control; dropping mouse events there would strand the drag with no mouse-up.
    static var pointerIsCaptured: Bool {
        NSEvent.pressedMouseButtons != 0
    }
}
