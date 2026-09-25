import AVFoundation
import Foundation
import LiveWallpaperCore

enum LibraryMetadata: Equatable, Sendable {
    case notApplicable
    case video(Video)

    struct Video: Codable, Equatable, Sendable {
        let resolution: CGSize?
        let isHDR: Bool
        /// Seconds; nil when the asset has no finite duration.
        let duration: TimeInterval?
        /// Bytes on disk, including the whole package for a packaged entry.
        let fileSize: Int64?
        let probedAt: Date
    }

    var resolutionShortLabel: String? {
        guard case let .video(video) = self, let size = video.resolution else { return nil }
        return VideoFormatInfo.resolutionShortLabel(width: Int(size.width), height: Int(size.height))
    }
}

@MainActor
final class LibraryMetadataSidecar {
    typealias Probe = @Sendable (URL, String?) async throws -> LibraryMetadata.Video?

    private struct Key: Codable, Hashable, Sendable {
        let path: String
        let entryName: String?
        /// Size and modification time of the file behind the path. The same path is a different
        /// video after a re-download or a Workshop update, and a record keyed on the path alone
        /// would keep serving the old duration, HDR flag and 4K verdict forever.
        let revision: String?
    }

    private let fileURL: URL
    private let probe: Probe
    private var records: [Key: LibraryMetadata.Video]
    private var pending: [Key: Task<LibraryMetadata.Video?, Never>] = [:]

    init(
        directory: ConfigurationDirectory = ConfigurationDirectory(),
        probe: @escaping Probe = LibraryMetadataSidecar.probeVideo
    ) {
        fileURL = directory.root.appendingPathComponent("library-metadata.json", isDirectory: false)
        self.probe = probe
        records = (try? JSONDecoder().decode(
            [Key: LibraryMetadata.Video].self, from: Data(contentsOf: fileURL)
        )) ?? [:]
    }

    func cached(for bookmark: WallpaperBookmark) -> LibraryMetadata? {
        guard case .video = bookmark.content else { return .notApplicable }
        guard let (key, _) = resource(for: bookmark) else { return nil }
        return records[key].map(LibraryMetadata.video)
    }

    func metadata(for bookmark: WallpaperBookmark) async -> LibraryMetadata? {
        guard case .video = bookmark.content else { return .notApplicable }
        guard let (key, url) = resource(for: bookmark) else { return nil }
        if let record = records[key] {
            return .video(record)
        }
        if let task = pending[key] {
            return await task.value.map(LibraryMetadata.video)
        }

        let probe = probe
        let task = Task.detached(priority: .utility) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try? await probe(url, key.entryName)
        }
        pending[key] = task
        let record = await task.value
        pending[key] = nil
        guard let record else { return nil }
        records[key] = record
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Logger.warning("Library metadata write failed: \(error.localizedDescription)", category: .ui)
        }
        return .video(record)
    }

    private func resource(for bookmark: WallpaperBookmark) -> (Key, URL)? {
        guard case let .video(bookmarkData, entryName) = bookmark.content,
              case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                  bookmarkData, target: .transient
              ) else { return nil }
        return (
            Key(path: resolved.url.path, entryName: entryName, revision: Self.revision(of: resolved.url)),
            resolved.url
        )
    }

    private static func revision(of url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return nil }
        return "\(Int64(modified.timeIntervalSince1970 * 1000)):\(values.fileSize ?? -1)"
    }

    private nonisolated static func probeVideo(url: URL, entryName: String?) async throws -> LibraryMetadata.Video? {
        let asset: AVURLAsset
        let loader: InMemoryVideoAssetLoader?
        let format: VideoFormatInfo?
        if let entryName {
            let result = try InMemoryVideoAssetLoader.loadPackageEntry(packageURL: url, entryName: entryName)
            loader = result.loader
            asset = AVURLAsset(url: result.customURL, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                AVURLAssetAllowsCellularAccessKey: false,
                AVURLAssetAllowsExpensiveNetworkAccessKey: false,
                AVURLAssetAllowsConstrainedNetworkAccessKey: false,
            ])
            asset.resourceLoader.setDelegate(result.loader, queue: DispatchQueue(
                label: "app.livewallpaper.library-metadata-loader", qos: .utility
            ))
        } else {
            loader = nil
            asset = AVURLAsset(url: url)
        }
        // AVFoundation holds its resource-loader delegate weakly across both loads.
        defer { withExtendedLifetime(loader) {} }
        guard try await !(asset.loadTracks(withMediaType: .video)).isEmpty else { return nil }
        if entryName != nil {
            format = try await PlayableVideoLoader.detectFormat(asset: asset)
        } else {
            format = await WallpaperThumbnailService.shared.videoFormatInfo(for: url, cacheKey: url.path)
        }
        guard let format else { return nil }
        let duration = try await asset.load(.duration).seconds
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return LibraryMetadata.Video(
            resolution: format.resolution, isHDR: format.isHDR,
            duration: duration.isFinite ? duration : nil,
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
            probedAt: Date()
        )
    }
}
