#if !LITE_BUILD
import Foundation

/// Raw values are Wallpaper Engine's `commandtype` strings.
enum UserShortcutKind: String, Codable, Sendable {
    case file, directory, web, cmd
}

struct UserShortcutBindingKey: Hashable, Codable, Sendable {
    let wallpaperID: String
    let propertyKey: String
}

struct UserShortcutBinding: Codable, Sendable, Equatable {
    var kind: UserShortcutKind
    /// web: normalized absolute http(s) URL string; cmd: the Shortcuts shortcut name;
    /// file/directory: the chosen item's last path component only, never the full path.
    var target: String
    /// cmd: text input for the shortcut; file: launch arguments, kept only for an `.app`. nil = none.
    var arguments: String?
    var displayName: String
    var revision: UInt64
    /// file/directory: read-only security-scoped bookmark; nil for web/cmd and in files written before it existed.
    var bookmark: Data?

    var isApplication: Bool {
        kind == .file && Self.isApplication(URL(filePath: target))
    }

    static func isApplication(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }
}

enum UserShortcutValidationError: Error, Equatable {
    case empty
    case tooLong
    case malformedURL
    case unsupportedScheme
    case missingHost
    case credentialsInURL
    case controlCharacters
}
#endif
