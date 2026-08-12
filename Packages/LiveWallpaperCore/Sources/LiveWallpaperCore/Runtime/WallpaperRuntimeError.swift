import Foundation

/// User-visible session errors (`runtimeError` → RuntimeErrorBanner).
public enum WallpaperRuntimeError: Error, Equatable, Sendable {
    case fileAccessDenied(URL)
    case mediaNotPlayable(URL, code: Int?)
    case webNavigationFailed(URL, code: Int?, description: String)
    case networkOffline
    case sandboxRevoked
    /// Generic readiness fail — no paths/URLs in diagnostics.
    case wallpaperPreparationFailed(type: WallpaperType, timedOut: Bool)
    /// Localized `SceneRenderingError` text (mapped in app; Core cannot see Pro types).
    case sceneRenderingFailed(description: String)

    public var userMessage: String {
        switch self {
        case .fileAccessDenied(let url):
            return String(localized: "Cannot access \(url.lastPathComponent). Re-pick the source to restore permission.", comment: "Runtime error message. The placeholder is a file name.")
        case .mediaNotPlayable(let url, let code):
            if let code {
                return String(localized: "The video \(url.lastPathComponent) cannot be played (error \(code)).", comment: "Runtime error message. Placeholders are file name and error code.")
            }
            return String(localized: "The video \(url.lastPathComponent) cannot be played.", comment: "Runtime error message. The placeholder is a file name.")
        case .webNavigationFailed(let url, let code, let description):
            if let code {
                return String(localized: "The web wallpaper at \(url.absoluteString) failed to load (error \(code)): \(description)", comment: "Runtime error message. Placeholders are URL, error code, and system description.")
            }
            return String(localized: "The web wallpaper at \(url.absoluteString) failed to load: \(description)", comment: "Runtime error message. Placeholders are URL and system description.")
        case .networkOffline:
            return String(localized: "The network appears to be offline.", defaultValue: "The network appears to be offline.", comment: "Runtime error message.")
        case .sandboxRevoked:
            return String(localized: "File permission expired. Re-pick the source to restore access.", defaultValue: "File permission expired. Re-pick the source to restore access.", comment: "Runtime error message.")
        case .wallpaperPreparationFailed(let type, let timedOut):
            let name = Self.localizedName(for: type)
            if timedOut {
                return String(localized: "\(name) wallpaper did not become ready in time.", comment: "Runtime readiness timeout. The placeholder is the localized wallpaper type.")
            }
            return String(localized: "\(name) wallpaper could not be prepared.", comment: "Runtime preparation failure. The placeholder is the localized wallpaper type.")
        case .sceneRenderingFailed(let description):
            if description.isEmpty {
                return String(localized: "The scene wallpaper failed to load.", defaultValue: "The scene wallpaper failed to load.", comment: "Runtime error message.")
            }
            return description
        }
    }

    public var canRetry: Bool {
        switch self {
        case .fileAccessDenied, .sandboxRevoked:
            return false
        case .mediaNotPlayable, .webNavigationFailed, .networkOffline,
             .wallpaperPreparationFailed, .sceneRenderingFailed:
            return true
        }
    }

    public enum Severity: Sendable { case error, warning, info }

    public var severity: Severity {
        switch self {
        case .fileAccessDenied, .sandboxRevoked, .mediaNotPlayable, .sceneRenderingFailed:
            return .error
        case .webNavigationFailed:
            return .warning
        case .networkOffline:
            return .info
        case .wallpaperPreparationFailed:
            return .warning
        }
    }

    public var title: String {
        switch self {
        case .fileAccessDenied(let url):
            return String(localized: "Cannot access \(url.lastPathComponent)", comment: "Runtime error title. The placeholder is the file name.")
        case .mediaNotPlayable(let url, _):
            return String(localized: "Video unavailable: \(url.lastPathComponent)", comment: "Runtime error title. The placeholder is the file name.")
        case .webNavigationFailed(let url, _, _):
            return String(localized: "Web wallpaper failed to load: \(url.host ?? url.absoluteString)", comment: "Runtime error title. The placeholder is the URL host or full URL.")
        case .networkOffline:
            return String(localized: "Network offline", defaultValue: "Network offline", comment: "Runtime error title.")
        case .sandboxRevoked:
            return String(localized: "File permission expired", defaultValue: "File permission expired", comment: "Runtime error title.")
        case .wallpaperPreparationFailed(let type, _):
            let name = Self.localizedName(for: type)
            return String(localized: "\(name) wallpaper failed to load", comment: "Runtime preparation error title. The placeholder is the localized wallpaper type.")
        case .sceneRenderingFailed:
            return String(localized: "Scene wallpaper failed to load", defaultValue: "Scene wallpaper failed to load", comment: "Runtime error title.")
        }
    }

    public var subtitlePath: String? {
        switch self {
        case .fileAccessDenied(let url),
             .mediaNotPlayable(let url, _):
            return middleTruncated(url.path, maxLength: 60)
        case .webNavigationFailed(let url, _, _):
            return middleTruncated(url.absoluteString, maxLength: 60)
        case .networkOffline, .sandboxRevoked, .wallpaperPreparationFailed,
             .sceneRenderingFailed:
            return nil
        }
    }

    public var accessibilityDetail: String {
        switch self {
        case .fileAccessDenied(let url),
             .mediaNotPlayable(let url, _):
            return url.path
        case .webNavigationFailed(let url, _, _):
            return url.absoluteString
        case .networkOffline:
            return ""
        case .sandboxRevoked:
            return ""
        case .wallpaperPreparationFailed:
            return userMessage
        case .sceneRenderingFailed(let description):
            return description
        }
    }

    private static func localizedName(for type: WallpaperType) -> String {
        switch type {
        case .video:
            return String(localized: "Video")
        case .html:
            return String(localized: "Web")
        case .scene:
            return String(localized: "Scene")
        }
    }

    private func middleTruncated(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        let keep = maxLength - 1
        let head = keep / 2
        let tail = keep - head
        return string.prefix(head) + "…" + string.suffix(tail)
    }
}
