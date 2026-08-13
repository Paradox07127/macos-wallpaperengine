#if !LITE_BUILD
import Foundation
import Security

/// The pre-2026-08-12 login-keychain slot, reduced to the three operations the
/// migration needs. Injectable so tests never touch the real login keychain.
struct WorkshopLegacyKeychainSlot: Sendable {
    enum ReadOutcome: Sendable {
        case found(String)
        case absent
        /// User cancelled the ACL dialog, or authorization failed.
        case denied
    }

    /// Attribute-only existence probe — never shows the ACL dialog.
    var exists: @Sendable () -> Bool
    var read: @Sendable () -> ReadOutcome
    /// Best-effort: under ad-hoc signing the read grant does not cover delete.
    var delete: @Sendable () -> Void

    private static let service = "com.loomscreen.livewallpaper.workshop.webapikey"
    private static let account = "default"

    static let live = WorkshopLegacyKeychainSlot(
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
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
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
        delete: { _ = SecItemDelete(Self.query() as CFDictionary) }
    )

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

/// Stores the Steam Web API key in a 0600 file inside the app's sandbox
/// container (`Application Support/Workshop/steam-webapi.key`).
///
/// Moved out of the keychain 2026-08-12: both dev and shipped builds are
/// ad-hoc signed, so they have no stable code identity — every rebuild or
/// app update re-triggered the login-keychain ACL password dialog, and the
/// data-protection keychain requires an access group ad-hoc signing cannot
/// provide. Sandbox container + FileVault is the accepted trade-off for this
/// revocable, read-only-scope key.
///
/// The legacy import is a **one-shot gated by `migrationDoneKey`**, not by the
/// legacy item's absence: deleting that item fails under ad-hoc signing (the
/// read grant does not cover delete), so an un-gated import re-created the key
/// right after "Forget" and made the button look dead.
actor WorkshopKeychainStore {

    private static let migrationDoneKey = "loomscreen.workshop.apiKeyKeychainMigrated.v1"
    private static let keyPattern = #"^[A-Fa-f0-9]{32}$"#

    enum WorkshopKeychainError: Error, Equatable, Sendable {
        case osStatus(OSStatus)
        case malformedData
        case ioFailure
    }

    private let fileURL: URL
    private let defaults: UserDefaults
    private let legacySlot: WorkshopLegacyKeychainSlot

    /// The parameters are test seams; production uses the sandbox container's
    /// Application Support, the app-scoped defaults suite, and the real slot.
    init(
        directory: URL? = nil,
        defaults: UserDefaults = .appScoped(),
        legacySlot: WorkshopLegacyKeychainSlot = .live
    ) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Workshop", isDirectory: true)
        fileURL = base.appendingPathComponent("steam-webapi.key", isDirectory: false)
        self.defaults = defaults
        self.legacySlot = legacySlot
    }

    func setWebAPIKey(_ key: String) async throws {
        guard Self.isValidAPIKeyShape(key),
              let data = key.data(using: .utf8) else {
            throw WorkshopKeychainError.malformedData
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            throw WorkshopKeychainError.ioFailure
        }
    }

    func loadWebAPIKey() async throws -> String? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return await migrateLegacyKeyIfNeeded()
        }
        guard let key = String(data: data, encoding: .utf8),
              Self.isValidAPIKeyShape(key) else {
            throw WorkshopKeychainError.malformedData
        }
        return key
    }

    func deleteWebAPIKey() async throws {
        // Closes the import path first: the legacy delete is best-effort
        // (see the type doc), so the flag — not the item — is what makes
        // "Forget" terminal.
        defaults.set(true, forKey: Self.migrationDoneKey)
        legacySlot.delete()
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw WorkshopKeychainError.ioFailure
        }
    }

    func hasWebAPIKey() async -> Bool {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return true
        }
        guard !defaults.bool(forKey: Self.migrationDoneKey) else { return false }
        return legacySlot.exists()
    }

    /// Copies the legacy item into the container file, then tries to delete it.
    ///
    /// Marks the one-shot done when the key is safely in the file, or when
    /// there is nothing to import — but NOT when the user cancels the ACL
    /// dialog, so an accidental cancel does not discard their key.
    private func migrateLegacyKeyIfNeeded() async -> String? {
        guard !defaults.bool(forKey: Self.migrationDoneKey) else { return nil }

        switch legacySlot.read() {
        case .denied:
            return nil
        case .absent:
            defaults.set(true, forKey: Self.migrationDoneKey)
            return nil
        case .found(let key):
            guard Self.isValidAPIKeyShape(key) else {
                defaults.set(true, forKey: Self.migrationDoneKey)
                return nil
            }
            // Retire the legacy path only once the file verifiably holds the key.
            guard (try? await setWebAPIKey(key)) != nil else { return key }
            defaults.set(true, forKey: Self.migrationDoneKey)
            legacySlot.delete()
            return key
        }
    }

    private static func isValidAPIKeyShape(_ key: String) -> Bool {
        key.range(of: keyPattern, options: [.regularExpression, .anchored]) != nil
    }
}
#endif
