import Foundation

public enum OriginReconciliationEvent: Sendable {
    /// Disk load — persisted origin is authoritative.
    case loaded
    case userReplacedActiveWallpaper(previous: WallpaperContent?)
}

/// Keeps `ScreenConfiguration.wpeOrigin` aligned with active content.
public protocol OriginReconciler: Sendable {
    func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent)
}

/// Lite: drop only `.unsupported`; no bookmark-matching pipeline.
public struct PreservingOriginReconciler: OriginReconciler {
    public init() {}

    public func reconcile(_ configuration: inout ScreenConfiguration, event: OriginReconciliationEvent) {
        guard let origin = configuration.wpeOrigin else { return }
        if origin.resourceLocation == .unsupported {
            configuration.wpeOrigin = nil
        }
        _ = event
    }
}
