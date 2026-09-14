import AppKit
import Combine

@MainActor
final class LockScreenSnapshotCoordinator {
    private var cleanupTasks: Set<AnyCancellable> = []
    private let onSessionDidResignActive: @MainActor () -> Void

    init(onSessionDidResignActive: @escaping @MainActor () -> Void) {
        self.onSessionDidResignActive = onSessionDidResignActive
        observeSessionNotifications()
    }

    private func observeSessionNotifications() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .sink { [weak self] _ in
                self?.onSessionDidResignActive()
            }
            .store(in: &cleanupTasks)
    }

    func stop() {
        cleanupTasks.removeAll()
    }
}
