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

    @MainActor
    static func execute(_ binding: UserShortcutBinding, open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard let url = launchURL(for: binding) else { return false }
        let host = binding.kind == .web ? url.host ?? "" : ""
        Logger.info("User shortcut: \(binding.kind.rawValue) \(host)", category: .settings)
        return open(url)
    }

    private static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
#endif
