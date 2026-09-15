import Foundation
@preconcurrency import AVFoundation
import LiveWallpaperCore

@MainActor
final class MetadataService {
    static let shared = MetadataService()

    private var cache: [String: RowMetadata] = [:]
    let requests: PreviewRequestPool<RowMetadata>
    private let load: @MainActor @Sendable (Data) async -> RowMetadata
    private let cacheLimit = 256

    init(
        gate: PreviewWorkGate = PreviewWorkGate(limit: 2),
        load: @escaping @MainActor @Sendable (Data) async -> RowMetadata = MetadataService.loadMetadata
    ) {
        requests = PreviewRequestPool(gate: gate)
        self.load = load
    }

    /// Shared consumers keep one bounded producer alive until the last row leaves.
    func metadata(for bookmark: Data) async -> RowMetadata {
        guard !Task.isCancelled else { return .empty }
        let key = cacheKey(for: bookmark)
        if let cached = cache[key] {
            return cached
        }
        return await requests.value(for: key) { [self] in
            let result = await load(bookmark)
            // An invalidated producer can finish after its replacement. It must
            // neither publish to a row nor repopulate the invalidated cache.
            guard !Task.isCancelled else { return nil }
            if result != .empty {
                storeInCache(result, for: key)
            }
            return result
        } ?? .empty
    }

    func invalidate(_ bookmark: Data) {
        let key = cacheKey(for: bookmark)
        cache.removeValue(forKey: key)
        requests.invalidate(key)
    }

    private func storeInCache(_ value: RowMetadata, for key: String) {
        if cache.count >= cacheLimit {
            if let victim = cache.keys.randomElement() {
                cache.removeValue(forKey: victim)
            }
        }
        cache[key] = value
    }

    private func cacheKey(for bookmark: Data) -> String {
        bookmark.base64EncodedString()
    }

    // MARK: - Loader

    private nonisolated static func loadMetadata(for bookmark: Data) async -> RowMetadata {
        guard let resolved = await LibraryContentLocator.resolvePreviewBookmark(bookmark),
              !Task.isCancelled else {
            return .empty
        }
        let url = resolved.url
        let folder = url.deletingLastPathComponent().lastPathComponent

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: url)
        async let durationLoad: CMTime? = {
            try? await asset.load(.duration)
        }()
        async let resolutionLoad: CGSize? = await Self.loadResolution(from: asset)

        let durationTime = await durationLoad
        let resolution = await resolutionLoad
        let seconds = durationTime.flatMap { time -> TimeInterval? in
            let raw = CMTimeGetSeconds(time)
            return raw.isFinite && raw > 0 ? raw : nil
        }

        return RowMetadata(
            resolution: resolution,
            duration: seconds,
            folder: folder
        )
    }

    private nonisolated static func loadResolution(from asset: AVURLAsset) async -> CGSize? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first
        else { return nil }
        guard let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let transformed = size.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
