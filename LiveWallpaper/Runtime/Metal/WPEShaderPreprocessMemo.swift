#if !LITE_BUILD
import CryptoKit
import Foundation
import os

/// SHA-256 over shader text, used to keep whole sources out of memo keys.
enum WPEShaderSourceDigest {
    static func hex(_ source: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(source.utf8))
        return Self.hex(hasher.finalize())
    }

    /// Fingerprint of a (vertex, fragment) pair. Each part is length-prefixed so
    /// no pair of sources can be re-cut into a different pair with the same
    /// fingerprint — a plain concatenation would let `("ab", "c")` and
    /// `("a", "bc")` collide, which in this key means one shader's processed
    /// source is served for another.
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

/// Bounded FIFO memo shared by the two GLSL preprocess stages.
///
/// Both stages sit UPSTREAM of every shader cache (`WPEShaderTranslationCache`
/// keys on the preprocessor's output), so a warm disk cache still pays them in
/// full. One scene re-runs the same preprocess dozens of times — measured at 174
/// stage-4 calls over 17 distinct shader names, with `effects/waterwaves` alone
/// preprocessed 92 times — because a shader is re-derived per PASS, not per name.
///
/// Correctness rests entirely on the key: a missing key dimension hands two
/// different shaders the same processed source and renders the wrong thing with
/// no error anywhere. Each memo's key is documented at its construction site.
/// Given a complete key the stored value is a pure function of it, so an entry
/// can never go stale — the bound below exists only to cap memory, and eviction
/// costs nothing but a recomputation.
final class WPEBoundedMemo<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Value
        let cost: Int
    }

    private struct Storage: Sendable {
        var entries: [Key: Entry] = [:]
        /// Insertion order, oldest first. FIFO rather than LRU: one scene load
        /// touches each key a few dozen times in a burst, so recency carries no
        /// information the insertion order does not.
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

    /// `compute` runs OUTSIDE the lock — the same reasoning the sibling
    /// `TextureFormatProbeCache` uses: a duplicate concurrent computation is
    /// idempotent for a complete key, and far cheaper than serializing the whole
    /// preprocessor behind one lock while the pre-warm fans out over passes.
    /// A throwing `compute` stores nothing.
    /// A `nil` key means the caller could not establish the value's identity, so
    /// compute without caching — storing under a placeholder key is how a memo
    /// serves one shader's output for another.
    func value(for key: Key?, compute: () throws -> Value) rethrows -> Value {
        guard let key else { return try compute() }
        return try value(for: key, compute: compute)
    }

    func value(for key: Key, compute: () throws -> Value) rethrows -> Value {
        // `.map`, not optional chaining: for an Optional `Value` a stored `nil`
        // must still be a hit, or a memoised "no builtin for this name" re-runs
        // the resolver on every pass.
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
            // `count > 1` keeps the entry just inserted even when it alone
            // exceeds the budget; otherwise an oversized shader would evict
            // itself on every call and never memoize.
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

/// Key for the stage-4 memo (`WPEMetalRenderExecutor.makeCompileRequest` →
/// `WPEShaderPreprocessor.process`). Every one of `process`'s five parameters is
/// represented, and nothing else may be added:
///
/// - `shaderName` — hashed into `WPEShaderCompileRequest.sourceHash` and carried
///   on the request, so two passes running different shaders must not share.
/// - `sourceFingerprint` — stands in for the `vertexSource` + `fragmentSource`
///   pair (`WPEShaderProgram.sourceFingerprint`, computed once when the program
///   is built rather than re-hashed per pass).
/// - `comboValues` — merged into the `#define` preamble AND into `sourceHash`.
/// - `materialTextureBindings` — merged into `textureBindings`, which decides
///   which MTL slot each `g_TextureN` samples.
///
/// Deliberately absent: the premultiplied-alpha flags. `makeCompileRequest`
/// applies those with `replacingPremultipliedAlphaSettings` AFTER `process`
/// returns, so they never influence the memoized value.
struct WPEShaderPreprocessMemoKey: Hashable, Sendable {
    let shaderName: String
    let sourceFingerprint: String
    let comboValues: [String: Int]
    let materialTextureBindings: [Int: String]
}

enum WPEShaderPreprocessMemoStore {
    /// Process-global and never cleared, for the same reason
    /// `WPEMetalRenderExecutor.translatedShaderCache` is never cleared on reload:
    /// the key is content-complete, so an entry surviving a scene change can only
    /// be a hit for identical content. Clearing it from one display's
    /// `releaseTransientResources` would also evict a sibling display's
    /// just-warmed entries mid-load, since scene loads overlap across displays.
    ///
    /// The budget is the bound. Entries hold fully include-expanded GLSL (tens of
    /// KB per stage), so the byte cap is what actually limits growth; the entry
    /// cap only stops a pathological scene of tiny shaders.
    static let shared = WPEBoundedMemo<WPEShaderPreprocessMemoKey, WPEShaderCompileRequest>(
        maxEntries: 128,
        maxCost: 8 * 1024 * 1024,
        cost: { $0.processedVertexSource.utf8.count + $0.processedFragmentSource.utf8.count }
    )
}

/// Key for the stage-3 memo (`WPEShaderSourceLoader.preprocess` — include
/// expansion + prelude + stage rewrite).
///
/// - `sourceDigest` — the raw stage source. Hashed rather than stored so the
///   memo does not retain a second copy of every shader.
/// - `logicalPath` — decides where a relative `#include` resolves
///   (`localIncludePath` uses the requesting file's directory), so the same
///   source text under two paths can expand to different GLSL.
/// - `stage` — picks the prelude and the `gl_FragColor` → `out_FragColor` rewrite.
/// - `comboValues` — emitted as `#define`s in the prelude and consulted by
///   `implicitConditionalDefines`.
///
/// Deliberately absent: `includeStack`. Recursion lives in `expandIncludes`, so
/// every call into `preprocess` is a top-level expansion with an empty stack;
/// the memo is skipped outright for a non-empty stack, which keeps the stack out
/// of the key by construction instead of by convention.
///
/// Also absent: the CONTENTS of the included headers. That is sound only because
/// this memo is an instance property of `WPEShaderSourceLoader`, i.e. one memo
/// per builder per scene build, whose resolver is fixed for its whole lifetime —
/// the same argument the sibling `TextureFormatProbeCache` makes for keying on a
/// bare path. A process-global stage-3 memo would be wrong.
struct WPEShaderPreprocessSourceKey: Hashable, Sendable {
    let sourceDigest: String
    let logicalPath: String
    let stage: WPEShaderStage
    let comboValues: [String: Int]
}
#endif
