#if !LITE_BUILD
import Foundation
import os

/// Process-wide byte-budget LRU for decoded animation frame bytes, shared by every
/// `WPETexLazyAnimatedTextureSource`; replaces the former per-source "4 decoded frames" cap,
/// which scaled with concurrent animation count instead of a budget. Eviction order (WebKit
/// MemoryCache-style): speculative (never-consumed) entries LRU, then consumed entries LRU;
/// per-source pinned (on-screen) IDs are skipped; prunes to ~80% of budget to avoid edge
/// thrashing; frames over the admission cap are never stored (upload-only, held transiently).
/// Thread-safe via one unfair lock; workers store during prefetch, render actors read; entries
/// are `Data`.
final class WPEAnimatedFrameByteCache: @unchecked Sendable {
    struct SourceToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private struct Key: Hashable {
        let source: UInt64
        let imageID: Int
    }

    private struct Entry {
        let bytes: Data
        var lastAccess: UInt64
        var speculative: Bool
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var pinnedImageIDBySource: [UInt64: Int] = [:]
        var totalBytes = 0
        var tick: UInt64 = 0
        var nextSourceID: UInt64 = 1
    }

    static let shared = WPEAnimatedFrameByteCache(
        budgetBytes: WPEMemoryTier.current.animatedFrameCacheBudgetBytes,
        admissionByteCap: WPEMemoryTier.current.animatedFrameAdmissionByteCap,
        respondsToMemoryPressure: true
    )

    let budgetBytes: Int
    let admissionByteCap: Int
    /// Hysteresis target — prune to 80% so the next admissions don't re-trigger.
    private var pruneTargetBytes: Int { budgetBytes * 8 / 10 }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var pressureSource: DispatchSourceMemoryPressure?

    init(budgetBytes: Int, admissionByteCap: Int, respondsToMemoryPressure: Bool = false) {
        self.budgetBytes = max(0, budgetBytes)
        self.admissionByteCap = max(0, admissionByteCap)
        if respondsToMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: DispatchQueue.global(qos: .utility)
            )
            // weak source: the handler must not retain the source it hangs on.
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let event = source.data
                if event.contains(.critical) {
                    self.removeAllUnpinned()
                } else if event.contains(.warning) {
                    self.removeSpeculative()
                }
            }
            source.activate()
            pressureSource = source
        }
    }

    deinit {
        pressureSource?.cancel()
    }

    // MARK: - Source lifecycle

    func registerSource() -> SourceToken {
        state.withLock { state in
            let id = state.nextSourceID
            state.nextSourceID += 1
            return SourceToken(id: id)
        }
    }

    /// Returns the source's lease: drops its entries and its pin.
    func unregisterSource(_ token: SourceToken) {
        removeAll(for: token)
    }

    func removeAll(for token: SourceToken) {
        state.withLock { state in
            state.pinnedImageIDBySource.removeValue(forKey: token.id)
            removeEntries(in: &state) { key, _ in key.source == token.id }
        }
    }

    // MARK: - Store / lookup

    /// Admits the frame unless it exceeds the admission cap. `speculative`
    /// marks prefetched entries that have not yet been consumed on screen.
    /// Returns whether the entry was admitted.
    @discardableResult
    func store(_ bytes: Data, source: SourceToken, imageID: Int, speculative: Bool) -> Bool {
        guard bytes.count <= admissionByteCap else { return false }
        return state.withLock { state in
            let key = Key(source: token(source), imageID: imageID)
            state.tick += 1
            if let existing = state.entries[key] {
                state.totalBytes -= existing.bytes.count
            }
            state.entries[key] = Entry(bytes: bytes, lastAccess: state.tick, speculative: speculative)
            state.totalBytes += bytes.count
            pruneIfNeeded(&state)
            return true
        }
    }

    /// Touches the entry, clears its speculative flag, and pins it as the
    /// source's current on-screen image.
    func lookup(source: SourceToken, imageID: Int) -> Data? {
        state.withLock { state in
            let key = Key(source: token(source), imageID: imageID)
            guard var entry = state.entries[key] else { return nil }
            state.tick += 1
            entry.lastAccess = state.tick
            entry.speculative = false
            state.entries[key] = entry
            state.pinnedImageIDBySource[token(source)] = imageID
            return entry.bytes
        }
    }

    func contains(source: SourceToken, imageID: Int) -> Bool {
        state.withLock { state in
            state.entries[Key(source: token(source), imageID: imageID)] != nil
        }
    }

    /// Pin without lookup — callers set the current frame before upload so a
    /// concurrent prune from another source's admission can't evict it.
    func pin(source: SourceToken, imageID: Int) {
        state.withLock { state in
            state.pinnedImageIDBySource[token(source)] = imageID
        }
    }

    // MARK: - Pressure trims

    /// Warning-level pressure: drop everything prefetched-but-unconsumed.
    func removeSpeculative() {
        state.withLock { state in
            let pinned = pinnedKeys(state)
            removeEntries(in: &state) { key, entry in
                entry.speculative && !pinned.contains(key)
            }
        }
    }

    /// Critical-level pressure: drop everything except the on-screen frames.
    func removeAllUnpinned() {
        state.withLock { state in
            let pinned = pinnedKeys(state)
            removeEntries(in: &state) { key, _ in !pinned.contains(key) }
        }
    }

    // MARK: - Introspection (diagnostics/tests)

    var totalBytes: Int {
        state.withLock { $0.totalBytes }
    }

    var entryCount: Int {
        state.withLock { $0.entries.count }
    }

    func imageIDs(for token: SourceToken) -> Set<Int> {
        state.withLock { state in
            Set(state.entries.keys.filter { $0.source == token.id }.map(\.imageID))
        }
    }

    // MARK: - Internals (caller holds the lock)

    private func token(_ token: SourceToken) -> UInt64 { token.id }

    private func pinnedKeys(_ state: State) -> Set<Key> {
        Set(state.pinnedImageIDBySource.map { Key(source: $0.key, imageID: $0.value) })
    }

    private func removeEntries(in state: inout State, where predicate: (Key, Entry) -> Bool) {
        let victims = state.entries.filter { predicate($0.key, $0.value) }.map(\.key)
        for key in victims {
            if let removed = state.entries.removeValue(forKey: key) {
                state.totalBytes -= removed.bytes.count
            }
        }
    }

    private func pruneIfNeeded(_ state: inout State) {
        guard state.totalBytes > budgetBytes else { return }
        let pinned = pinnedKeys(state)

        func evictLRU(speculativeOnly: Bool) {
            while state.totalBytes > pruneTargetBytes {
                let victim = state.entries
                    .filter { key, entry in
                        !pinned.contains(key) && (!speculativeOnly || entry.speculative)
                    }
                    .min { lhs, rhs in
                        lhs.value.lastAccess != rhs.value.lastAccess
                            ? lhs.value.lastAccess < rhs.value.lastAccess
                            : (lhs.key.source, lhs.key.imageID) < (rhs.key.source, rhs.key.imageID)
                    }?.key
                guard let victim else { return }
                if let removed = state.entries.removeValue(forKey: victim) {
                    state.totalBytes -= removed.bytes.count
                }
            }
        }

        evictLRU(speculativeOnly: true)
        evictLRU(speculativeOnly: false)
    }
}
#endif
