#if !LITE_BUILD
import Foundation
import Observation

@MainActor
@Observable
final class WorkshopServices {
    @ObservationIgnored let keychain: WorkshopKeychainStore
    @ObservationIgnored let queryCache: WorkshopQueryCache
    @ObservationIgnored let queryService: WorkshopQueryService
    @ObservationIgnored let itemDetails: WorkshopItemDetailsLoader

    var hasWebAPIKey: Bool = false
    /// True once a keychain read was refused. `hasWebAPIKey` stays true alongside it so the UI can say "unlock it" instead of "set one".
    private(set) var apiKeyAccessDenied = false
    /// True once Valve rejected the stored key (401/403/disabled). Cleared by a later keyed success or when the stored key differs.
    private(set) var apiKeyRejected = false
    private(set) var rejectedKeyFingerprint: String?
    /// Bumped by every acceptance, not by a refresh: the deferred one in `init` would swallow a rejection that overlapped it.
    private var keyGeneration = 0

    /// The keyed paths need a key Valve currently accepts; a stored key it
    /// rejected is no better than none.
    var isKeyless: Bool {
        !hasWebAPIKey || apiKeyRejected
    }

    convenience init() {
        let keychain = WorkshopKeychainStore()
        let cache = WorkshopQueryCache()
        self.init(keychain: keychain, cache: cache, queryService: WorkshopQueryService(keychain: keychain, cache: cache))
    }

    init(
        keychain: WorkshopKeychainStore,
        cache: WorkshopQueryCache,
        queryService: WorkshopQueryService,
        itemDetails: WorkshopItemDetailsLoader = WorkshopItemDetailsLoader()
    ) {
        self.keychain = keychain
        self.queryCache = cache
        self.queryService = queryService
        self.itemDetails = itemDetails
        Task { @MainActor [weak self] in
            guard let self else { return }
            // `self` owns `queryService`, which stores this handler: capturing strongly is the cycle; `[weak self]` one level further in does not break it.
            await queryService.setAuthVerdictHandler { [weak self] accepted, fingerprint in
                Task { @MainActor in
                    await self?.noteAuthVerdict(accepted: accepted, keyFingerprint: fingerprint)
                }
            }
            await self.refreshAPIKeyStatus()
        }
    }

    func noteAuthVerdict(accepted: Bool, keyFingerprint: String) async {
        // A success can only clear a rejection recorded for the SAME key: a stale in-flight 200 from a replaced key must not green-light the new refusal.
        if accepted, apiKeyRejected, keyFingerprint != rejectedKeyFingerprint, !keyFingerprint.isEmpty {
            return
        }
        if accepted {
            keyGeneration += 1
        } else {
            // A rejection only counts against the key stored now. Asked of the store at verdict time, not a refresh snapshot.
            let generation = keyGeneration
            let current = await keychain.storedKeyFingerprint
            guard keyGeneration == generation else { return }
            if let current, current != keyFingerprint {
                return
            }
        }
        apiKeyRejected = !accepted
        rejectedKeyFingerprint = accepted ? nil : keyFingerprint
    }

    func refreshAPIKeyStatus() async {
        hasWebAPIKey = await keychain.hasWebAPIKey()
        apiKeyAccessDenied = await keychain.readWasDenied
        guard apiKeyRejected else { return }
        if !hasWebAPIKey {
            // Key removed — the rejection no longer describes anything.
            await noteAuthVerdict(accepted: true, keyFingerprint: "")
        } else if let current = await keychain.storedKeyFingerprint, current != rejectedKeyFingerprint {
            // A different key was saved since the rejection; decide from the store's fingerprint, never from a read (a read can raise the keychain ACL prompt).
            await noteAuthVerdict(accepted: true, keyFingerprint: "")
        }
    }
}
#endif
