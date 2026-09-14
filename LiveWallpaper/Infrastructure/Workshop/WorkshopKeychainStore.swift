#if !LITE_BUILD
import Darwin
import Foundation
import Security

struct WorkshopKeychainSlot: Sendable {
    enum ReadOutcome: Sendable {
        case found(String)
        case absent
        /// The ACL dialog was refused, or the keychain is locked.
        case denied
        /// The item is there and macOS agreed to it, but the read failed (errSecDecode, errSecParam). Reporting absent would send the reader to Steam for a key they already had.
        case failed(OSStatus)
    }

    /// Attribute-only existence probe — never shows the ACL dialog.
    var exists: @Sendable () -> Bool
    var read: @Sendable () -> ReadOutcome
    var write: @Sendable (String) -> OSStatus
    /// `errSecItemNotFound` is normalised to success: nothing to remove is the
    /// outcome the caller asked for.
    var delete: @Sendable () -> OSStatus

    /// Reusing this service/account pair keeps an older install's key readable instead of orphaning it in the user's keychain.
    private static let service = "com.loomscreen.livewallpaper.workshop.webapikey"
    private static let account = "default"

    static let live = WorkshopKeychainSlot(
        exists: {
            var query = Self.query()
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        },
        read: {
            var query = Self.query()
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &item) {
            case errSecSuccess:
                // The item is there and macOS handed it over; bytes we cannot
                // decode are a damaged item, not a missing one.
                guard let data = item as? Data,
                      let key = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
                return .found(key)
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                return .denied
            case errSecItemNotFound:
                return .absent
            case let status:
                return .failed(status)
            }
        },
        write: { key in
            let data = Data(key.utf8)
            var insert = Self.query()
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecDuplicateItem else { return added }
            return SecItemUpdate(
                Self.query() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        },
        delete: {
            let status = SecItemDelete(Self.query() as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
    )

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            // Explicit rather than implied: the data-protection keychain refuses this build (SecItemAdd → errSecMissingEntitlement).
            kSecUseDataProtectionKeychain as String: false
        ]
    }
}

/// hasWebAPIKey answers from an attribute-only probe that never triggers the ACL prompt; reads wait until the key is actually needed.
actor WorkshopKeychainStore {

    private static let keyPattern = #"^[A-Fa-f0-9]{32}$"#
    private static let maximumLegacyFileBytes = 64

    enum WorkshopKeychainError: Error, Equatable, Sendable {
        case osStatus(OSStatus)
        case malformedData
        case ioFailure
        /// The item is there but macOS would not hand it over — distinct from no key stored so the UI does not send the user back to Steam.
        case accessDenied
    }

    /// The container file, kept only as a migration source.
    private let fileURL: URL
    private let slot: WorkshopKeychainSlot

    /// Sticky record of the last read having been refused, so the settings UI
    /// can say so without performing a read of its own.
    private(set) var readWasDenied = false
    /// Fingerprint of the key this store last wrote or read back; nil once it is gone.
    private(set) var storedKeyFingerprint: String?

    init(directory: URL? = nil, slot: WorkshopKeychainSlot = .live) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Workshop", isDirectory: true)
        fileURL = base.appendingPathComponent("steam-webapi.key", isDirectory: false)
        self.slot = slot
    }

    func setWebAPIKey(_ key: String) async throws {
        guard Self.isValidAPIKeyShape(key) else {
            throw WorkshopKeychainError.malformedData
        }
        let status = slot.write(key)
        guard status == errSecSuccess else { throw Self.error(for: status) }
        readWasDenied = false
        storedKeyFingerprint = WorkshopQueryService.keyFingerprint(key)
        // Loads consult the file first, so a leftover one would shadow this.
        try? FileManager.default.removeItem(at: fileURL)
    }

    func loadWebAPIKey() async throws -> String? {
        if let migrated = try migrateContainerFileIfPresent() {
            storedKeyFingerprint = WorkshopQueryService.keyFingerprint(migrated)
            return migrated
        }
        switch slot.read() {
        case .found(let key):
            readWasDenied = false
            guard Self.isValidAPIKeyShape(key) else {
                throw WorkshopKeychainError.malformedData
            }
            storedKeyFingerprint = WorkshopQueryService.keyFingerprint(key)
            return key
        case .absent:
            readWasDenied = false
            storedKeyFingerprint = nil
            return nil
        case .denied:
            readWasDenied = true
            throw WorkshopKeychainError.accessDenied
        case let .failed(status):
            readWasDenied = false
            throw WorkshopKeychainError.osStatus(status)
        }
    }

    func deleteWebAPIKey() async throws {
        let status = slot.delete()
        guard status == errSecSuccess else { throw Self.error(for: status) }
        readWasDenied = false
        storedKeyFingerprint = nil
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw WorkshopKeychainError.ioFailure
        }
    }

    func hasWebAPIKey() async -> Bool {
        Self.legacyFileMetadataIsSafe(at: fileURL) || slot.exists()
    }

    /// Copy the container file into the keychain and drop it only once the keychain verifiably holds the key — a refused write must leave the key where it still works.
    private func migrateContainerFileIfPresent() throws -> String? {
        guard Self.legacyEntryExists(at: fileURL) else { return nil }
        // The keychain outranks the file: whenever both exist the file is the stale side. Migrating it over the keychain would resurrect forgotten keys.
        if case .found(let stored) = slot.read(), Self.isValidAPIKeyShape(stored) {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard let data = Self.readBoundedLegacyFile(at: fileURL) else {
            // Never follow a symlink or allocate based on an unbounded legacy file. Removing a rejected symlink only unlinks this directory entry.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard let key = String(data: data, encoding: .utf8),
              Self.isValidAPIKeyShape(key) else {
            // A corrupt leftover must not throw here before the keychain is consulted — that would shadow a valid stored key.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard slot.write(key) == errSecSuccess,
              case .found(let stored) = slot.read(), stored == key else { return key }
        try? FileManager.default.removeItem(at: fileURL)
        return key
    }

    /// Metadata-only probe: legacy migration accepts only a small, current-user-owned regular file.
    static func legacyFileMetadataIsSafe(
        at url: URL,
        expectedOwner: uid_t = geteuid()
    ) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == expectedOwner
            && metadata.st_size >= 0
            && metadata.st_size <= off_t(maximumLegacyFileBytes)
    }

    private static func legacyEntryExists(at url: URL) -> Bool {
        var metadata = stat()
        return Darwin.lstat(url.path, &metadata) == 0
    }

    /// Open without following the final symlink, fstat the descriptor (closes the lstat/open race), and read at most one byte beyond the limit so concurrent growth is rejected too.
    private static func readBoundedLegacyFile(at url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumLegacyFileBytes) else { return nil }

        var bytes = [UInt8](repeating: 0, count: maximumLegacyFileBytes + 1)
        var count = 0
        while count < bytes.count {
            let result = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: count),
                    buffer.count - count
                )
            }
            if result == 0 {
                break
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            count += result
        }
        guard count <= maximumLegacyFileBytes else { return nil }
        return Data(bytes.prefix(count))
    }

    private static func error(for status: OSStatus) -> WorkshopKeychainError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .accessDenied
        default:
            return .osStatus(status)
        }
    }

    private static func isValidAPIKeyShape(_ key: String) -> Bool {
        key.range(of: keyPattern, options: [.regularExpression, .anchored]) != nil
    }
}
#endif
