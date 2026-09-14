#if !LITE_BUILD
import Darwin
import Foundation
import os

final class WorkshopDiskCacheStore: Sendable {
    /// `modificationDate` is also the LRU stamp and is bumped on every read, so an entry expiring on it lives as long as it keeps being read — the query cache wants exactly that from its 5-minute TTL.
    /// `creationDate` expires an entry on its age however often it was viewed — Steam serves a replaced preview under the same `preview_url`, so a preview the cap never reaches would otherwise show the old picture forever.
    enum ExpiryClock: Sendable {
        case creationDate
        case modificationDate
    }

    /// Orphan .tmp files are invisible to the cap; sweep only once older than any write that could still be in flight.
    private static let orphanTempGrace: TimeInterval = 60

    private let directoryURL: URL
    private let fileExtension: String
    private let capBytes: Int64
    private let timeToLive: TimeInterval
    private let expiryClock: ExpiryClock
    /// Read-side bound on one entry, checked against the stat size before the
    /// allocation is made rather than after; an entry outside it is dropped.
    private let maxEntryBytes: Int64?
    private let now: @Sendable () -> Date
    /// Serial: cap enforcement lists the whole directory and deletes from it,
    /// and two of those interleaving would each evict against a stale total.
    private let queue: DispatchQueue
    private let hasSwept = OSAllocatedUnfairLock(initialState: false)

    init(
        directoryURL: URL,
        fileExtension: String,
        capBytes: Int64,
        timeToLive: TimeInterval,
        expiryClock: ExpiryClock,
        maxEntryBytes: Int64? = nil,
        queueLabel: String,
        now: @escaping @Sendable () -> Date
    ) {
        self.directoryURL = directoryURL
        self.fileExtension = fileExtension
        self.capBytes = capBytes
        self.timeToLive = timeToLive
        self.expiryClock = expiryClock
        self.maxEntryBytes = maxEntryBytes
        self.now = now
        queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    // MARK: - API

    func read(named name: String) async -> Data? {
        let result = await perform { self.readSync(named: name) }
        sweepOnce()
        return result
    }

    func write(_ data: Data, named name: String) async {
        await perform { self.writeSync(data, named: name) }
        sweepOnce()
    }

    func sizeBytes() async -> Int64 {
        await perform { self.entriesSync().reduce(Int64(0)) { $0 + $1.sizeBytes } }
    }

    func clear() async {
        await perform { self.clearSync() }
    }

    /// One housekeeping pass per instance, queued behind the request that triggered it on the same serial queue, so the waiting entry is not blocked by a full directory listing.
    func sweepOnce() {
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

    private func readSync(named name: String) -> Data? {
        let fileManager = FileManager.default
        let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        let path = fileURL.path(percentEncoded: false)
        // `attributesOfItem` stats fresh every call; `URLResourceValues` would
        // memoize on the URL instance and hand back a stale mtime.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let stamp = attributes[expiryClock.attributeKey] as? Date,
              let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        guard stamp > now().addingTimeInterval(-timeToLive) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        if let maxEntryBytes, byteCount <= 0 || byteCount > maxEntryBytes {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Bump the LRU stamp so cap eviction approximates least-recently-used
        // rather than first-written.
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: path)
        return data
    }

    private func writeSync(_ data: Data, named name: String) {
        let fileManager = FileManager.default
        do {
            try ensureDirectory(fileManager: fileManager)
            let destination = directoryURL.appendingPathComponent(name, isDirectory: false)
            // Scratch name unique per write, not a fixed <key>.tmp: two writers racing the same key must not share a scratch file.
            let tempURL = directoryURL.appendingPathComponent(
                "\(name).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            let tempPath = tempURL.path(percentEncoded: false)
            try data.write(to: tempURL)
            // Stamp before rename so the entry is never briefly world-readable. Two setAttributes calls: a rejected date must not take permissions down with it.
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

    private func enforceCap(fileManager: FileManager) throws {
        removeOrphanedTempFiles(fileManager: fileManager)

        var entries = entriesSync()
        let expiryCutoff = now().addingTimeInterval(-timeToLive)
        entries.removeAll { entry in
            guard entry.expiryStamp <= expiryCutoff else { return false }
            try? fileManager.removeItem(at: entry.url)
            return true
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > capBytes else { return }
        entries.sort { $0.usedAt < $1.usedAt }
        for entry in entries {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.sizeBytes
            if total <= capBytes {
                break
            }
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
            guard url.pathExtension == fileExtension else { return nil }
            let path = url.path(percentEncoded: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let expiryStamp = attributes[expiryClock.attributeKey] as? Date,
                  let used = attributes[.modificationDate] as? Date,
                  let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
                return nil
            }
            return Entry(url: url, expiryStamp: expiryStamp, usedAt: used, sizeBytes: byteCount)
        }
    }

    private func ensureDirectory(fileManager: FileManager) throws {
        var isDirectory = ObjCBool(false)
        let path = directoryURL.path(percentEncoded: false)
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return
            }
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
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
        let expiryStamp: Date
        let usedAt: Date
        let sizeBytes: Int64
    }
}

private extension WorkshopDiskCacheStore.ExpiryClock {
    var attributeKey: FileAttributeKey {
        switch self {
        case .creationDate: .creationDate
        case .modificationDate: .modificationDate
        }
    }
}
#endif
