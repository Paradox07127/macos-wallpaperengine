#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Feeds each running scene's script bridge the user's bindings and launches them on request.
@MainActor
final class UserShortcutRendererLink {
    static let shared = UserShortcutRendererLink(store: .shared)

    private struct Registration {
        weak var bridge: WPEUserShortcutScriptBridge?
        weak var icons: WPEUserShortcutIconStore?
        let wallpaperID: String
        var declared: Set<String>
        /// Scene texture keys: their bound image or video goes to `icons` only, never to the script bridge.
        let textureKeys: Set<String>
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

    func attach(
        _ bridge: WPEUserShortcutScriptBridge,
        icons: WPEUserShortcutIconStore,
        wallpaperID: String,
        declaredKeys: Set<String>,
        textureKeys: Set<String> = []
    ) {
        registrations.removeAll { $0.bridge == nil || $0.bridge === bridge }
        let registration = Registration(bridge: bridge, icons: icons, wallpaperID: wallpaperID, declared: declaredKeys,
                                        textureKeys: textureKeys)
        registrations.append(registration)
        push(registration)
        bridge.setLauncher { [weak self] propertyKey, revision in
            Task { @MainActor in self?.launch(wallpaperID: wallpaperID, propertyKey: propertyKey, revision: revision) }
        }
    }

    /// A reload's manifest may declare different keys; no-op for a bridge that was never attached.
    func updateDeclaredKeys(_ declaredKeys: Set<String>, for bridge: WPEUserShortcutScriptBridge) {
        guard let index = registrations.firstIndex(where: { $0.bridge === bridge }) else { return }
        registrations[index].declared = declaredKeys
        push(registrations[index])
    }

    nonisolated static func declaredTextureKeys(manifestRoot: URL) -> Set<String> {
        guard let schema = try? WallpaperEngineProjectPropertySchema.read(from: manifestRoot, includeSchemeColor: true) else {
            return []
        }
        return Set(schema.properties.filter { $0.type == .sceneTexture }.map(\.key))
    }

    private func storeDidChange(wallpaperID: String?) {
        registrations.removeAll { $0.bridge == nil }
        for registration in registrations where registration.wallpaperID == wallpaperID {
            push(registration)
        }
    }

    private func push(_ registration: Registration) {
        guard let bridge = registration.bridge else { return }
        let declared = registration.declared
        let bindings = store.bindings(forWallpaper: registration.wallpaperID)
        let bound = bindings.filter { declared.contains($0.key) }.mapValues {
            WPEUserShortcutScriptBridge.Entry(commandType: $0.kind.rawValue, displayName: $0.displayName, revision: $0.revision,
                                              target: $0.target)
        }
        bridge.setBindings(declared: declared, bound: bound)
        guard let icons = registration.icons else { return }
        for key in declared {
            icons.setIcon(bindings[key].flatMap(UserShortcutIconRenderer.icon(for:)), forKey: key)
        }
        for key in registration.textureKeys {
            let video = bindings[key].flatMap(UserShortcutIconRenderer.sceneVideo(for:))
            icons.setVideo(video, forKey: key)
            icons.setIcon(video == nil ? bindings[key].flatMap(UserShortcutIconRenderer.sceneTexture(for:)) : nil, forKey: key)
        }
    }

    private func launch(wallpaperID: String, propertyKey: String, revision: UInt64) {
        let key = UserShortcutBindingKey(wallpaperID: wallpaperID, propertyKey: propertyKey)
        guard let binding = store.binding(for: key), binding.revision == revision else {
            Logger.debug("User shortcut launch dropped: the binding changed after the click", category: .settings)
            return
        }
        execute(binding)
    }
}
#endif
