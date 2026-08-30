#if !LITE_BUILD
import CryptoKit
import Darwin
import Foundation
import os

/// Disk layer for Workshop preview images: the encoded image bytes, and nothing else.
/// All three Workshop sessions are deliberately `.ephemeral` with `httpCookieAcceptPolicy = .never`, `urlCache = nil` and `reloadIgnoringLocalAndRemoteCacheData` — here, in `WorkshopQueryService` and in `SteamWorkshopMetadata` — and `docs/SECURITY.md` advertises that posture to users.
/// Getting a disk layer by hanging a `URLCache` on that session would persist response headers (and anything cookie-shaped in them), which is the one thing the configuration exists to prevent — so this cache is filled by the loader rather than by the URL loading system, and an entry is byte-for-byte the image that was decoded: no headers, no status line, no URL, no wrapper.
/// The file *name* is a SHA-256 of the key, so a directory listing does not disclose which previews were browsed either. `Sendable`: every stored property is a `let` of a `Sendable` type, and all file work is funnelled onto the serial `queue`.
final class WorkshopPreviewDiskCache: Sendable {

    static let shared = WorkshopPreviewDiskCache()

    /// LRU hard cap. A Workshop page is 50 items and a Steam preview is
    /// ~100–400 KB, so this holds on the order of a thousand previews. `Caches`
    /// is additionally reclaimed by the system under disk pressure, so the cap
    /// only has to stop unbounded growth between reclaims.
    static let defaultCapBytes: Int64 = 256 * 1024 * 1024

    /// Steam serves a replaced preview under the same `preview_url`, so an
    /// entry the cap never reaches would show the old picture forever.
    static let defaultTimeToLive: TimeInterval = 30 * 24 * 60 * 60

    /// Orphan `.tmp` files (a write interrupted by a crash) are invisible to the
    /// cap, so they are swept — but only once they are older than any write
    /// that could still be in flight, since a second process or instance may be
    /// mid-write on the same directory.
    private static let orphanTempGrace: TimeInterval = 60

    private static let fileExtension = "bin"

    private let directoryURL: URL
    private let capBytes: Int64
    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date
    /// Serial: cap enforcement lists the whole directory and deletes from it,
    /// and two of those interleaving would each evict against a stale total.
    private let queue = DispatchQueue(
        label: "com.loomscreen.workshop-preview-disk-cache",
        qos: .utility
    )
    /// Whether this instance has already run its one housekeeping pass.
    private let hasSwept = OSAllocatedUnfairLock(initialState: false)

    init(
        directoryURL: URL? = nil,
        capBytes: Int64 = defaultCapBytes,
        timeToLive: TimeInterval = defaultTimeToLive,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.capBytes = capBytes
        self.timeToLive = timeToLive
        self.now = now
    }

    // MARK: - API

    /// The bytes previously stored for this URL *at this size*, or `nil`.
    func data(for url: URL, size: WorkshopPreviewSize) async -> Data? {
        let result = await perform { self.readSync(for: url, size: size) }
        sweepOnce()
        return result
    }

    func store(_ data: Data, for url: URL, size: WorkshopPreviewSize) async {
        await perform { self.writeSync(data, for: url, size: size) }
        sweepOnce()
    }

    func sizeBytes() async -> Int64 {
        await perform { self.entriesSync().reduce(Int64(0)) { $0 + $1.sizeBytes } }
    }

    func clear() async {
        await perform { self.clearSync() }
    }

    /// Size is part of the key, not just of the decode: Steam serves one
    /// `preview_url` for the grid tile and the detail hero, and the two are
    /// decoded to different pixel caps.
    static func fileName(for url: URL, size: WorkshopPreviewSize) -> String {
        let key = "v1|\(size.rawValue)|\(url.absoluteString)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).\(fileExtension)"
    }

    /// One housekeeping pass per instance, the first time the cache is used for real work.
    /// `enforceCap` otherwise only ever runs as the tail of a write, which leaves three ways for the directory to stay wrong indefinitely: a browsing session followed by never opening the Workshop again strands expired entries; a process that exits between the `rename(2)` and the cap check leaves the directory over `capBytes` with nothing due to notice; and a crash mid-write leaves a `.tmp` that no total counts.
    /// Sweeping at first use clears all three on the next run, without putting any I/O on the launch path — this is a menu-bar app, and nothing touches this cache until a Workshop view asks for a preview.
    /// Queued *behind* the request that triggered it, on the same serial queue, so the preview the user is waiting for is not made to wait for a full directory listing.
    private func sweepOnce() {
        let claimed = hasSwept.withLock { swept -> Bool in
            guard !swept else { return false }
            swept = true
            return true
        }
        guard claimed else { return }
        queue.async { try? self.enforceCap(fileManager: .default) }
    }

    // MARK: - Disk

