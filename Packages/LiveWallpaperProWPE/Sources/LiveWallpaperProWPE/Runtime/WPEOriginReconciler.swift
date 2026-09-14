import Foundation
import LiveWallpaperCore

/// Lite uses `PreservingOriginReconciler` (no path-safety dependency).
public struct WPEOriginReconciler: OriginReconciler {
    public init() {}

    public func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent) {
        guard let origin = configuration.wpeOrigin else { return }

        switch event {
        case .loaded:
            return
        case .userReplacedActiveWallpaper:
            break
        }

        guard origin.resourceLocation != .unsupported else {
            configuration.wpeOrigin = nil
            return
        }

        switch configuration.activeWallpaper {
        case .video(let bookmarkData, _):
            if !WPEOrigin.matchesBookmark(bookmarkData, origin: origin) {
                configuration.wpeOrigin = nil
            }
        case .html(let source, _):
            guard case .folder(let bookmarkData, _) = source,
                  WPEOrigin.matchesBookmark(bookmarkData, origin: origin) else {
                configuration.wpeOrigin = nil
                return
            }
        case .scene(let descriptor):
            guard origin.workshopID == descriptor.workshopID,
                  origin.cacheRelativePath == descriptor.cacheRelativePath else {
                configuration.wpeOrigin = nil
                return
            }
        }
    }
}
