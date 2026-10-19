#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os

/// Per-scene user-shortcut bindings that scripts read and launch through.
final class WPEUserShortcutScriptBridge: Sendable {
    static func declaredKeys(manifestRoot: URL) -> Set<String> {
        guard let schema = try? WallpaperEngineProjectPropertySchema.read(from: manifestRoot, includeSchemeColor: true) else {
            return []
        }
        return Set(schema.properties.filter { $0.type == .userShortcut }.map(\.key))
    }

    struct Entry: Sendable, Equatable {
        let commandType: String
        let displayName: String
        let revision: UInt64
        /// The binding target: web URL, cmd shortcut name, or the last path component for file/directory.
        var target = ""
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
#endif
