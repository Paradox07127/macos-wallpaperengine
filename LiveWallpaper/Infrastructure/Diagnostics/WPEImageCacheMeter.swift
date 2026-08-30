import Foundation
import LiveWallpaperCore
import os

/// Which image `NSCache` a measurement belongs to. Labels are log tokens and are
/// deliberately non-substrings of one another so a report line can be parsed.
enum WPEImageCacheKind: Int, CaseIterable, Sendable {
    case workshopPreview
    case scenePreviewDecoded
    case wallpaperThumbnail
    case systemWallpaperLibrary

    var label: String {
        switch self {
        case .workshopPreview: "workshopPreview"
        case .scenePreviewDecoded: "scenePreview"
        case .wallpaperThumbnail: "wallpaperThumb"
        case .systemWallpaperLibrary: "systemLibrary"
        }
    }
}

/// Standing occupancy of one image cache, plus the two counters that say which
/// direction the number can be wrong in.
struct WPEImageCacheStats: Equatable, Sendable {
    var liveBytes = 0
    var liveCount = 0
    var inserted = 0
    var evicted = 0
    /// Eviction callbacks that found no ledger entry, i.e. an insert this meter
    /// never saw. Each one is evidence that `liveBytes` was a *lower* bound
    /// while that object was live — an insert site is missing a `recordInsert`.
    var unattributedEvictions = 0
    /// Inserts of an instance already live in the same cache. `NSCache` reports
    /// only one eviction for an instance held under several keys (measured on
    /// macOS 27), so each of these makes `liveBytes` an *upper* bound.
    var duplicateInserts = 0

    /// Never touched, as opposed to churned back down to zero.
    var isUntouched: Bool { inserted == 0 && evicted == 0 }
}

/// Live-stock accounting for the app's image caches. `NSCache` exposes neither occupancy nor an evicted object's cost, so cost is recorded here at insert time and looked up by object identity when `NSCacheDelegate` reports the eviction.
/// Subtraction is therefore byte-identical to the addition — no cost formula is ever re-run — which is what lets `NSImage` (a foreign class with no room for a stored property) be metered at all.
/// `liveBytes` is exact exactly when `duplicateInserts` and `unattributedEvictions` are both zero, and the report prints both. A ledger entry can only outlive its object when one instance occupies several cache slots (`NSCache` then reports one eviction, not one per slot — measured on macOS 27), and that case is already flagged at insert time, before the under-report can happen.
/// `Sendable`: the only stored property is an `OSAllocatedUnfairLock`, which serialises every read and write of the state it wraps.
final class WPEImageCacheAccountant: Sendable {

    private struct State {
        var stats = [WPEImageCacheStats](
            repeating: WPEImageCacheStats(), count: WPEImageCacheKind.allCases.count
        )
        /// Per cache, the insert-time costs of every slot a live instance
        /// occupies. A stack rather than a single value so that one instance
        /// cached under several keys still nets out to zero once every slot has
        /// been reported.
        var ledgers = [[ObjectIdentifier: [Int]]](
            repeating: [:], count: WPEImageCacheKind.allCases.count
        )
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Installs the metering delegate on `cache`; the cache's own limits and
    /// eviction policy are untouched. `NSCache.delegate` is declared `assign`
    /// (`unowned(unsafe)`), not `weak`, and drains through that pointer on
    /// dealloc — a released delegate is a hard crash, not a silent no-op — so the probe is parked in a process-wide registry and never released.
    func attach<Key: AnyObject, Value: AnyObject>(
        _ cache: NSCache<Key, Value>, as kind: WPEImageCacheKind
    ) {
        let probe = WPEImageCacheEvictionProbe { [weak self] identity in
            self?.recordEviction(identity, in: kind)
        }
        WPEImageCacheEvictionProbe.parkForProcessLifetime(probe)
        cache.delegate = probe
    }

    /// Call this *before* `setObject`. `setObject` can synchronously evict the
    /// very object it is inserting (when the cost alone blows `totalCostLimit`),
    /// and an eviction arriving before its own insert would be unattributable —
    /// leaving the cost added afterwards with nothing left to remove it.
    func recordInsert(_ object: AnyObject, cost: Int, in kind: WPEImageCacheKind) {
        let identity = ObjectIdentifier(object)
        state.withLock { state in
            let slot = kind.rawValue
            if state.ledgers[slot][identity] != nil {
                state.stats[slot].duplicateInserts += 1
            }
            state.ledgers[slot][identity, default: []].append(cost)
            state.stats[slot].liveBytes += cost
            state.stats[slot].liveCount += 1
            state.stats[slot].inserted += 1
        }
    }

