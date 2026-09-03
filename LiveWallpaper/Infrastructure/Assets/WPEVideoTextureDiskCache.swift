#if !LITE_BUILD
import AVFoundation
import Foundation
import CryptoKit
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Content-addressed disk cache for `.tex` video MP4s (`wpe-tex-video/<id>/<sha256>.mp4`).
/// Leased while live; orphans/LRU/`purgeAll` reclaim only non-leased files.
actor WPEVideoTextureDiskCache {
    static let shared = WPEVideoTextureDiskCache()

    /// LRU disk ceiling (source of truth remains the scene `.tex`).
    static let defaultMaxBytes: UInt64 = 2 * 1024 * 1024 * 1024  // 2 GiB

    /// Local-import bucket; always reclaimed by launch GC.
    static let unattributedBucket = "_unattributed"

    /// Audio-strip export scratch file. Hidden, so it is not LRU-evictable
    /// while the export writes it; swept by age instead.
    static let stripPrefix = ".strip-"
    /// An export that has not finished in this long lost its process.
    static let stripTemporaryMaxAge: TimeInterval = 60 * 60

    private let rootURL: URL
    private let fileManager: FileManager
    private let maxBytes: UInt64

    /// Live lease refcounts (content-addressing can share one file across sources).
    private var leaseCounts: [String: Int] = [:]

    /// Keys whose audio strip failed this launch — don't re-attempt a multi-second
    /// export on every load of the same scene.
    private var audioStripFailedKeys: Set<String> = []

    init(rootURL: URL? = nil, maxBytes: UInt64 = WPEVideoTextureDiskCache.defaultMaxBytes) {
        self.fileManager = .default
        self.rootURL = (rootURL ?? Self.defaultRootURL).standardizedFileURL
        self.maxBytes = maxBytes
    }

    nonisolated static var defaultRootURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-tex-video", isDirectory: true)
    }

    // MARK: - Store / lease

    /// Store/reuse by SHA-256 of the ORIGINAL bytes; returns a leased URL and
    /// refreshes LRU mtime. The stored file may be smaller than `data`: the
    /// audio track is stripped at write time (see `stripAudioTrackIfNeeded`),
    /// which is also why the hit check cannot compare sizes.
    func store(_ data: Data, workshopID: String) async throws -> URL {
        let bucketURL = rootURL.appendingPathComponent(bucketName(for: workshopID), isDirectory: true)
        try fileManager.createDirectory(at: bucketURL, withIntermediateDirectories: true)

        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = bucketURL.appendingPathComponent("\(hex).mp4").standardizedFileURL

        if fileExists(target) {
            touch(target)
        } else {
            try data.write(to: target, options: [.atomic])
        }
        // Lease BEFORE the strip: the export suspends this actor, and a
        // concurrently running orphan GC or LRU pass would otherwise see an
        // unleased file and delete it mid-export (guaranteed for the
        // `_unattributed` bucket, which GC never keeps by reference).
        leaseCounts[target.path, default: 0] += 1
        await stripAudioTrackIfNeeded(at: target, cacheKey: hex)
        enforceSizeLimit()
        return target
    }

    /// Scene playback is permanently muted, but a muted-but-PRESENT audio track still makes AVPlayerLooper's item rotation non-gapless: audio priming of the next item held frame publication ~100 ms at every 20 s wrap of scene 3660962877's clip vs 14-21 ms with the track removed (loop-seam probe A/B, 2026-08-20).
    /// Stripping once at write time keeps playback (lwmem mapping included) completely unchanged. Idempotent: an audio-free file — including every previously stripped one — returns after one track load. Any failure keeps the original file: worse seams, never broken playback.
    private func stripAudioTrackIfNeeded(at target: URL, cacheKey: String) async {
        guard !audioStripFailedKeys.contains(cacheKey) else { return }
        do {
            let asset = AVURLAsset(url: target)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { return }
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }
            let composition = AVMutableComposition()
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ), let export = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetPassthrough
            ) else {
                audioStripFailedKeys.insert(cacheKey)
                return
            }
            let (range, transform) = try await videoTrack.load(.timeRange, .preferredTransform)
            try compositionTrack.insertTimeRange(range, of: videoTrack, at: .zero)
            compositionTrack.preferredTransform = transform
            // Dot-prefixed sibling: same volume as `target`, since `replaceItemAt` is only atomic within a volume. Hidden keeps it out of the LRU (evicting a half-written export would break it), so `stats()` counts it and `collectOrphans` sweeps stale ones — a force-quit mid-export used to strand it forever.
            let tempURL = target.deletingLastPathComponent()
                .appendingPathComponent("\(Self.stripPrefix)\(UUID().uuidString).mp4")
            defer { try? fileManager.removeItem(at: tempURL) }
            try await export.export(to: tempURL, as: .mp4)
            // Atomic swap; an already-mapped old inode stays valid for its holders.
            _ = try fileManager.replaceItemAt(target, withItemAt: tempURL)
            Logger.info(
                "[WPE.video] stripped audio track from cached video \(cacheKey.prefix(8))…",
                category: .wpeRender
            )
        } catch {
            // A cancelled scene load (wallpaper switched away) can surface as
            // CancellationError or an AVFoundation cancel code. The file is
            // fine — leave the key unlatched so the next load strips it.
            if error is CancellationError || Task.isCancelled { return }
            audioStripFailedKeys.insert(cacheKey)
            Logger.warning(
                "[WPE.video] audio-track strip failed — keeping original: \(error.localizedDescription)",
                category: .wpeRender
            )
        }
    }

    /// Drop one lease; file stays for reuse until no holders remain.
    func release(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard let count = leaseCounts[path] else { return }
        if count <= 1 {
            leaseCounts.removeValue(forKey: path)
        } else {
            leaseCounts[path] = count - 1
        }
    }

    // MARK: - Garbage collection

    /// Delete unreferenced buckets (spare leases), then enforce LRU size limit.
    @discardableResult
    func collectOrphans(referencedWorkshopIDs: Set<String>) -> UInt64 {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var freed: UInt64 = 0
        for child in children {
            let name = child.lastPathComponent
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let referenced = isDirectory
                && name != Self.unattributedBucket
                && WPEPathSafety.isSafeProjectID(name)
                && referencedWorkshopIDs.contains(name)
            if referenced || containsLeasedFile(child) { continue }

            let bytes = byteCount(at: child)
            do {
                try fileManager.removeItem(at: child)
                freed += bytes
            } catch {
                Logger.warning("WPE video cache GC: failed to remove \(name): \(error.localizedDescription)", category: .wpeRender)
            }
        }

        freed += sweepStripTemporaries()
        if freed > 0 {
            Logger.info("WPE video cache GC reclaimed \(freed) bytes from orphaned scenes", category: .wpeRender)
        }
        enforceSizeLimit()
        return freed
    }

    /// User "Clear": unlink all files including leased (open fd/in-memory loader survive).
    @discardableResult
    func purgeAll() -> UInt64 {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var freed: UInt64 = 0
        for child in children {
            let bytes = byteCount(at: child)
            do {
                try fileManager.removeItem(at: child)
                freed += bytes
            } catch {
                Logger.warning("WPE video cache purgeAll: failed to remove \(child.lastPathComponent): \(error.localizedDescription)", category: .wpeRender)
            }
        }
        if freed > 0 {
            Logger.info("WPE video cache purged \(freed) bytes", category: .wpeRender)
        }
        return freed
    }

    // MARK: - Accounting

    /// On-disk allocated size + file count (Settings `du`-equivalent).
    func stats() -> WPEVideoCacheStats {
        let files = allFiles() + stripTemporaries()
        return WPEVideoCacheStats(
            totalBytes: files.reduce(0) { $0 + $1.size },
            fileCount: files.count
        )
    }

    /// Hidden scratch files, which `allFiles()` deliberately skips.
    private func stripTemporaries() -> [FileRecord] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .contentModificationDateKey
            ]
        ) else { return [] }
        var records: [FileRecord] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix(Self.stripPrefix),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .totalFileAllocatedSizeKey,
                      .fileAllocatedSizeKey,
                      .contentModificationDateKey
                  ]), values.isRegularFile == true
            else { continue }
            records.append(FileRecord(
                url: url.standardizedFileURL,
                size: UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return records
    }

    /// Deletes scratch files whose export can no longer be running. Age, not
    /// existence, is the test: a live export is writing one right now.
    @discardableResult
    private func sweepStripTemporaries(now: Date = Date()) -> UInt64 {
        var freed: UInt64 = 0
        for record in stripTemporaries()
        where now.timeIntervalSince(record.modified) > Self.stripTemporaryMaxAge {
            guard (try? fileManager.removeItem(at: record.url)) != nil else { continue }
            freed += record.size
        }
        return freed
    }

    // MARK: - LRU eviction

    /// LRU-evict non-leased files until under `maxBytes` (never unlink leases).
    private func enforceSizeLimit() {
        let files = allFiles()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        let evictable = files
            .filter { !isLeased($0.url.path) }
            .sorted { $0.modified < $1.modified }

        var freed: UInt64 = 0
        for file in evictable {
            if total <= maxBytes { break }
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.size
                freed += file.size
            } catch {
                Logger.warning("WPE video cache eviction: failed to remove \(file.url.lastPathComponent): \(error.localizedDescription)", category: .wpeRender)
            }
        }

        if freed > 0 {
            Logger.info("WPE video cache LRU evicted \(freed) bytes (cap \(maxBytes))", category: .wpeRender)
        }
        if total > maxBytes {
            Logger.notice("WPE video cache still over cap (\(total) > \(maxBytes)) — remaining files are in use", category: .wpeRender)
        }
    }

    // MARK: - Helpers

    private func bucketName(for workshopID: String) -> String {
        WPEPathSafety.isSafeProjectID(workshopID) ? workshopID : Self.unattributedBucket
    }

    /// No size comparison: stored files are audio-stripped, so their size
    /// legitimately differs from the original payload's. `.atomic` writes mean
    /// a present file is never partial.
    private func fileExists(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return false
        }
        return size > 0
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private struct FileRecord {
        let url: URL
        let size: UInt64
        let modified: Date
    }

    private func allFiles() -> [FileRecord] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var records: [FileRecord] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .contentModificationDateKey
            ]), values.isRegularFile == true else {
                continue
            }
            let size = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            records.append(FileRecord(
                url: url.standardizedFileURL,
                size: size,
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return records
    }

    private func byteCount(at url: URL) -> UInt64 {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: UInt64 = 0
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
            return total
        }
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    private func isLeased(_ path: String) -> Bool {
        (leaseCounts[path] ?? 0) > 0
    }

    /// True if `url` is a leased file or a directory containing one.
    private func containsLeasedFile(_ url: URL) -> Bool {
        guard !leaseCounts.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        if isLeased(path) { return true }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return leaseCounts.keys.contains { $0.hasPrefix(prefix) }
    }
}

/// Disk-usage snapshot of the WPE video-texture cache, surfaced in Settings.
struct WPEVideoCacheStats: Sendable, Equatable {
    let totalBytes: UInt64
    let fileCount: Int
}
#endif
