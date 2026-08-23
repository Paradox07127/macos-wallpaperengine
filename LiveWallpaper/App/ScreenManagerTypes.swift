import CoreGraphics
import Foundation
import LiveWallpaperCore
#if !LITE_BUILD
import LiveWallpaperProWPE
#endif

struct WallpaperSessionSummaryCache: Equatable {
    private var summariesByScreenID: [CGDirectDisplayID: WallpaperSessionSummary] = [:]

    init() {}

    init(entries: [(CGDirectDisplayID, WallpaperSessionSummary)]) {
        replace(with: entries)
    }

    mutating func replace(with entries: [(CGDirectDisplayID, WallpaperSessionSummary)]) {
        summariesByScreenID = Dictionary(uniqueKeysWithValues: entries)
    }

    func summary(
        for screenID: CGDirectDisplayID,
        fallback: @autoclosure () -> WallpaperSessionSummary
    ) -> WallpaperSessionSummary {
        summariesByScreenID[screenID] ?? fallback()
    }
}

/// Equatable snapshot of the derived wallpaper-session state.
struct WallpaperSessionState: Equatable {
    var version: UInt64 = 0
    var summaryCache: WallpaperSessionSummaryCache = WallpaperSessionSummaryCache()
    var isAnyPlaying: Bool = false
}

struct ScreenManagerStartupOptions: Equatable {
    var restoreSavedWallpapers: Bool = true
    var startAutomation: Bool = true
    var powerMonitor: (any PowerMonitoring)? = nil
    var fullScreenDetector: (any FullScreenDetecting)? = nil
    var playableVideoLoader: (any PlayableVideoLoading)? = nil
    var displayRegistry: (any DisplayRegistering)? = nil
    /// Tests/previews remain inert unless they explicitly inject a watcher. The
    /// production app startup plan supplies the single app-lifetime authority.
    var memoryPressureWatcher: any MemoryPressureWatching = InactiveMemoryPressureWatcher.shared
    /// Second opinion used to clear a stale absence when an OS wake/unlock
    /// notification never arrives. Injectable so tests can drive lock state.
    var userPresenceProbe: any UserPresenceProbing = SystemUserPresenceProbe.shared
    /// How long a freshly recorded absence is left alone before the probe is
    /// allowed to second-guess it. OS notifications can beat the CoreGraphics
    /// state they describe, so revalidating immediately would clear the very
    /// absence the notification just established.
    var absenceRevalidationGrace: Duration = .seconds(10)
    /// Cadence of the slow poll that re-runs revalidation while absent. The
    /// safety net for an absence whose only policy refresh landed inside the
    /// grace window and was skipped there; injectable so tests do not have to
    /// wait out the production cadence.
    var absenceRevalidationPollInterval: Duration = .seconds(30)
    /// SKU-driven feature toggles. Every production, test, and preview caller
    /// must explicitly choose Lite, Pro, or the fail-closed unconfigured state.
    var featureCatalog: FeatureCatalog
    #if LITE_BUILD
    var originReconciler: any OriginReconciler = PreservingOriginReconciler()
    #else
    var originReconciler: any OriginReconciler = WPEOriginReconciler()
    #endif

    static func == (lhs: ScreenManagerStartupOptions, rhs: ScreenManagerStartupOptions) -> Bool {
        lhs.restoreSavedWallpapers == rhs.restoreSavedWallpapers
            && lhs.startAutomation == rhs.startAutomation
            && lhs.featureCatalog == rhs.featureCatalog
    }
}

/// The activity assertion used while at least one wallpaper is actively drawing.
enum WallpaperRenderingActivityPolicy {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
}
