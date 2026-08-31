import AppKit
import Foundation
import LiveWallpaperCore
import os

/// The image caches whose every entry can be rebuilt from a file this app
/// already holds on disk, so dropping one costs a re-decode and never a
/// re-download. Network-backed caches deliberately stay out. `Sendable`: the only stored property is an `OSAllocatedUnfairLock`, which serialises every read and write of the state it wraps.
final class LocalImageCacheRegistry: Sendable {

    static let shared = LocalImageCacheRegistry()

    private let purges = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())

    /// Register from the cache's own initializer: these caches are lazy
    /// statics, and one that was never built holds nothing to reclaim, so
    /// first-touch registration already covers the whole population.
    func register<Key: AnyObject, Value: AnyObject>(_ cache: NSCache<Key, Value>) {
        // `NSCache` is documented as thread-safe and `removeAllObjects()` is one
        // of its own operations; it simply is not formally `Sendable`.
        nonisolated(unsafe) let cache = cache
        purges.withLock { $0.append { cache.removeAllObjects() } }
    }

    /// Empties every registered cache. `removeAllObjects()` reports each entry
    /// through `NSCacheDelegate`, so a meter attached to these caches nets back
    /// to zero on its own rather than needing to be told.
    func purgeAll() {
        for purge in purges.withLock({ $0 }) { purge() }
    }
}

/// Drops the local-source image caches once the app's last user-visible window has stayed closed for `delay`. The trigger has to be the *transition*, not the condition: this is a menu-bar agent, so "no window open" is its ordinary resting state.
/// Windows are therefore registered explicitly by whoever presents them instead of being discovered from `NSApp.windows` — the wallpaper surfaces are `NSWindow`s too, living at `desktopWindow` level, and enumerating would either pin the caches for as long as a wallpaper is on screen or fire the purge when a display is unplugged. A window this type was never told about takes no part in the decision.
@MainActor
final class LocalImageCacheReclaimer {

    static let shared = LocalImageCacheReclaimer()

    /// Long enough to ride out a close followed straight away by a reopen, and
    /// still inside the 15s cadence of `WPEImageCacheMeter`'s report, so the
    /// drop shows up whole in the next line rather than smeared across two.
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
            // Redundant today, kept as a backstop. A superseded task cannot get
            // here: cancelling after the sleep has already elapsed still makes
            // the resumption throw, so the `catch` above returns first —
            // probed on macOS 27 by blocking the main actor past the deadline, then cancelling. That's a runtime detail of `Task.sleep`, not a documented guarantee; if it ever changes, the stale task would purge early AND null out its replacement's handle, so this one-line guard stays.
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

    /// Leaves `shared` as a fresh process would have it, so a test that drove
    /// the real singleton cannot arm a purge for the tests that follow it.
    func resetForTesting() {
        cancelPendingPurge()
        openWindows.removeAll()
    }
}
