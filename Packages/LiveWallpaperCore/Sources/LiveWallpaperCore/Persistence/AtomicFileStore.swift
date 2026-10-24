import Foundation

/// Durability calls on an open descriptor; each returns 0 on success or the failing errno.
public struct FileDurabilitySync: Sendable {
    public var fullFsync: @Sendable (Int32) -> Int32
    public var fsync: @Sendable (Int32) -> Int32

    public init(fullFsync: @escaping @Sendable (Int32) -> Int32, fsync: @escaping @Sendable (Int32) -> Int32) {
        self.fullFsync = fullFsync
        self.fsync = fsync
    }

    public static let system = FileDurabilitySync(
        fullFsync: { fcntl($0, F_FULLFSYNC) == -1 ? errno : 0 },
        fsync: { Darwin.fsync($0) == 0 ? 0 : errno }
    )
}

public struct AtomicFileStore<Value: Codable> {
    public enum StoreError: Error, CustomStringConvertible {
        case writeFailed(underlying: Error)
        case deleteFailed(underlying: Error)

        public var description: String {
            switch self {
            case let .writeFailed(error):
                "AtomicFileStore: write failed — \(error.localizedDescription)"
            case let .deleteFailed(error):
                "AtomicFileStore: delete failed — \(error.localizedDescription)"
            }
        }
    }

    /// Read and write cap (~64 MB ≫ real config size) to refuse malicious/truncated blobs.
    public static var maxReasonableFileSize: Int { 64 * 1024 * 1024 }

    public let fileURL: URL
    public let backupURL: URL
    public let tempURL: URL
    public let lockURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let durabilitySync: FileDurabilitySync
    private let category: Logger.Category

    public init(
        fileURL: URL,
        encoder: JSONEncoder = .configurationEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        fileManager: FileManager = .default,
        durabilitySync: FileDurabilitySync = .system,
        category: Logger.Category = .settings
    ) {
        self.durabilitySync = durabilitySync
        self.fileURL = fileURL
        self.backupURL = fileURL.appendingPathExtension("bak")
        self.tempURL = fileURL.appendingPathExtension("tmp")
        self.lockURL = fileURL.appendingPathExtension("lock")
        self.encoder = encoder
        self.decoder = decoder
        self.fileManager = fileManager
        self.category = category
    }

    /// True only when a payload actually decodes (empty/corrupt must not block UD re-seed).
    public var hasPersistedValue: Bool {
        read() != nil
    }

    public func read() -> Value? {
        if let value = decode(from: fileURL) {
            return value
        }

        if fileExists(fileURL) {
            Logger.warning(
                "AtomicFileStore primary unreadable at \(fileURL.lastPathComponent); attempting backup",
                category: category
            )
        }

        guard let backup = decode(from: backupURL) else {
            if fileExists(backupURL) {
                Logger.error(
                    "AtomicFileStore backup also unreadable at \(backupURL.lastPathComponent)",
                    category: category
                )
            }
            return nil
        }

        Logger.info(
            "AtomicFileStore recovered from backup at \(backupURL.lastPathComponent)",
            category: category
        )
        return backup
    }

    public func write(_ value: Value) throws {
        do {
            try ensureDirectoryExists()
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }

        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }

