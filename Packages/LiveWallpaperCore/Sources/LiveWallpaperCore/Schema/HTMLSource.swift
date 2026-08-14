import Foundation

public enum HTMLSource: Codable, Equatable, Sendable {
    case file(bookmarkData: Data)
    case folder(bookmarkData: Data, indexFileName: String)
    case url(URL)
    case inline(String)

    /// Security-scoped grant for file/folder sources only.
    public var localBookmarkData: Data? {
        switch self {
        case .file(let bookmarkData), .folder(let bookmarkData, _):
            return bookmarkData
        case .url, .inline:
            return nil
        }
    }

    /// CAS local bookmark; keeps file/folder shape. `nil` if `original` no longer owned
    /// (late stale refresh must not overwrite a newer grant).
    public func replacingLocalBookmark(
        matching original: Data,
        with refreshed: Data
    ) -> HTMLSource? {
        switch self {
        case .file(let bookmarkData) where bookmarkData == original:
            return .file(bookmarkData: refreshed)
        case .folder(let bookmarkData, let indexFileName) where bookmarkData == original:
            return .folder(bookmarkData: refreshed, indexFileName: indexFileName)
        case .file, .folder, .url, .inline:
            return nil
        }
    }

    /// Inspector/menu-bar parse: real http(s) hosts, bare host→https, else inline.
    /// YouTube watch/shorts rewrite to cookieless embed (see `normalizingForWallpaper`).
    public init?(userInput: String) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = url.host,
           !host.isEmpty {
            self = .url(Self.normalizingForWallpaper(url))
            return
        }

        if Self.looksLikeBareHost(trimmed),
           let url = URL(string: "https://" + trimmed),
           let host = url.host,
           !host.isEmpty {
            self = .url(Self.normalizingForWallpaper(url))
            return
        }

        self = .inline(trimmed)
    }

    /// YouTube → `youtube-nocookie.com/embed`; other hosts pass through.
    public static func normalizingForWallpaper(_ url: URL) -> URL {
        if let videoID = youTubeVideoID(from: url) {
            return youTubeEmbedURL(forID: videoID) ?? url
        }
        return url
    }

    private static func youTubeVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "youtu.be" {
            let id = url.lastPathComponent
            return isPlausibleVideoID(id) ? id : nil
        }

        guard host == "youtube.com"
            || host == "www.youtube.com"
            || host == "m.youtube.com" else { return nil }

        let path = url.path
        if path == "/watch" {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value ?? ""
            return isPlausibleVideoID(id) ? id : nil
        }
        if path.hasPrefix("/shorts/") {
            let id = String(path.dropFirst("/shorts/".count))
                .split(separator: "/").first.map(String.init) ?? ""
            return isPlausibleVideoID(id) ? id : nil
        }
        if path.hasPrefix("/embed/") {
            return nil
        }
        return nil
    }

    private static func isPlausibleVideoID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 20 else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func youTubeEmbedURL(forID id: String) -> URL? {
        // nocookie avoids SSO/cookie paths that break sandboxed WKWebView passive play;
        // `playlist=<id>` makes `loop=1` restart; extra iframe flags caused Error 153.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(id)"
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "mute", value: "1"),
            URLQueryItem(name: "loop", value: "1"),
            URLQueryItem(name: "playlist", value: id),
        ]
        return components.url
    }

    /// Host-like chars only — blocks CSS/JS with dots from being treated as bare hosts.
    private static let bareHostAllowedScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: ".-:[]")
        return set
    }()

    private static func looksLikeBareHost(_ input: String) -> Bool {
        guard !input.isEmpty else { return false }
        guard input.unicodeScalars.allSatisfy({ bareHostAllowedScalars.contains($0) }) else {
            return false
        }
        let lower = input.lowercased()
        if lower == "localhost" || lower.hasPrefix("localhost:") { return true }
        if input.contains(".") {
            guard input.first != ".", input.last != "." else { return false }
            return true
        }
        if let colonIndex = input.firstIndex(of: ":") {
            let portPart = input[input.index(after: colonIndex)...]
            if !portPart.isEmpty, portPart.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

    public var displayName: String {
        switch self {
        case .file(let bookmark):
            return ResourceUtilities.resolveBookmarkName(bookmark) ?? String(localized: "Local file", comment: "HTML source display name fallback when the bookmark name cannot be resolved.")
        case .folder(let bookmark, let index):
            let folderName = ResourceUtilities.resolveBookmarkName(bookmark) ?? String(localized: "Folder", comment: "HTML source display name fallback when the bookmark name cannot be resolved.")
            return "\(folderName)/\(index)"
        case .url(let url):
            return url.host ?? url.absoluteString
        case .inline:
            return "Inline web content"
        }
    }

    public var iconName: String {
        switch self {
        case .file: return "doc.richtext"
        case .folder: return "folder"
        case .url: return "globe"
        case .inline: return "chevron.left.forwardslash.chevron.right"
        }
    }

    public var isInsecureURL: Bool {
        if case .url(let url) = self {
            return url.scheme?.lowercased() == "http"
        }
        return false
    }

    /// Stable multi-screen identity key (audio/GPU dedupe).
    public var diagnosticSignature: String {
        switch self {
        case .file(let data):
            return "file:" + data.base64EncodedString()
        case .folder(let data, let index):
            return "folder:" + data.base64EncodedString() + ":" + index
        case .url(let url):
            return "url:" + url.absoluteString
        case .inline(let html):
            return "inline:" + String(html.hashValue)
        }
    }
}