    private func perform<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func readSync(for url: URL, size: WorkshopPreviewSize) -> Data? {
        let fileManager = FileManager.default
        let fileURL = self.fileURL(for: url, size: size)
        let path = fileURL.path(percentEncoded: false)
        // `attributesOfItem` stats fresh every call; `URLResourceValues` would
        // memoize on the URL instance and hand back a stale mtime.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let created = attributes[.creationDate] as? Date,
              let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        // Expiry runs against the creation date, not the modification date:
        // `modificationDate` is the LRU stamp and is bumped on every read, so a
        // frequently viewed preview would never expire if the two shared a clock.
        guard created > now().addingTimeInterval(-timeToLive) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        // Bound the allocation before making it, rather than after.
        guard byteCount > 0, byteCount <= Int64(WorkshopAnimatedGIF.maxBytes) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Bump the LRU stamp so cap eviction approximates least-recently-used
        // rather than first-written.
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: path)
        return data
    }

    private func writeSync(_ data: Data, for url: URL, size: WorkshopPreviewSize) {
        guard !data.isEmpty, data.count <= WorkshopAnimatedGIF.maxBytes else { return }
        let fileManager = FileManager.default
        do {
            try ensureDirectory(fileManager: fileManager)
            let destination = fileURL(for: url, size: size)
            // A scratch name unique per write, not a fixed `<key>.tmp`: two
            // writers racing on the same key must not share a scratch file, or
            // one would rename the other's half-written bytes into place.
            let tempURL = directoryURL.appendingPathComponent(
                "\(destination.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            let tempPath = tempURL.path(percentEncoded: false)
            try data.write(to: tempURL)
            // Stamp before the rename so the entry is never briefly
            // world-readable and never briefly carries the wrong clocks. Two
            // calls, not one: `setAttributes` is all-or-nothing, and a rejected
            // date must not take the permissions down with it.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempPath)
            let stamp = now()
            try? fileManager.setAttributes(
                [.creationDate: stamp, .modificationDate: stamp], ofItemAtPath: tempPath
            )
            // `rename(2)` is atomic: a concurrent reader sees either the previous
            // complete entry or the new complete entry, never a splice of both.
            try Self.renameItem(at: tempURL, to: destination)
            try enforceCap(fileManager: fileManager)
        } catch {
            return
        }
    }

    private func clearSync() {
        let fileManager = FileManager.default
        let path = directoryURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return }
        // Move aside, then delete: the directory stops serving entries at the
        // rename, not partway through a long recursive delete.
        let tombstone = directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(directoryURL.lastPathComponent).tobedeleted-\(UUID().uuidString)",
                isDirectory: true
            )
        guard (try? fileManager.moveItem(at: directoryURL, to: tombstone)) != nil else { return }
        try? fileManager.removeItem(at: tombstone)
    }

    /// Drops expired entries and orphaned scratch files, then evicts
    /// least-recently-used entries until the directory fits `capBytes`.
    private func enforceCap(fileManager: FileManager) throws {
        removeOrphanedTempFiles(fileManager: fileManager)

        var entries = entriesSync()
        let expiryCutoff = now().addingTimeInterval(-timeToLive)
        entries.removeAll { entry in
            guard entry.createdAt <= expiryCutoff else { return false }
            try? fileManager.removeItem(at: entry.url)
            return true
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > capBytes else { return }
        entries.sort { $0.usedAt < $1.usedAt }
        for entry in entries {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.sizeBytes
            if total <= capBytes { break }
        }
    }

    private func removeOrphanedTempFiles(fileManager: FileManager) {
        let cutoff = now().addingTimeInterval(-Self.orphanTempGrace)
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension == "tmp" {
            guard let modified = (try? fileManager.attributesOfItem(
                atPath: url.path(percentEncoded: false)
            ))?[.modificationDate] as? Date, modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func entriesSync() -> [Entry] {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == Self.fileExtension else { return nil }
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: url.path(percentEncoded: false)
            ),
                  let created = attributes[.creationDate] as? Date,
                  let used = attributes[.modificationDate] as? Date,
                  let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
                return nil
            }
            return Entry(url: url, createdAt: created, usedAt: used, sizeBytes: byteCount)
        }
    }

    private func ensureDirectory(fileManager: FileManager) throws {
        var isDirectory = ObjCBool(false)
        let path = directoryURL.path(percentEncoded: false)
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func fileURL(for url: URL, size: WorkshopPreviewSize) -> URL {
        directoryURL.appendingPathComponent(
            Self.fileName(for: url, size: size), isDirectory: false
        )
    }

    /// `.cachesDirectory` rather than Application Support: previews are
    /// re-downloadable, and the system reclaims `Caches` on its own under disk
    /// pressure. Inside the sandbox `FileManager` resolves this to the app
    /// container, so no path is hard-coded.
    private static func defaultDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let caches = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.loomscreen.pro", isDirectory: true
            )
            .appendingPathComponent("WorkshopPreviews", isDirectory: true)
    }

    private static func renameItem(at source: URL, to destination: URL) throws {
        try source.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { throw CocoaError(.fileNoSuchFile) }
                if Darwin.rename(sourcePath, destinationPath) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private struct Entry {
        let url: URL
        let createdAt: Date
        let usedAt: Date
        let sizeBytes: Int64
    }
}
#endif
