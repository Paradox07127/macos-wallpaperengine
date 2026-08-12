#if !LITE_BUILD
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

    private let rootURL: URL
    private let fileManager: FileManager
    private let maxBytes: UInt64

    /// Live lease refcounts (content-addressing can share one file across sources).
    private var leaseCounts: [String: Int] = [:]

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

    /// Store/reuse by SHA-256; returns a leased URL and refreshes LRU mtime.
    func store(_ data: Data, workshopID: String) throws -> URL {
        let bucketURL = rootURL.appendingPathComponent(bucketName(for: workshopID), isDirectory: true)
        try fileManager.createDirectory(at: bucketURL, withIntermediateDirectories: true)

        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = bucketURL.appendingPathComponent("\(hex).mp4").standardizedFileURL

        if fileExists(target, withSize: UInt64(data.count)) {
            touch(target)
        } else {
            try data.write(to: target, options: [.atomic])
        }
        leaseCounts[target.path, default: 0] += 1
        enforceSizeLimit()
        return target
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
                && WPEPathSafety.isSafeWorkshopID(name)
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
        let files = allFiles()
        return WPEVideoCacheStats(
            totalBytes: files.reduce(0) { $0 + $1.size },
            fileCount: files.count
        )
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
        WPEPathSafety.isSafeWorkshopID(workshopID) ? workshopID : Self.unattributedBucket
    }

    private func fileExists(_ url: URL, withSize expected: UInt64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size >= 0 else {
            return false
        }
        return UInt64(size) == expected
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