    /// Identity only: the meter never retains, inspects, or otherwise keeps the
    /// evicted object alive past the callback.
    func recordEviction(_ identity: ObjectIdentifier, in kind: WPEImageCacheKind) {
        state.withLock { state in
            let slot = kind.rawValue
            state.stats[slot].evicted += 1
            guard var costs = state.ledgers[slot][identity], let cost = costs.popLast() else {
                state.stats[slot].unattributedEvictions += 1
                return
            }
            state.ledgers[slot][identity] = costs.isEmpty ? nil : costs
            state.stats[slot].liveBytes -= cost
            state.stats[slot].liveCount -= 1
        }
    }

    func stats(for kind: WPEImageCacheKind) -> WPEImageCacheStats {
        state.withLock { $0.stats[kind.rawValue] }
    }

    /// One line naming only the caches that have recorded something, with the
    /// bound markers spelled out so a reader never has to guess whether the
    /// byte figure is exact.
    /// Returns `nil` when no cache has recorded anything.
    func report() -> String? {
        let snapshot = state.withLock { $0.stats }
        var line = "[imgcache]"
        var named = false
        for kind in WPEImageCacheKind.allCases {
            let stats = snapshot[kind.rawValue]
            guard !stats.isUntouched else { continue }
            named = true
            let mib = String(format: "%.2f", Double(stats.liveBytes) / (1024 * 1024))
            line += " \(kind.label)=\(mib)MiB/\(stats.liveCount)"
            line += "(in:\(stats.inserted) ev:\(stats.evicted)"
            if stats.duplicateInserts > 0 {
                line += " dup:\(stats.duplicateInserts)=UPPER-BOUND"
            }
            if stats.unattributedEvictions > 0 {
                line += " unattributed:\(stats.unattributedEvictions)=LOWER-BOUND"
            }
            line += ")"
        }
        return named ? line : nil
    }
}

/// Bridges `NSCacheDelegate` to a closure that only ever sees an identity.
///
/// `Sendable`: final, superclass `NSObject`, and its one stored property is an
/// immutable `@Sendable` closure.
final class WPEImageCacheEvictionProbe: NSObject, NSCacheDelegate, Sendable {

    private let onEvict: @Sendable (ObjectIdentifier) -> Void

    init(onEvict: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.onEvict = onEvict
        super.init()
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        onEvict(ObjectIdentifier(obj as AnyObject))
    }

    private static let parked = OSAllocatedUnfairLock(
        initialState: [WPEImageCacheEvictionProbe]()
    )

    /// See `WPEImageCacheAccountant.attach` for why these are never released.
    /// Bounded in practice: four caches in the app, one per `attach` in tests.
    static func parkForProcessLifetime(_ probe: WPEImageCacheEvictionProbe) {
        parked.withLock { $0.append(probe) }
    }
}

/// Opt-in via `WPEImageCacheLog`; disabled cost is one cached bool check.
/// Answers "which image cache is holding the app's idle footprint" by reporting
/// standing occupancy (live bytes and live object count per cache) rather than
/// a rate — `inserted`/`evicted` come along to show turnover.
enum WPEImageCacheMeter {

    static let isEnabled: Bool = {
        // XCTest hosts `appSuite` as the real `com.loomscreen.pro` domain, so a
        // live metering session would leak into tests. Isolated scratch only.
        let suites: [UserDefaults] = NSClassFromString("XCTestCase") != nil
            ? [UserDefaults.appScoped()]
            : [UserDefaults.appSuite, UserDefaults.standard]
        for suite in suites where suite.object(forKey: "WPEImageCacheLog") != nil {
            return suite.bool(forKey: "WPEImageCacheLog")
        }
        return false
    }()

    static let shared = WPEImageCacheAccountant()

    private static let reportInterval = Duration.seconds(15)

    static func attach<Key: AnyObject, Value: AnyObject>(
        _ cache: NSCache<Key, Value>, as kind: WPEImageCacheKind
    ) {
        guard isEnabled else { return }
        shared.attach(cache, as: kind)
        startReporter()
    }

    static func recordInsert(_ object: AnyObject, cost: Int, in kind: WPEImageCacheKind) {
        guard isEnabled else { return }
        shared.recordInsert(object, cost: cost, in: kind)
    }

    private static let reporterStarted = OSAllocatedUnfairLock(initialState: false)

    /// Clock-driven, not traffic-driven: an idle app inserts nothing, and idle
    /// is exactly when the standing occupancy needs to be read.
    private static func startReporter() {
        let alreadyRunning = reporterStarted.withLock { started -> Bool in
            if started { return true }
            started = true
            return false
        }
        guard !alreadyRunning else { return }
        Task.detached(priority: .utility) {
            while true {
                do {
                    try await Task.sleep(for: reportInterval)
                } catch {
                    return
                }
                if let report = shared.report() {
                    Logger.notice(report, category: .memory)
                }
            }
        }
    }
}
