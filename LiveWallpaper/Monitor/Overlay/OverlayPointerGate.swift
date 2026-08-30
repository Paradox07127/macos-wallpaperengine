import AppKit

/// Whether an overlay window may take mouse events *right now*. `hitTest` returning nil means no view wants the click,
/// but the window still consumes it — so `ignoresMouseEvents = false` on a full-screen overlay swallows every desktop
/// click, including where nothing is drawn. Only `ignoresMouseEvents` reaches Finder, and it's per-window not
/// per-rect, so a window wanting the pointer for one control stays click-through until the pointer is over it.
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
