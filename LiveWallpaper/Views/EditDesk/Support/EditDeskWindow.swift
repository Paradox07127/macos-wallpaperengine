import AppKit

/// Sends Edit › Undo and Redo where ⌘Z goes. Only text fields register actions here; the Edit Desk's
/// own steps stay in `stack`.
final class EditDeskMenuUndoManager: UndoManager {
    weak var stack: EditDeskUndoStack?
    weak var toasts: EditDeskToastCenter?
    var route: @MainActor () -> EditDeskUndoKeyRoute = { .current }

    override var canUndo: Bool {
        switch route() {
        case .text: super.canUndo
        case .stack: stack?.undoSteps.isEmpty == false
        case .ignore: false
        }
    }

    override var canRedo: Bool {
        switch route() {
        case .text: super.canRedo
        case .stack: stack?.redoSteps.isEmpty == false
        case .ignore: false
        }
    }

    override func undo() {
        switch route() {
        case .text:
            super.undo()
        case .stack:
            if let toasts {
                stack?.perform(redo: false, announcingTo: toasts)
            }
        case .ignore:
            break
        }
    }

    override func redo() {
        switch route() {
        case .text:
            super.redo()
        case .stack:
            if let toasts {
                stack?.perform(redo: true, announcingTo: toasts)
            }
        case .ignore:
            break
        }
    }

    /// Empty unless the command goes to a text field, whose action name ("Typing") would otherwise title the stack's Undo.
    override var undoActionName: String {
        route() == .text ? super.undoActionName : ""
    }

    override var redoActionName: String {
        route() == .text ? super.redoActionName : ""
    }
}

/// The Edit Desk's window. `AppDelegate.windowWillReturnUndoManager(_:)` hands AppKit its `menuUndo`.
final class EditDeskWindow: NSWindow {
    let menuUndo = EditDeskMenuUndoManager()
}
