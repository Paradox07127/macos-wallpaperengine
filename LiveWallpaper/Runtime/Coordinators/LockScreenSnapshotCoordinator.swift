import AppKit
import Combine
import LiveWallpaperCore

@MainActor
final class LockScreenSnapshotCoordinator {
    private var cleanupTasks: Set<AnyCancellable> = []
    private let onRefresh: @MainActor () -> Void

    init(onRefresh: @escaping @MainActor () -> Void) {
        self.onRefresh = onRefresh
        observeSessionNotifications()
    }

    /// A paused, suspended or unwatched display shows the frame its last capture already holds.
    nonisolated static func shouldCapture(
        globallyEnabled: Bool,
        userPaused: Bool,
        suspended: Bool,
        userAbsent: Bool,
        wallpaperType: WallpaperType,
        setAsLockScreen: Bool
    ) -> Bool {
        globallyEnabled && !userPaused && !suspended && !userAbsent
            && wallpaperType == .video && setAsLockScreen
    }

    private func observeSessionNotifications() {
        // Prepare while unlocked: the password screen may already have cached its background on resign-active.
        // `onRefresh` checks the lock state itself.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                self?.onRefresh()
            }
            .store(in: &cleanupTasks)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.onRefresh()
            }
            .store(in: &cleanupTasks)
    }

    func stop() {
        cleanupTasks.removeAll()
    }
}
