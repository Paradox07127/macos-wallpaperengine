#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Bindings are written only from the user's settings row; wallpaper content, presets, backups, CLI and QA never call these setters.
@MainActor
final class UserShortcutBindingStore {
    static let didChange = Notification.Name("UserShortcutBindingStore.didChange")
    static let shared = UserShortcutBindingStore(fileURL: ConfigurationDirectory().url(for: .userShortcutBindings))

    private struct Entry: Codable {
        let key: UserShortcutBindingKey
        let binding: UserShortcutBinding
    }

    private struct StoredFile: Codable {
        var revision: UInt64
        var entries: [Entry]
    }

    private static let maxURLLength = 2048
    private static let maxNameLength = 255
    private static let maxArgumentsLength = 1024

    private let fileURL: URL
    private var bindings: [UserShortcutBindingKey: UserShortcutBinding] = [:]
    private var revision: UInt64 = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let stored = try JSONDecoder().decode(StoredFile.self, from: data)
            for entry in stored.entries {
                bindings[entry.key] = entry.binding
            }
            revision = max(stored.revision, stored.entries.map(\.binding.revision).max() ?? 0)
        } catch {
            Logger.error("User shortcut bindings unreadable, starting empty: \(error.localizedDescription)", category: .settings)
        }
    }

    func binding(for key: UserShortcutBindingKey) -> UserShortcutBinding? {
        bindings[key]
    }

    /// Keyed by property key.
    func bindings(forWallpaper wallpaperID: String) -> [String: UserShortcutBinding] {
        var result: [String: UserShortcutBinding] = [:]
        for (key, binding) in bindings where key.wallpaperID == wallpaperID {
            result[key.propertyKey] = binding
        }
        return result
    }

    func setWebsite(_ urlString: String, for key: UserShortcutBindingKey) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UserShortcutValidationError.empty }
        guard var components = URLComponents(string: trimmed) else { throw UserShortcutValidationError.malformedURL }
        let scheme = components.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { throw UserShortcutValidationError.unsupportedScheme }
        components.scheme = scheme
        guard let host = components.host, !host.isEmpty else { throw UserShortcutValidationError.missingHost }
        guard components.user == nil, components.password == nil else { throw UserShortcutValidationError.credentialsInURL }
        guard let url = components.url else { throw UserShortcutValidationError.malformedURL }
        let normalized = url.absoluteString
        guard normalized.count <= Self.maxURLLength else { throw UserShortcutValidationError.tooLong }
        store(kind: .web, target: normalized, arguments: nil, displayName: host, for: key)
    }

    func setShortcut(name: String, arguments: String?, for key: UserShortcutBindingKey) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw UserShortcutValidationError.empty }
        guard trimmedName.count <= Self.maxNameLength else { throw UserShortcutValidationError.tooLong }
        guard !Self.containsControlCharacter(trimmedName, allowingNewline: false) else {
            throw UserShortcutValidationError.controlCharacters
        }
        var storedArguments: String?
        if let arguments, !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard arguments.count <= Self.maxArgumentsLength else { throw UserShortcutValidationError.tooLong }
            guard !Self.containsControlCharacter(arguments, allowingNewline: true) else {
                throw UserShortcutValidationError.controlCharacters
            }
            storedArguments = arguments
        }
        store(kind: .cmd, target: trimmedName, arguments: storedArguments, displayName: trimmedName, for: key)
    }

    func clear(_ key: UserShortcutBindingKey) {
        guard bindings.removeValue(forKey: key) != nil else { return }
        commit(wallpaperID: key.wallpaperID)
    }

    func removeAll(forWallpaper wallpaperID: String) {
        let before = bindings.count
        bindings = bindings.filter { $0.key.wallpaperID != wallpaperID }
        guard bindings.count != before else { return }
        commit(wallpaperID: wallpaperID)
    }

    private func store(kind: UserShortcutKind, target: String, arguments: String?, displayName: String, for key: UserShortcutBindingKey) {
        bindings[key] = UserShortcutBinding(
            kind: kind,
            target: target,
            arguments: arguments,
            displayName: displayName,
            revision: revision + 1
        )
        commit(wallpaperID: key.wallpaperID)
    }

    private func commit(wallpaperID: String) {
        revision += 1
        let stored = StoredFile(
            revision: revision,
            entries: bindings.map { Entry(key: $0.key, binding: $0.value) }
        )
        do {
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.error("User shortcut bindings write failed: \(error.localizedDescription)", category: .settings)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["wallpaperID": wallpaperID])
    }

    private static func containsControlCharacter(_ text: String, allowingNewline: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            !(allowingNewline && scalar == "\n") && CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
#endif
