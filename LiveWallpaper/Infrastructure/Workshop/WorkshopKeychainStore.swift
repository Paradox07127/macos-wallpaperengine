#if !LITE_BUILD
import Foundation
import Security

/// The login-keychain slot the Steam Web API key lives in, reduced to the four
/// operations the store needs. Injectable so tests never touch the real
/// login keychain.
struct WorkshopKeychainSlot: Sendable {
    enum ReadOutcome: Sendable {
        case found(String)
        case absent
        /// The ACL dialog was refused, or the keychain is locked.
        case denied
    }

    /// Attribute-only existence probe — never shows the ACL dialog.
    var exists: @Sendable () -> Bool
    var read: @Sendable () -> ReadOutcome
    /// Adds, or updates an item that is already there.
    var write: @Sendable (String) -> OSStatus
    /// `errSecItemNotFound` is normalised to success: nothing to remove is the
    /// outcome the caller asked for.
    var delete: @Sendable () -> OSStatus

    /// Unchanged since before the 2026-08-12 move to a container file: reusing
    /// the pair is what keeps an older install's key readable instead of
    /// orphaning it in the user's keychain.
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
                guard let data = item as? Data,
                      let key = String(data: data, encoding: .utf8) else { return .absent }
                return .found(key)
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                return .denied
            default:
                return .absent
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
            // Explicit rather than implied: the data-protection keychain refuses
            // this build outright (`SecItemAdd` → errSecMissingEntitlement, and
            // `keychain-access-groups` needs a provisioning profile this project
            // has no certificate for).
            kSecUseDataProtectionKeychain as String: false
        ]
    }
}

/// Stores the Steam Web API key in the login keychain. Moved back out of the sandbox container file it lived in from 2026-08-12: the file was plaintext, and the legacy keychain does accept this build's add/read.
/// The cost is that a legacy-keychain ACL is bound to the calling binary's code-directory hash, so the first read after a Sparkle update prompts once. `hasWebAPIKey` deliberately answers from an attribute-only probe that never triggers that prompt, and reads are left to the moment the key is actually needed.
actor WorkshopKeychainStore {

    private static let keyPattern = #"^[A-Fa-f0-9]{32}$"#

    enum WorkshopKeychainError: Error, Equatable, Sendable {
        case osStatus(OSStatus)
        case malformedData
        case ioFailure
        /// The item is there but macOS would not hand it over. Distinct from
        /// "no key stored" so the UI does not send the user back to Steam for
        /// a key they already have.
        case accessDenied
    }

    /// The 2026-08-12 container file, kept only as a migration source.
    private let fileURL: URL
    private let slot: WorkshopKeychainSlot

    /// Sticky record of the last read having been refused, so the settings UI
    /// can say so without performing a read of its own.
    private(set) var readWasDenied = false

    /// The parameters are test seams; production uses the sandbox container's
    /// Application Support and the real keychain slot.
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
        // Loads consult the file first, so a leftover one would shadow this.
        try? FileManager.default.removeItem(at: fileURL)
    }

    func loadWebAPIKey() async throws -> String? {
        if let migrated = try migrateContainerFileIfPresent() { return migrated }
        switch slot.read() {
        case .found(let key):
            readWasDenied = false
            guard Self.isValidAPIKeyShape(key) else {
                throw WorkshopKeychainError.malformedData
            }
            return key
        case .absent:
            readWasDenied = false
            return nil
        case .denied:
            readWasDenied = true
            throw WorkshopKeychainError.accessDenied
        }
    }

    func deleteWebAPIKey() async throws {
        let status = slot.delete()
        guard status == errSecSuccess else { throw Self.error(for: status) }
        readWasDenied = false
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw WorkshopKeychainError.ioFailure
        }
    }

    func hasWebAPIKey() async -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path) || slot.exists()
    }

    /// Copies the container file into the keychain and drops it — but only once
    /// the keychain verifiably holds the key, so a refused write leaves the key
    /// where it still works rather than losing it.
    private func migrateContainerFileIfPresent() throws -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // The keychain outranks the file: a save writes the keychain first and
        // only then drops the file, so whenever both exist the file is the
        // stale side (a failed removal, a backup restore, a half-written legacy
        // copy). Migrating it over the keychain resurrected forgotten keys.
        if case .found(let stored) = slot.read(), Self.isValidAPIKeyShape(stored) {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard let key = String(data: data, encoding: .utf8),
              Self.isValidAPIKeyShape(key) else {
            // A corrupt leftover used to throw here — before the keychain was
            // even consulted — shadowing a perfectly valid stored key.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard slot.write(key) == errSecSuccess,
              case .found(let stored) = slot.read(), stored == key else { return key }
        try? FileManager.default.removeItem(at: fileURL)
        return key
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
