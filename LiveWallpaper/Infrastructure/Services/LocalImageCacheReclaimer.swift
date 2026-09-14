import AppKit
import Foundation
import LiveWallpaperCore
import os

final class LocalImageCacheRegistry: Sendable {

    static let shared = LocalImageCacheRegistry()

    private let purges = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())

    func register<Key: AnyObject, Value: AnyObject>(_ cache: NSCache<Key, Value>) {
        // `NSCache` is documented as thread-safe and `removeAllObjects()` is one
        // of its own operations; it simply is not formally `Sendable`.
        nonisolated(unsafe) let cache = cache
        purges.withLock { $0.append { cache.removeAllObjects() } }
    }

    func purgeAll() {
        for purge in purges.withLock({ $0 }) { purge() }
    }
}

/// The trigger has to be the transition, not the condition: "no window open" is this menu-bar agent's ordinary resting state.
/// Windows are registered explicitly — wallpaper surfaces are `NSWindow`s at `desktopWindow` level, so enumerating `NSApp.windows` would pin the caches or fire when a display is unplugged.
@MainActor
final class LocalImageCacheReclaimer {

    static let shared = LocalImageCacheReclaimer()

    /// Long enough to ride out a close followed straight away by a reopen, and still inside the 15s cadence of `WPEImageCacheMeter`'s report.
    static let defaultDelay = Duration.seconds(10)

    private let delay: Duration
    private let purge: @MainActor () -> Void
    private var openWindows: Set<ObjectIdentifier> = []
    private var pendingPurge: Task<Void, Never>?

    init(
        delay: Duration = LocalImageCacheReclaimer.defaultDelay,
        purge: @escaping @MainActor () -> Void = { LocalImageCacheRegistry.shared.purgeAll() }
    ) {
        self.delay = delay
        self.purge = purge
    }

    func windowDidOpen(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        cancelPendingPurge()
    }

    func windowWillClose(_ window: NSWindow) {
        guard openWindows.remove(ObjectIdentifier(window)) != nil else { return }
        guard openWindows.isEmpty else { return }
        schedulePurge()
    }

    private func schedulePurge() {
        cancelPendingPurge()
        pendingPurge = Task { [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            // Kept as a backstop: if Task.sleep ever stops throwing on cancel-after-deadline, a stale task would purge early and null out its replacement's handle.
            guard !Task.isCancelled else { return }
            self?.purgeIfStillIdle()
        }
    }

    private func purgeIfStillIdle() {
        pendingPurge = nil
        guard openWindows.isEmpty else { return }
        purge()
        Logger.info("Reclaimed local image caches: last window closed", category: .memory)
    }

    private func cancelPendingPurge() {
        pendingPurge?.cancel()
        pendingPurge = nil
    }

    // MARK: - Lifecycle probes for LocalImageCacheReclaimerTests

    var hasOpenWindowsForTesting: Bool { !openWindows.isEmpty }

    var hasPendingPurgeForTesting: Bool { pendingPurge != nil }

    func resetForTesting() {
        cancelPendingPurge()
        openWindows.removeAll()
    }
}
