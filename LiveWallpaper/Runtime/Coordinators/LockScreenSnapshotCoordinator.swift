import AppKit
import Combine

@MainActor
final class LockScreenSnapshotCoordinator {
    private var cleanupTasks: Set<AnyCancellable> = []
    private let onRefresh: @MainActor () -> Void

    init(onRefresh: @escaping @MainActor () -> Void) {
        self.onRefresh = onRefresh
        observeSessionNotifications()
    }

    private func observeSessionNotifications() {
        // Prepare while unlocked: the password screen may already have cached its background on resign-active.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard SystemUserPresenceProbe.shared.screenLockState() == .unlocked else { return }
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
