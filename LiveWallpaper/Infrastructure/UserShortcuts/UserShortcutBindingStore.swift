#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Bindings are written only from the user's settings row; wallpaper content, presets, backups, CLI and QA never call these setters.
/// Setters return false when the change couldn't be saved; the store is then unchanged and posts nothing.
@MainActor
final class UserShortcutBindingStore {
    static let didChange = Notification.Name("UserShortcutBindingStore.didChange")
    static let shared = UserShortcutBindingStore(fileURL: ConfigurationDirectory().url(for: .userShortcutBindings))

    private struct Entry: Codable {
        let key: UserShortcutBindingKey
        let binding: UserShortcutBinding
    }

    private struct StoredFile: Encodable {
        var revision: UInt64
        var entries: [Entry]
    }

    /// Decodes entries one by one so one unreadable entry doesn't discard the rest.
    private struct LenientFile: Decodable {
        struct LenientEntry: Decodable {
            let entry: Entry?

            init(from decoder: any Decoder) throws {
                entry = try? Entry(from: decoder)
            }
        }

        let revision: UInt64?
        let entries: [LenientEntry]

        private enum CodingKeys: String, CodingKey {
            case revision, entries
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            revision = try? container.decode(UInt64.self, forKey: .revision)
            entries = try container.decode([LenientEntry].self, forKey: .entries)
        }
    }

    private static let maxURLLength = 2048
    private static let maxNameLength = 255
    private static let maxArgumentsLength = 1024
    /// Larger loaded revisions are corrupt: incrementing from them could overflow.
    private static let maxLoadedRevision = UInt64.max / 2

    private let fileURL: URL
    private var bindings: [UserShortcutBindingKey: UserShortcutBinding] = [:]
    private var revision: UInt64 = 0
    /// The file exists but couldn't be read, so no write may replace it.
    private var isReadOnly = false
    /// Part of the file was unreadable; it's moved aside before the next write replaces it.
    private var needsBackup = false

