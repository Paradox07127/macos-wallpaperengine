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
    /// web: normalized absolute http(s) URL string; cmd: the Shortcuts shortcut name.
    var target: String
    /// cmd only: text input for the shortcut; nil = run without input.
    var arguments: String?
    var displayName: String
    var revision: UInt64
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
