#if !LITE_BUILD
import Foundation

/// Exponential 1→2→4→…→30s gaps, give up after `maxAttempts`. Without it a permanently missing file would retry every frame.
struct WPEStaticTextureReloadThrottle: Equatable, Sendable {
    static let maxAttempts = 5
    private(set) var failureCount = 0
    private(set) var nextAttemptUptime: TimeInterval = 0

    var isExhausted: Bool { failureCount >= Self.maxAttempts }

    func allowsAttempt(at uptime: TimeInterval) -> Bool {
        !isExhausted && uptime >= nextAttemptUptime
    }

    mutating func recordFailure(at uptime: TimeInterval) {
        failureCount += 1
        nextAttemptUptime = uptime + min(pow(2, Double(failureCount - 1)), 30)
    }
}

struct WPEMetalTextureCacheLRU: Equatable, Sendable {
    private var core: WPEMetalLRUByteBudget<String>

    var totalBytes: Int { core.totalBytes }
    var entries: [String: WPEMetalLRUByteBudget<String>.Entry] { core.entries }

    init(budgetBytes: Int) {
        core = WPEMetalLRUByteBudget(budgetBytes: budgetBytes)
    }

    mutating func admit(_ key: String, bytes: Int) {
        guard bytes > 0 else {
            core.remove(key)
            return
        }
        core.record(key, bytes: bytes)
    }

    mutating func touch(_ key: String) {
        core.touch(key)
    }

    mutating func remove(_ key: String) {
        core.remove(key)
    }

    mutating func removeAll() {
        core.removeAll()
    }

    /// Never touch a `protected` (active this frame) path — an over-budget frame keeps every active texture rather than evicting one it is about to sample.
    @discardableResult
    mutating func evictOverBudget(protecting protected: Set<String>) -> [String] {
        core.evictOverBudget(protecting: protected)
    }
}
#endif
