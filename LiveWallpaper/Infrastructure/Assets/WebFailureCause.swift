import Foundation
import LiveWallpaperCore

/// The web counterpart of `SceneFailureCause`: without it every web failure — a missing
/// `index.html`, a revoked folder grant, a 404, a renderer crash — collapses into one
/// `runtime.webNavigationFailed` bucket and the surface can only say "it didn't load".
enum WebFailureCause {
    /// `isLocalProject`: the folder scheme serves a missing entry page as the file error, never
    /// as an HTTP 404, so only there does a Cocoa "no such file" mean the project lacks its page.
    static func navigation(domain: String, code: Int, description: String, isLocalProject: Bool = false) -> WallpaperFailureCause {
        switch domain {
        case NSURLErrorDomain:
            urlError(code: code, description: description, isLocalProject: isLocalProject)
        case "WebKitErrorDomain":
            webKitError(code: code, description: description)
        case NSCocoaErrorDomain where isLocalProject && (code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError):
            entryMissing
        case NSCocoaErrorDomain where isLocalProject && code == NSFileReadNoPermissionError:
            resourceDenied
        default:
            WallpaperFailureCause(code: "web.\(domain).\(code)", reason: description)
        }
    }

    /// Only the folder scheme's 404 means the project is missing its entry file; a remote host's
    /// 404 is a server answer and must not be reported as a broken local folder.
    static func httpStatus(_ status: Int, isLocalProject: Bool) -> WallpaperFailureCause {
        if status == 404, isLocalProject {
            entryMissing
        } else {
            WallpaperFailureCause(
                code: "web.http_status",
                reason: String(
                    localized: "The page's server answered with error \(status).",
                    bundle: .appLanguage,
                    comment: "Web wallpaper failure reason. The placeholder is an HTTP status code such as 500."
                ),
                // Only a server-side fault can clear on its own; a 4xx answers the same next time.
                canRetry: status >= 500
            )
        }
    }

    static func rendererCrashed() -> WallpaperFailureCause {
        WallpaperFailureCause(
            code: "web.renderer_crashed",
            reason: String(
                localized: "The web renderer process crashed repeatedly.",
                bundle: .appLanguage,
                comment: "Runtime error detail shown when an HTML wallpaper's WebKit content process keeps crashing and the retry budget is exhausted."
            )
        )
    }

    private static var entryMissing: WallpaperFailureCause {
        WallpaperFailureCause(
            code: "web.entry_missing",
            reason: String(
                localized: "The wallpaper's entry page is missing from its folder.",
                bundle: .appLanguage,
                comment: "Web wallpaper failure reason shown when the HTML file the project names cannot be served."
            ),
            canRetry: false
        )
    }

    private static var resourceDenied: WallpaperFailureCause {
        WallpaperFailureCause(
            code: "web.resource_denied",
            reason: String(
                localized: "The wallpaper's folder could not be read. Re-pick the source to restore permission.",
                bundle: .appLanguage,
                comment: "Web wallpaper failure reason shown when the sandbox refuses the project folder."
            ),
            canRetry: false
        )
    }

    private static func urlError(code: Int, description: String, isLocalProject: Bool) -> WallpaperFailureCause {
        switch code {
        case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable:
            entryMissing
        // The folder scheme answers an entry path that is a directory with cannotOpenFile.
        case NSURLErrorCannotOpenFile, NSURLErrorFileIsDirectory:
            isLocalProject ? entryMissing : WallpaperFailureCause(code: "web.url_error.\(code)", reason: description)
        case NSURLErrorNoPermissionsToReadFile:
            resourceDenied
        case NSURLErrorNotConnectedToInternet:
            WallpaperFailureCause(
                code: "web.offline",
                reason: String(
                    localized: "The network appears to be offline.",
                    bundle: .appLanguage,
                    comment: "Runtime error message."
                )
            )
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed:
            WallpaperFailureCause(
                code: "web.host_unreachable",
                reason: String(
                    localized: "The page's server could not be reached.",
                    bundle: .appLanguage,
                    comment: "Web wallpaper failure reason shown when a remote page's host does not answer."
                )
            )
        default:
            WallpaperFailureCause(code: "web.url_error.\(code)", reason: description)
        }
    }

    /// WebKit's own domain has no public constants; these two are the ones a wallpaper hits.
    private static func webKitError(code: Int, description: String) -> WallpaperFailureCause {
        switch code {
        case 103:
            WallpaperFailureCause(
                code: "web.blocked_port",
                reason: String(
                    localized: "The page tried to load from a network port the system blocks.",
                    bundle: .appLanguage,
                    comment: "Web wallpaper failure reason shown when WebKit refuses a restricted port."
                ),
                canRetry: false
            )
        case 102:
            WallpaperFailureCause(
                code: "web.frame_interrupted",
                reason: String(
                    localized: "The page stopped loading before it finished.",
                    bundle: .appLanguage,
                    comment: "Web wallpaper failure reason shown when a frame load is interrupted."
                )
            )
        default:
            WallpaperFailureCause(code: "web.webkit_error.\(code)", reason: description)
        }
    }
}
