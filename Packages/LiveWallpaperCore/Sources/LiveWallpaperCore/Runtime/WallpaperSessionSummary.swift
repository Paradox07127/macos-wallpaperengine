import Foundation

public enum WallpaperSessionActivity: Equatable, Sendable {
    case inactive
    case active
    /// User pause — last frame still visible.
    case paused
    /// Held down by system policy (heat, memory, absence, a rule), not by the user.
    /// Must stay distinct from `.paused`: status text names the policy hold only for this case.
    case policySuspended
    /// Rebuilding what a deep hibernate released: nothing is holding it down, so it must
    /// not be reported as suspended.
    case restoring
    /// Master switch off — desktop shows through (not last frame).
    case off
    case error
}

public struct WallpaperSessionSummary: Equatable, Sendable {
    public let wallpaperType: WallpaperType?
    public let activity: WallpaperSessionActivity
    public let supportsPlaybackControl: Bool
    public let subtitle: String?

    public init(
        wallpaperType: WallpaperType?,
        activity: WallpaperSessionActivity,
        supportsPlaybackControl: Bool,
        subtitle: String?
    ) {
        self.wallpaperType = wallpaperType
        self.activity = activity
        self.supportsPlaybackControl = supportsPlaybackControl
        self.subtitle = subtitle
    }

    public static let notConfigured = WallpaperSessionSummary(
        wallpaperType: nil,
        activity: .inactive,
        supportsPlaybackControl: false,
        subtitle: nil
    )

    public var isConfigured: Bool {
        wallpaperType != nil && activity != .inactive
    }
}

public enum WallpaperOverviewStatus: Equatable, Sendable {
    case notConfigured
    case active
    case paused
    case off
    case error
}

public enum WallpaperStatusAggregator {
    /// active > error > all-off > paused.
    public static func overview(for summaries: [WallpaperSessionSummary]) -> WallpaperOverviewStatus {
        let configured = summaries.filter(\.isConfigured)
        guard !configured.isEmpty else {
            return .notConfigured
        }

        // `.restoring` counts as active: falling through to `.paused` would draw the pause
        // glyph and announce a paused wallpaper mid-restore.
        if configured.contains(where: { $0.activity == .active || $0.activity == .restoring }) {
            return .active
        }
        if configured.contains(where: { $0.activity == .error }) {
            return .error
        }
        if configured.allSatisfy({ $0.activity == .off }) {
            return .off
        }
        return .paused
    }
}
