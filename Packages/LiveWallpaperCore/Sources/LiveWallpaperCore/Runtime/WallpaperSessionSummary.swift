import Foundation

public enum WallpaperSessionActivity: Equatable, Sendable {
    case inactive
    case active
    /// User pause — last frame still visible.
    case paused
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

        if configured.contains(where: { $0.activity == .active }) {
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