        do {
            try writeAtomically(data)
        } catch {
            Logger.error(
                "AtomicFileStore write failed for \(fileURL.lastPathComponent): \(error.localizedDescription)",
                category: category
            )
            throw StoreError.writeFailed(underlying: error)
        }
    }

    public func writeRaw(_ data: Data) throws {
        do {
            try ensureDirectoryExists()
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }

        do {
            try writeAtomically(data)
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }
    }

    /// Attempts every file even after a failure, then throws the first removal error.
    public func delete() throws {
        var firstFailure: Error?
        var removedAny = false
        for url in [fileURL, backupURL, tempURL, lockURL] where fileExists(url) {
            do {
                try fileManager.removeItem(at: url)
                removedAny = true
            } catch {
                Logger.warning(
                    "AtomicFileStore could not remove \(url.lastPathComponent): \(error.localizedDescription)",
                    category: category
                )
                firstFailure = firstFailure ?? error
            }
        }
        if removedAny {
            do {
                try fsyncParentDirectory(of: fileURL)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw StoreError.deleteFailed(underlying: firstFailure)
        }
    }

    // MARK: - Internals

    private func decode(from url: URL) -> Value? {
        guard fileExists(url) else { return nil }
        do {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > Self.maxReasonableFileSize {
                Logger.error(
                    "AtomicFileStore refusing to decode oversized file \(url.lastPathComponent) (\(size) bytes)",
                    category: category
                )
                return nil
            }
            let data = try Data(contentsOf: url)
            return try decoder.decode(Value.self, from: data)
        } catch {
            Logger.warning(
                "AtomicFileStore decode failed for \(url.lastPathComponent): \(error.localizedDescription)",
                category: category
            )
            return nil
        }
    }

    /// Parent dir `0700` — bookmark Data / absolute paths must not be world-readable.
    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } else {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path(percentEncoded: false)
            )
        }
    }

    private func writeAtomically(_ data: Data) throws {
        // decode(from:) refuses anything larger, so such a write would be lost on next launch.
        guard data.count <= Self.maxReasonableFileSize else { throw POSIXError(.EFBIG) }
        let lockFD = try acquireLock()
        defer { releaseLock(lockFD) }

        if fileExists(tempURL) {
            try fileManager.removeItem(at: tempURL)
        }

        try data.write(to: tempURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tempURL.path(percentEncoded: false)
        )

        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }
            try fullSync(handle.fileDescriptor, label: tempURL.lastPathComponent)
        }

        var rotated = false
        do {
            if fileExists(fileURL) {
                if backupIsSoleReadableGeneration() {
                    try fileManager.removeItem(at: fileURL)
                } else {
                    if fileExists(backupURL) {
                        try fileManager.removeItem(at: backupURL)
                    }
                    try fileManager.moveItem(at: fileURL, to: backupURL)
                    rotated = true
                }
            }
            try fileManager.moveItem(at: tempURL, to: fileURL)
        } catch {
            if rotated {
                try? fileManager.moveItem(at: backupURL, to: fileURL)
            }
            throw error
        }

        try fsyncParentDirectory(of: fileURL)
    }

    /// Rotating while the primary is corrupt would delete the backup and promote the
    /// corrupt primary into its slot, leaving nothing readable after a later loss.
    private func backupIsSoleReadableGeneration() -> Bool {
        guard fileExists(backupURL) else { return false }
        return decode(from: fileURL) == nil && decode(from: backupURL) != nil
    }

    private func acquireLock() throws -> Int32 {
        let path = lockURL.path(percentEncoded: false)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw StoreError.writeFailed(underlying: POSIXError(
                .init(rawValue: errno) ?? .EIO
            ))
        }
        if flock(fd, LOCK_EX) != 0 {
            let err = errno
            close(fd)
            throw StoreError.writeFailed(underlying: POSIXError(
                .init(rawValue: err) ?? .EIO
            ))
        }
        return fd
    }

    private func releaseLock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    private func fsyncParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        let fd = open(parent, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try fullSync(fd, label: url.deletingLastPathComponent().lastPathComponent)
    }

    /// `F_FULLFSYNC`, else `fsync` (ENOTSUP on some FS); throws only when neither succeeds.
    private func fullSync(_ fd: Int32, label: String) throws {
        let fullSyncErr = durabilitySync.fullFsync(fd)
        guard fullSyncErr != 0 else { return }
        let fsyncErr = durabilitySync.fsync(fd)
        if fsyncErr == 0 {
            Logger.warning(
                "AtomicFileStore F_FULLFSYNC unsupported for \(label) (errno \(fullSyncErr)); fell back to fsync",
                category: category
            )
            return
        }
        Logger.error(
            "AtomicFileStore durability sync failed for \(label): F_FULLFSYNC errno \(fullSyncErr), fsync errno \(fsyncErr)",
            category: category
        )
        throw POSIXError(.init(rawValue: fsyncErr) ?? .EIO)
    }

    private func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }
}

/// `@unchecked Sendable` only when `Value: Sendable` (encoder/decoder/fileManager immutable here).
extension AtomicFileStore: @unchecked Sendable where Value: Sendable {}

// MARK: - Shared encoder configuration

extension JSONEncoder {
    /// Sorted keys → stable bytes for fixtures and re-runnable migration seeds.
    public static func configurationEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
