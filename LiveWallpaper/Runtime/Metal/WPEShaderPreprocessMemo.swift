#if !LITE_BUILD
import CryptoKit
import Foundation
import os

enum WPEShaderSourceDigest {
    static func hex(_ source: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(source.utf8))
        return Self.hex(hasher.finalize())
    }

    /// Length-prefix each part so `("ab","c")` and `("a","bc")` cannot share a fingerprint.
    static func pair(vertexSource: String, fragmentSource: String) -> String {
        var hasher = SHA256()
        let vertex = Data(vertexSource.utf8)
        let fragment = Data(fragmentSource.utf8)
        withUnsafeBytes(of: UInt64(vertex.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: vertex)
        withUnsafeBytes(of: UInt64(fragment.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: fragment)
        return Self.hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Missing a key dimension serves one shader's processed source for another.
final class WPEBoundedMemo<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Value
        let cost: Int
    }

    private struct Storage: Sendable {
        var entries: [Key: Entry] = [:]
        // FIFO, not LRU: a scene-load burst touches each key many times, so recency adds nothing.
        var order: [Key] = []
        var totalCost = 0
    }

    private let maxEntries: Int
    private let maxCost: Int
    private let cost: @Sendable (Value) -> Int
    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    init(maxEntries: Int, maxCost: Int, cost: @escaping @Sendable (Value) -> Int) {
        self.maxEntries = maxEntries
        self.maxCost = maxCost
        self.cost = cost
    }

    /// A nil key computes without caching — a placeholder key would serve one shader's output for another.
    /// `compute` runs outside the lock; a throwing compute stores nothing.
    func value(for key: Key?, compute: () throws -> Value) rethrows -> Value {
        guard let key else { return try compute() }
        return try value(for: key, compute: compute)
    }

    func value(for key: Key, compute: () throws -> Value) rethrows -> Value {
        // `.map`, not optional chaining: a stored nil Optional Value must still be a hit.
        if let hit = storage.withLock({ $0.entries[key].map(\.value) }) {
            return hit
        }
        let value = try compute()
        let valueCost = cost(value)
        storage.withLock { state in
            if let previous = state.entries.updateValue(Entry(value: value, cost: valueCost), forKey: key) {
                state.totalCost += valueCost - previous.cost
            } else {
                state.order.append(key)
                state.totalCost += valueCost
            }
            // `count > 1` keeps an oversized just-inserted entry so it can memoize.
            while state.order.count > 1,
                  state.order.count > self.maxEntries || state.totalCost > self.maxCost {
                let oldest = state.order.removeFirst()
                if let removed = state.entries.removeValue(forKey: oldest) {
                    state.totalCost -= removed.cost
                }
            }
        }
        return value
    }
}

/// PMA flags are absent: `makeCompileRequest` applies them after `process`, so they never influence the memoized value.
struct WPEShaderPreprocessMemoKey: Hashable, Sendable {
    let shaderName: String
    let sourceFingerprint: String
    let comboValues: [String: Int]
    let materialTextureBindings: [Int: String]
}

enum WPEShaderPreprocessMemoStore {
    /// Never cleared on reload: clearing from one display would evict a sibling display's mid-load entries.
    static let shared = WPEBoundedMemo<WPEShaderPreprocessMemoKey, WPEShaderCompileRequest>(
        maxEntries: 128,
        maxCost: 8 * 1024 * 1024,
        cost: { $0.processedVertexSource.utf8.count + $0.processedFragmentSource.utf8.count }
    )
}

/// `includeStack` is absent: non-empty stacks skip the memo. Header contents are absent because this memo is per-loader, not process-global.
struct WPEShaderPreprocessSourceKey: Hashable, Sendable {
    let sourceDigest: String
    let logicalPath: String
    let stage: WPEShaderStage
    let comboValues: [String: Int]
}
#endif
