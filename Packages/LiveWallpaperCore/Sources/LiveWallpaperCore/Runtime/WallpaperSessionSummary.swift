import Foundation

public enum WallpaperSessionActivity: Equatable, Sendable {
    case inactive
    case active
    /// User pause — last frame still visible.
    case paused
    /// Held down by system policy (heat, memory, absence, a rule) rather than by
    /// the user. Distinct from `.paused` because the play button is drawn from
    /// this: collapsing the two made a suspended wallpaper show a Play button
    /// whose tap then cleared the user's intent.
    case policySuspended
    /// Rebuilding what a deep hibernate released. Nothing is holding it down —
    /// it is on its way back — so reporting it as suspended told the user the
    /// opposite of what was happening.
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

        // `.restoring` counts as active: the wallpaper is rebuilding itself back
        // into view, and falling through to `.paused` drew the pause glyph and
        // had VoiceOver announce a paused wallpaper mid-restore.
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
