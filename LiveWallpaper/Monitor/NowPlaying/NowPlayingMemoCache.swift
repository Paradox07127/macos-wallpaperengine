#if !MAS_BUILD
import Foundation

struct NowPlayingMemoCache<Value: Sendable> {
    let capacity: Int
    let negativeTTL: TimeInterval

    private var cache: [String: Value] = [:]
    /// Least-recently-used first.
    private var order: [String] = []
    /// Key → expiry instant.
    private var negative: [String: Date] = [:]
    var inFlight: [String: Task<Value?, Never>] = [:]

    init(capacity: Int, negativeTTL: TimeInterval) {
        self.capacity = capacity
        self.negativeTTL = negativeTTL
    }

    /// Positive-cache-only lookup; a hit becomes most recently used.
    mutating func cached(_ key: String) -> Value? {
        guard let value = cache[key] else { return nil }
        touch(key)
        return value
    }

    /// True while a failed lookup for `key` is inside its TTL; an expired
    /// entry is dropped on the way out.
    mutating func isNegative(_ key: String, now: Date) -> Bool {
        pruneNegative(now: now)
        return negative[key] != nil
    }

    /// A cancelled task's nil is neither a hit nor a miss, and `cancelInFlight`
    /// already dropped it from `inFlight` — removing the key here would evict
    /// the replacement task registered under it since.
    mutating func finish(key: String, result: Value?, cancelled: Bool, now: Date) {
        if cancelled {
            return
        }
        inFlight.removeValue(forKey: key)
        if let result {
            negative.removeValue(forKey: key)
            cache[key] = result
            touch(key)
            while order.count > capacity {
                cache.removeValue(forKey: order.removeFirst())
            }
        } else {
            negative[key] = now.addingTimeInterval(negativeTTL)
        }
        pruneNegative(now: now)
    }

    private mutating func pruneNegative(now: Date) {
        negative = negative.filter { $0.value > now }
        while negative.count > capacity, let oldest = negative.min(by: { $0.value < $1.value })?.key {
            negative.removeValue(forKey: oldest)
        }
    }

    /// Drops every merged fetch except the one the caller still wants. Without
    /// this, skipping through a playlist leaves one live download per skipped
    /// track: the callers go away, but the merged task they shared does not.
    mutating func cancelInFlight(except key: String?) {
        for (running, task) in inFlight where running != key {
            task.cancel()
            inFlight.removeValue(forKey: running)
        }
    }

    private mutating func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}
#endif
