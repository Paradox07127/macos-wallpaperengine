import Foundation

/// JSON-on-disk store: atomic write, `.bak` recovery, POSIX lock, dir/file `0700`/`0600`.
/// Independent of UserDefaults; synchronous I/O on the caller's actor.
public struct AtomicFileStore<Value: Codable> {
    public enum StoreError: Error, CustomStringConvertible {
        case writeFailed(underlying: Error)

        public var description: String {
            switch self {
            case .writeFailed(let error):
                return "AtomicFileStore: write failed — \(error.localizedDescription)"
            }
        }
    }

    /// Read-path cap (~64 MB ≫ real config size) to refuse malicious/truncated blobs.
    public static var maxReasonableFileSize: Int { 64 * 1024 * 1024 }

    public let fileURL: URL
    public let backupURL: URL
    public let tempURL: URL
    public let lockURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let category: Logger.Category

    public init(
        fileURL: URL,
        encoder: JSONEncoder = .configurationEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        fileManager: FileManager = .default,
        category: Logger.Category = .settings
    ) {
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

    /// Primary, else `.bak` on missing/corrupt.
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

    /// Seed from an existing UserDefaults JSON blob without re-encode.
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

    public func delete() {
        for url in [fileURL, backupURL, tempURL, lockURL] where fileExists(url) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Logger.warning(
                    "AtomicFileStore could not remove \(url.lastPathComponent): \(error.localizedDescription)",
                    category: category
                )
            }
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

        if let handle = try? FileHandle(forWritingTo: tempURL) {
            fullSync(handle.fileDescriptor, label: tempURL.lastPathComponent)
            try? handle.close()
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

        fsyncParentDirectory(of: fileURL)
    }

    /// After `read()` has recovered from the backup, the primary stays corrupt —
    /// nothing heals it. Rotating in that state deletes the backup and promotes
    /// the corrupt primary into its slot, so a later primary loss leaves nothing
    /// readable. Keep the backup and drop the corrupt primary instead.
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

    private func fsyncParentDirectory(of url: URL) {
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        let fd = open(parent, O_RDONLY)
        guard fd >= 0 else { return }
        fullSync(fd, label: url.deletingLastPathComponent().lastPathComponent)
        close(fd)
    }

    /// Best-effort `F_FULLFSYNC`, else `fsync` (ENOTSUP on some FS). Never throws.
    private func fullSync(_ fd: Int32, label: String) {
        guard fcntl(fd, F_FULLFSYNC) == -1 else { return }
        let fullSyncErr = errno
        if fsync(fd) == 0 {
            Logger.warning(
                "AtomicFileStore F_FULLFSYNC unsupported for \(label) (errno \(fullSyncErr)); fell back to fsync",
                category: category
            )
        } else {
            Logger.error(
                "AtomicFileStore durability sync failed for \(label): F_FULLFSYNC errno \(fullSyncErr), fsync errno \(errno)",
                category: category
            )
        }
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
