import AppKit

/// Decides, per overlay window, whether it may take mouse events *right now*.
///
/// `NSView.hitTest` returning nil only says "no view in this window wants the
/// click" — the window still consumes it, so a full-screen overlay running with
/// `ignoresMouseEvents = false` swallows every desktop click, including the ones
/// it draws nothing under. Only `ignoresMouseEvents` lets a click reach Finder,
/// and that flag is per-window, not per-rect. So a window that wants the pointer
/// for one control has to stay click-through until the pointer is over it.
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
            // Edit mode / Mouse Interaction: the board is the interaction
            // surface, and the user asked for exactly that.
            return true
        case .widgetsOnly:
            return pointerIsOverLiveArea
        }
    }

    /// Mid-drag the pointer routinely leaves the control it started on (the
    /// progress bar is the reason this exists); dropping the window's mouse
    /// events there would strand the drag with no mouse-up.
    static var pointerIsCaptured: Bool {
        NSEvent.pressedMouseButtons != 0
    }
}
