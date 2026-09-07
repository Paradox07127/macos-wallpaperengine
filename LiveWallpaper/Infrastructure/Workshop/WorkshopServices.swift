#if !LITE_BUILD
import Foundation
import Observation

/// Bundles the Workshop online actors behind one `@Observable` host for
/// `@Environment(WorkshopServices.self)`. Actors aren't `@Observable`, so the
/// container mirrors `hasWebAPIKey` for UI bindings to read synchronously.
@MainActor
@Observable
final class WorkshopServices {
    @ObservationIgnored let keychain: WorkshopKeychainStore
    @ObservationIgnored let queryCache: WorkshopQueryCache
    @ObservationIgnored let queryService: WorkshopQueryService
    /// Key-free per-id lookups for the detail inspector (required items, a
    /// selection that is no longer on the page).
    @ObservationIgnored let itemDetails: WorkshopItemDetailsLoader

    var hasWebAPIKey: Bool = false
    /// True once a keychain read was refused — a denied ACL prompt, or a locked
    /// keychain. `hasWebAPIKey` stays true alongside it (the item is there),
    /// which is what lets the UI say "unlock it" instead of "set one".
    private(set) var apiKeyAccessDenied = false
    /// True once Valve explicitly rejected the stored key on a live request
    /// (401/403/disabled) — the key file existing no longer means "ready".
    /// Cleared by a later keyed success, or by `refreshAPIKeyStatus` once the
    /// stored key differs from the one that was rejected.
    private(set) var apiKeyRejected = false
    private(set) var rejectedKeyFingerprint: String?
    /// Bumped by every acceptance — the save path's in particular. A rejection
    /// that was awaiting the store's fingerprint across one was answered about
    /// the key as it was, and is discarded. Not bumped by a refresh: the
    /// deferred one in `init` would then swallow a rejection that merely
    /// overlapped it.
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
            // `self` owns `queryService`, which stores this handler: capturing
            // strongly here is the cycle, and a `[weak self]` one level further in
            // does not break it because the handler already holds the reference.
            await queryService.setAuthVerdictHandler { [weak self] accepted, fingerprint in
                Task { @MainActor in
                    await self?.noteAuthVerdict(accepted: accepted, keyFingerprint: fingerprint)
                }
            }
            await self.refreshAPIKeyStatus()
        }
    }

    func noteAuthVerdict(accepted: Bool, keyFingerprint: String) async {
        // A success can only clear a rejection recorded for the SAME key: a
        // stale in-flight 200 from a replaced key must not green-light the key
        // that was just refused.
        if accepted, apiKeyRejected, keyFingerprint != rejectedKeyFingerprint, !keyFingerprint.isEmpty {
            return
        }
        if accepted {
            keyGeneration += 1
        } else {
            // A rejection only counts against the key that is stored now: a
            // 403 for the key the user just replaced must not mark the new one.
            // Asked of the store at verdict time, not read from a refresh snapshot:
            // a save-then-fetch outruns `refreshAPIKeyStatus()`, and a refresh that
            // was in flight during the save would write the old key back over it.
            // With no fingerprint on record the rejection is taken at face value.
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
            // A different key was saved since the rejection (save() validates
            // the candidate against Valve first, so it starts trusted). Decided
            // from the store's record, never from a read: a read can raise the
            // keychain ACL prompt, and this runs on every pane appearance. No
            // record means unknown, and unknown is not different.
            await noteAuthVerdict(accepted: true, keyFingerprint: "")
        }
    }
}
#endif
