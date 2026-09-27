import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
protocol DisplayConfigurationCommitting {
    func save(_ configuration: ScreenConfiguration)
    func remove(for screenID: CGDirectDisplayID)
}

@MainActor
final class DisplayConfigurationController: DisplayConfigurationCommitting {
    private let store: WallpaperConfigurationStore
    private let bookmarkDisplayNameCache: BookmarkDisplayNameCache
    private let releaseRuntimeSession: @MainActor (CGDirectDisplayID) -> Void
    private let notifyWallpaperSessionChanged: @MainActor () -> Void
    private let advanceSceneMutationIntent: @MainActor (CGDirectDisplayID) -> Void
    private let now: @MainActor () -> Date
    private let calendar: @MainActor () -> Calendar
    private let notificationCenter: NotificationCenter

    init(
        store: WallpaperConfigurationStore,
        bookmarkDisplayNameCache: BookmarkDisplayNameCache,
        releaseRuntimeSession: @MainActor @escaping (CGDirectDisplayID) -> Void,
        notifyWallpaperSessionChanged: @MainActor @escaping () -> Void,
        advanceSceneMutationIntent: @MainActor @escaping (CGDirectDisplayID) -> Void,
        now: @MainActor @escaping () -> Date = Date.init,
        calendar: @MainActor @escaping () -> Calendar = { .current },
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.bookmarkDisplayNameCache = bookmarkDisplayNameCache
        self.releaseRuntimeSession = releaseRuntimeSession
        self.notifyWallpaperSessionChanged = notifyWallpaperSessionChanged
        self.advanceSceneMutationIntent = advanceSceneMutationIntent
        self.now = now
        self.calendar = calendar
        self.notificationCenter = notificationCenter
    }

    func save(_ configuration: ScreenConfiguration) {
        advanceSceneMutationIntent(configuration.screenID)
        let committed = SchedulePolicy.holdingManualChange(
            configuration, previous: store.get(for: configuration.screenID),
            now: now(), calendar: calendar()
        )
        primeDisplayNames(from: committed)
        store.save(committed)
        postChange(for: configuration.screenID)
    }

    func remove(for screenID: CGDirectDisplayID) {
        store.remove(for: screenID)
        postChange(for: screenID)
    }

    func primeDisplayNames(from configuration: ScreenConfiguration) {
        bookmarkDisplayNameCache.prime(bookmarks: Self.videoBookmarks(in: configuration))
    }

    @discardableResult
    func pruneInvalidConfigurations() -> [CGDirectDisplayID] {
        let removed = store.pruneInvalidResourceConfigurations(
            using: SettingsManager.shared.validateConfiguration
        )
        guard !removed.isEmpty else { return [] }
        for screenID in removed {
            releaseRuntimeSession(screenID)
            postChange(for: screenID)
        }
        notifyWallpaperSessionChanged()
        return removed
    }

    /// Next main-actor tick so subscribers run outside the current SwiftUI reconcile.
    private func postChange(for screenID: CGDirectDisplayID) {
        Task { @MainActor [notificationCenter] in
            notificationCenter.post(
                name: .wallpaperConfigurationDidChange,
                object: nil,
                userInfo: ["screenID": screenID]
            )
        }
    }

    private static func videoBookmarks(in configuration: ScreenConfiguration) -> [Data] {
        var result: [Data] = []
        var seen: Set<Data> = []

        func append(_ bookmarkData: Data?) {
            guard let bookmarkData,
                  !bookmarkData.isEmpty,
                  seen.insert(bookmarkData).inserted else { return }
            result.append(bookmarkData)
        }

        if case .video(let bookmarkData, _) = configuration.activeWallpaper {
            append(bookmarkData)
        }
        append(configuration.savedVideoBookmarkData)
        configuration.playlistBookmarks?.forEach { append($0) }
        configuration.wallpaperQueue?.forEach { append($0.content.activeVideoBookmarkData) }
        append(configuration.scheduleFallback?.content.activeVideoBookmarkData)
        configuration.scheduleSlots?.forEach {
            append($0.videoBookmarkData)
            append($0.wallpaper?.content.activeVideoBookmarkData)
        }

        return result
    }
}
