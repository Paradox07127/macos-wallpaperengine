#if !LITE_BUILD
import AppKit
import LiveWallpaperCore

enum UserShortcutExecutor {
    /// RFC 3986 unreserved only: URLComponents.queryItems leaves `+`, `=` etc. as-is, which would let a name or argument inject query items.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func launchURL(for binding: UserShortcutBinding) -> URL? {
        switch binding.kind {
        case .web:
            // The store validated the scheme on write; re-check so an edited bindings file cannot open other schemes.
            guard let url = URL(string: binding.target), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
            return url
        case .cmd:
            var items = [URLQueryItem(name: "name", value: encode(binding.target))]
            if let arguments = binding.arguments {
                items.append(URLQueryItem(name: "input", value: "text"))
                items.append(URLQueryItem(name: "text", value: encode(arguments)))
            }
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            components.percentEncodedQueryItems = items
            return components.url
        case .file, .directory:
            return nil
        }
    }

    /// `openFile` gets launch arguments only for an `.app` and must call `completion` once the open finishes.
    @MainActor
    static func execute(
        _ binding: UserShortcutBinding,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        openFile: @MainActor (URL, _ arguments: [String]?, _ completion: @escaping @Sendable () -> Void) -> Void = openWithWorkspace
    ) -> Bool {
        switch binding.kind {
        case .web, .cmd:
            guard let url = launchURL(for: binding) else { return false }
            let host = binding.kind == .web ? url.host ?? "" : ""
            Logger.info("User shortcut: \(binding.kind.rawValue) \(host)", category: .settings)
            return open(url)
        case .file, .directory:
            let target = SecurityScopedBookmarkResolver.Target(label: "user-shortcut") { original, refreshed in
                Task { @MainActor in
                    let store = UserShortcutBindingStore.shared
                    for key in store.keys(boundTo: original) {
                        store.replaceBookmark(original, with: refreshed, for: key)
                    }
                }
            }
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(binding.bookmark, target: target) else {
                Logger.warning("User shortcut: \(binding.kind.rawValue) target can't be resolved", category: .settings)
                return false
            }
            let url = resolved.url
            let arguments = binding.kind == .file && UserShortcutBinding.isApplication(url) ? splitArguments(binding.arguments) : nil
            Logger.info("User shortcut: \(binding.kind.rawValue)", category: .settings)
            // The scope must outlive the asynchronous open, so it is released in the completion, not on return.
            let didStart = url.startAccessingSecurityScopedResource()
            openFile(url, arguments) {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return true
        }
    }

    /// Only checks; a stale refresh is not persisted.
    static func isResolvable(_ binding: UserShortcutBinding) -> Bool {
        switch binding.kind {
        case .web, .cmd:
            return true
        case .file, .directory:
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(binding.bookmark, target: .transient) else {
                return false
            }
            return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                FileManager.default.fileExists(atPath: resolved.url.path(percentEncoded: false))
            }
        }
    }

    /// Whitespace-separated; a double-quoted run is one argument with the quotes removed. No escapes.
    static func splitArguments(_ text: String?) -> [String] {
        guard let text else { return [] }
        var result: [String] = []
        var current = ""
        var hasToken = false
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                hasToken = true
            } else if character.isWhitespace, !quoted {
                if hasToken {
                    result.append(current)
                }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken {
            result.append(current)
        }
        return result
    }

    @MainActor
    static func openWithWorkspace(_ url: URL, arguments: [String]?, completion: @escaping @Sendable () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        let finish: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            if let error {
                Logger.warning("User shortcut: open failed (\((error as NSError).code))", category: .settings)
            }
            completion()
        }
        if let arguments {
            configuration.arguments = arguments
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: finish)
        } else {
            NSWorkspace.shared.open(url, configuration: configuration, completionHandler: finish)
        }
    }

    private static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
#endif