    private var nextRevision: UInt64 {
        revision == .max ? revision : revision + 1
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            isReadOnly = true
            let readError = error as NSError
            Logger.error("User shortcut bindings couldn't be read (\(readError.domain) \(readError.code)); changes won't be saved", category: .settings)
            return
        }
        let stored = try? JSONDecoder().decode(LenientFile.self, from: data)
        let entries = (stored?.entries ?? []).compactMap(\.entry).filter { $0.binding.revision <= Self.maxLoadedRevision }
        for entry in entries {
            bindings[entry.key] = entry.binding
        }
        let fileRevision = stored?.revision.flatMap { $0 <= Self.maxLoadedRevision ? $0 : nil }
        revision = max(fileRevision ?? 0, entries.map(\.binding.revision).max() ?? 0)
        if fileRevision == nil || entries.count != stored?.entries.count {
            needsBackup = true
            Logger.error("User shortcut bindings partly unreadable: kept \(entries.count) entries", category: .settings)
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

    @discardableResult
    func setWebsite(_ urlString: String, for key: UserShortcutBindingKey) throws -> Bool {
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
        return store(kind: .web, target: normalized, arguments: nil, displayName: host, for: key)
    }

    @discardableResult
    func setShortcut(name: String, arguments: String?, for key: UserShortcutBindingKey) throws -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw UserShortcutValidationError.empty }
        guard trimmedName.count <= Self.maxNameLength else { throw UserShortcutValidationError.tooLong }
        guard !Self.containsControlCharacter(trimmedName, allowingNewline: false) else {
            throw UserShortcutValidationError.controlCharacters
        }
        let storedArguments = try Self.validatedArguments(arguments)
        return store(kind: .cmd, target: trimmedName, arguments: storedArguments, displayName: trimmedName, for: key)
    }

    /// Arguments are kept only for an `.app`; any other file drops them.
    @discardableResult
    func setFile(_ url: URL, arguments: String?, for key: UserShortcutBindingKey) throws -> Bool {
        let isApplication = UserShortcutBinding.isApplication(url)
        let storedArguments = isApplication ? try Self.validatedArguments(arguments) : nil
        let bookmark = try DirectoryBookmarks.createReadOnlyBookmark(for: url)
        let name = url.lastPathComponent
        let displayName = isApplication ? url.deletingPathExtension().lastPathComponent : name
        return store(kind: .file, target: name, arguments: storedArguments, displayName: displayName, bookmark: bookmark, for: key)
    }

    @discardableResult
    func setDirectory(_ url: URL, for key: UserShortcutBindingKey) throws -> Bool {
        let bookmark = try DirectoryBookmarks.createReadOnlyBookmark(for: url)
        let name = url.lastPathComponent
        return store(kind: .directory, target: name, arguments: nil, displayName: name, bookmark: bookmark, for: key)
    }

    /// Compare-and-swap: a refresh of a bookmark the user has since replaced is dropped.
    @discardableResult
    func replaceBookmark(_ original: Data, with refreshed: Data, for key: UserShortcutBindingKey) -> Bool {
        guard var binding = bindings[key], binding.bookmark == original else { return true }
        binding.bookmark = refreshed
        var updated = bindings
        updated[key] = binding
        return commit(updated, wallpaperID: key.wallpaperID)
    }

    /// The executor gets a binding without its key, so a stale-bookmark refresh finds its owners here.
    func keys(boundTo bookmark: Data) -> [UserShortcutBindingKey] {
        bindings.filter { $0.value.bookmark == bookmark }.map(\.key)
    }

    @discardableResult
    func clear(_ key: UserShortcutBindingKey) -> Bool {
        var updated = bindings
        guard updated.removeValue(forKey: key) != nil else { return true }
        return commit(updated, wallpaperID: key.wallpaperID)
    }

    @discardableResult
    func removeAll(forWallpaper wallpaperID: String) -> Bool {
        let updated = bindings.filter { $0.key.wallpaperID != wallpaperID }
        guard updated.count != bindings.count else { return true }
        return commit(updated, wallpaperID: wallpaperID)
    }

    /// A local copy keeps the Workshop id of the Steam item it came from, so bindings go only once no remaining entry uses the id.
    @discardableResult
    func removeAllUnlessUsed(forWallpaper wallpaperID: String, by remaining: [WPEHistoryEntry]) -> Bool {
        guard !remaining.contains(where: { $0.origin.workshopID == wallpaperID }) else { return true }
        return removeAll(forWallpaper: wallpaperID)
    }

    private func store(
        kind: UserShortcutKind,
        target: String,
        arguments: String?,
        displayName: String,
        bookmark: Data? = nil,
        for key: UserShortcutBindingKey
    ) -> Bool {
        var updated = bindings
        updated[key] = UserShortcutBinding(
            kind: kind,
            target: target,
            arguments: arguments,
            displayName: displayName,
            revision: nextRevision,
            bookmark: bookmark
        )
        return commit(updated, wallpaperID: key.wallpaperID)
    }

    /// nil for nil or blank input.
    private static func validatedArguments(_ arguments: String?) throws -> String? {
        guard let arguments, !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard arguments.count <= maxArgumentsLength else { throw UserShortcutValidationError.tooLong }
        guard !containsControlCharacter(arguments, allowingNewline: true) else {
            throw UserShortcutValidationError.controlCharacters
        }
        return arguments
    }

    /// Adopts `updated` and the next revision only after the file write succeeds.
    private func commit(_ updated: [UserShortcutBindingKey: UserShortcutBinding], wallpaperID: String) -> Bool {
        guard !isReadOnly else {
            Logger.error("User shortcut bindings not saved: the stored file couldn't be read", category: .settings)
            return false
        }
        let next = nextRevision
        let stored = StoredFile(
            revision: next,
            entries: updated.map { Entry(key: $0.key, binding: $0.value) }
        )
        do {
            let data = try JSONEncoder().encode(stored)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if needsBackup {
                let stem = fileURL.deletingPathExtension().lastPathComponent
                let backup = directory.appendingPathComponent("\(stem).corrupt-\(Int(Date().timeIntervalSince1970)).json", isDirectory: false)
                try FileManager.default.moveItem(at: fileURL, to: backup)
                needsBackup = false
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            let writeError = error as NSError
            Logger.error("User shortcut bindings write failed (\(writeError.domain) \(writeError.code))", category: .settings)
            return false
        }
        bindings = updated
        revision = next
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["wallpaperID": wallpaperID])
        return true
    }

    private static func containsControlCharacter(_ text: String, allowingNewline: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            !(allowingNewline && scalar == "\n") && CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
#endif
