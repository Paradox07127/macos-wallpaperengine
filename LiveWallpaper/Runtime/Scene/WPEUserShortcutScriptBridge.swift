#if !LITE_BUILD
import Foundation
import JavaScriptCore
import os

/// Process-wide record of gestures that already spent their one user command.
enum WPEUserShortcutGestureLedger {
    private static let capacity = 256

    private struct State {
        var used: Set<UInt64> = []
        var order: [UInt64] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// True only for the first claim of `gesture`.
    static func claim(_ gesture: UInt64) -> Bool {
        state.withLock { value in
            guard value.used.insert(gesture).inserted else { return false }
            value.order.append(gesture)
            if value.order.count > capacity {
                value.used.remove(value.order.removeFirst())
            }
            return true
        }
    }
}

/// Per-scene user-shortcut bindings that scripts read and launch through.
final class WPEUserShortcutScriptBridge: Sendable {
    struct Entry: Sendable, Equatable {
        let commandType: String
        let displayName: String
    }

    private struct State {
        var declared: Set<String> = []
        var bound: [String: Entry] = [:]
        var launcher: (@Sendable (String) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setBindings(declared: Set<String>, bound: [String: Entry]) {
        state.withLock {
            $0.declared = declared
            $0.bound = bound
        }
    }

    func snapshot() -> (declared: Set<String>, bound: [String: Entry]) {
        state.withLock { ($0.declared, $0.bound) }
    }

    /// The launcher receives the user-property key.
    func setLauncher(_ launcher: (@Sendable (String) -> Void)?) {
        state.withLock { $0.launcher = launcher }
    }

    func requestLaunch(_ propertyKey: String) -> Bool {
        let launcher = state.withLock { $0.bound[propertyKey] == nil ? nil : $0.launcher }
        guard let launcher else { return false }
        launcher(propertyKey)
        return true
    }
}

/// One per script context with cursor handlers; touched only on that context's lane.
final class WPEUserShortcutCallScope {
    /// nil = not inside a cursorDown/Up/Click of a physical press, so the bridge throws.
    var gesture: UInt64?
    /// Weak toward the JS heap, so the scope never keeps its context alive.
    private var thrownError: JSManagedValue?
    /// Whether the last uncaught exception was the error this bridge raised.
    private(set) var uncaughtIsBridgeError = false

    func begin(_ event: WPELayerScriptCursorEvent, pointerFrame: WPEPointerFrame) {
        let eligible: Set<WPELayerScriptCursorEvent> = [.down, .up, .click]
        gesture = eligible.contains(event) && pointerFrame.gesture != 0 ? pointerFrame.gesture : nil
        thrownError = nil
        uncaughtIsBridgeError = false
    }

    func end() {
        gesture = nil
        thrownError = nil
    }

    func noteUncaught(_ exception: JSValue?) {
        guard let exception, let thrown = thrownError?.value else {
            uncaughtIsBridgeError = false
            return
        }
        uncaughtIsBridgeError = exception.isEqual(to: thrown)
    }

    /// Raises `SyntaxError(message)` in the calling context.
    static func raise(_ message: String, scope: WPEUserShortcutCallScope?) {
        guard let context = JSContext.current(),
              let error = context.objectForKeyedSubscript("SyntaxError")?.construct(withArguments: [message]) else { return }
        scope?.thrownError = JSManagedValue(value: error)
        context.exception = error
    }
}
#endif
