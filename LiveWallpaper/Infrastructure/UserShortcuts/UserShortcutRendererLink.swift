#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Feeds each running scene's script bridge the user's bindings and launches them on request.
@MainActor
final class UserShortcutRendererLink {
    static let shared = UserShortcutRendererLink(store: .shared)

    private struct Registration {
        weak var bridge: WPEUserShortcutScriptBridge?
        let wallpaperID: String
        let declared: Set<String>
    }

    private let store: UserShortcutBindingStore
    private var registrations: [Registration] = []
    var execute: @MainActor (UserShortcutBinding) -> Void = { _ = UserShortcutExecutor.execute($0) }

    init(store: UserShortcutBindingStore) {
        self.store = store
        // queue nil: the store posts on the main actor, so the push lands before its setter returns.
        _ = NotificationCenter.default.addObserver(
            forName: UserShortcutBindingStore.didChange, object: store, queue: nil
        ) { [weak self] notification in
            let wallpaperID = notification.userInfo?["wallpaperID"] as? String
            MainActor.assumeIsolated { self?.storeDidChange(wallpaperID: wallpaperID) }
        }
    }

    var registrationCount: Int {
        registrations.count
    }

    func attach(_ bridge: WPEUserShortcutScriptBridge, wallpaperID: String, declaredKeys: Set<String>) {
        registrations.removeAll { $0.bridge == nil || $0.bridge === bridge }
        registrations.append(Registration(bridge: bridge, wallpaperID: wallpaperID, declared: declaredKeys))
        push(to: bridge, wallpaperID: wallpaperID, declared: declaredKeys)
        bridge.setLauncher { [weak self] propertyKey in
            Task { @MainActor in self?.launch(wallpaperID: wallpaperID, propertyKey: propertyKey) }
        }
    }

    static func declaredKeys(manifestRoot: URL) -> Set<String> {
        guard let schema = try? WallpaperEngineProjectPropertySchema.read(from: manifestRoot, includeSchemeColor: true) else {
            return []
        }
        return Set(schema.properties.filter { $0.type == .userShortcut }.map(\.key))
    }

    private func storeDidChange(wallpaperID: String?) {
        registrations.removeAll { $0.bridge == nil }
        for registration in registrations where registration.wallpaperID == wallpaperID {
            guard let bridge = registration.bridge else { continue }
            push(to: bridge, wallpaperID: registration.wallpaperID, declared: registration.declared)
        }
    }

    private func push(to bridge: WPEUserShortcutScriptBridge, wallpaperID: String, declared: Set<String>) {
        let bound = store.bindings(forWallpaper: wallpaperID).mapValues {
            WPEUserShortcutScriptBridge.Entry(commandType: $0.kind.rawValue, displayName: $0.displayName)
        }
        bridge.setBindings(declared: declared, bound: bound)
    }

    private func launch(wallpaperID: String, propertyKey: String) {
        guard let binding = store.binding(for: UserShortcutBindingKey(wallpaperID: wallpaperID, propertyKey: propertyKey)) else {
            return
        }
        execute(binding)
    }
}
#endif
