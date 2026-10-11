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
        /// Gesture numbers only grow, so anything at or below an evicted one is already spent.
        var evictedCeiling: UInt64 = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// True only for the first claim of `gesture`.
    static func claim(_ gesture: UInt64) -> Bool {
        state.withLock { value in
            guard gesture > value.evictedCeiling, value.used.insert(gesture).inserted else { return false }
            value.order.append(gesture)
            if value.order.count > capacity {
                let evicted = value.order.removeFirst()
                value.used.remove(evicted)
                value.evictedCeiling = max(value.evictedCeiling, evicted)
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
        let revision: UInt64
    }

    private struct State {
        var declared: Set<String> = []
        var bound: [String: Entry] = [:]
        var launcher: (@Sendable (String, UInt64) -> Void)?
        /// Declared keys whose binding changed since the renderer last took them.
        var changed: Set<String> = []
        var onChange: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setBindings(declared: Set<String>, bound: [String: Entry]) {
        let onChange = state.withLock { value -> (@Sendable () -> Void)? in
            let changed = declared.filter { value.bound[$0] != bound[$0] }
            value.declared = declared
            value.bound = bound
            value.changed.formUnion(changed)
            return changed.isEmpty ? nil : value.onChange
        }
        onChange?()
    }

    func snapshot() -> (declared: Set<String>, bound: [String: Entry]) {
        state.withLock { ($0.declared, $0.bound) }
    }

    /// Runs after `setBindings` marks a key changed, outside the lock.
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.onChange = handler }
    }

    func takeChangedKeys() -> Set<String> {
        state.withLock { value in
            defer { value.changed.removeAll() }
            return value.changed.intersection(value.declared)
        }
    }

    /// The launcher receives the user-property key and the revision of the binding the click saw.
    func setLauncher(_ launcher: (@Sendable (String, UInt64) -> Void)?) {
        state.withLock { $0.launcher = launcher }
    }

    func requestLaunch(_ propertyKey: String) -> Bool {
        let request = state.withLock { value in
            value.bound[propertyKey].flatMap { entry in value.launcher.map { ($0, entry.revision) } }
        }
        guard let (launcher, revision) = request else { return false }
        launcher(propertyKey, revision)
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

    /// Global that `installSandbox` pins to the built-in SyntaxError before any script runs.
    static let nativeSyntaxErrorName = "__wpeNativeSyntaxError"

    /// Raises the built-in `SyntaxError(message)` in the calling context, even if the script reassigned the global.
    static func raise(_ message: String, scope: WPEUserShortcutCallScope?) {
        guard let context = JSContext.current(),
              let error = context.objectForKeyedSubscript(nativeSyntaxErrorName)?.construct(withArguments: [message]) else { return }
        scope?.thrownError = JSManagedValue(value: error)
        context.exception = error
    }
}
#endif
