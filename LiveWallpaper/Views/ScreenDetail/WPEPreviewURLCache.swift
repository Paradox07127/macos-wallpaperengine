#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Observation

/// Preview paths resolved once per (bookmark, preview file) off the main thread, so a
/// card is handed its URL synchronously and never re-resolves when it scrolls back in.
@MainActor
@Observable
final class WPEPreviewURLCache {
    private struct Key: Hashable {
        let bookmark: Data
        let previewFileName: String?

        init(_ origin: WPEOrigin) {
            bookmark = origin.sourceFolderBookmark
            previewFileName = origin.previewFileName
        }
    }

    static let shared = WPEPreviewURLCache()

    /// Plain file paths: readers re-scope access through the bookmark themselves and
    /// never start it on these instances. `.some(nil)` = resolved, no preview.
    private var resolved: [Key: URL?] = [:]
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private let resolve: @Sendable (WPEOrigin) -> URL?

    init(resolve: @escaping @Sendable (WPEOrigin) -> URL? = { $0.sourcePreviewURL }) {
        self.resolve = resolve
    }

    func url(for origin: WPEOrigin) -> URL? {
        resolved[Key(origin)] ?? nil
    }

    /// Resolves every origin not yet known in one background task and publishes them together.
    func prefetch(_ entries: [WPEHistoryEntry]) {
        var pending: [WPEOrigin] = []
        var keys = Set<Key>()
        for entry in entries {
            let key = Key(entry.origin)
            guard resolved[key] == nil, !inFlight.contains(key), keys.insert(key).inserted else { continue }
            pending.append(entry.origin)
        }
        guard !pending.isEmpty else { return }
        inFlight.formUnion(keys)
        let origins = pending
        let resolve = resolve
        Task {
            let urls = await Task.detached(priority: .utility) {
                origins.map { ($0, resolve($0)) }
            }.value
            var next = resolved
            for (origin, url) in urls {
                let key = Key(origin)
                next[key] = .some(url)
                inFlight.remove(key)
            }
            resolved = next
        }
    }
}
#endif
