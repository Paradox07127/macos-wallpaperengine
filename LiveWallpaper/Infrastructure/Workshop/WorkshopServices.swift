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
    @ObservationIgnored private var rejectedKeyFingerprint: String?

    init() {
        let keychain = WorkshopKeychainStore()
        let cache = WorkshopQueryCache()
        self.keychain = keychain
        self.queryCache = cache
        self.queryService = WorkshopQueryService(keychain: keychain, cache: cache)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // `self` owns `queryService`, which stores this handler: capturing
            // strongly here is the cycle, and a `[weak self]` one level further in
            // does not break it because the handler already holds the reference.
            await queryService.setAuthVerdictHandler { [weak self] accepted, fingerprint in
                Task { @MainActor in
                    self?.noteAuthVerdict(accepted: accepted, keyFingerprint: fingerprint)
                }
            }
            await self.refreshAPIKeyStatus()
        }
    }

    func noteAuthVerdict(accepted: Bool, keyFingerprint: String) {
        // A success can only clear a rejection recorded for the SAME key: a
        // stale in-flight 200 from a replaced key must not green-light the key
        // that was just refused.
        if accepted, apiKeyRejected, keyFingerprint != rejectedKeyFingerprint, !keyFingerprint.isEmpty {
            return
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
            noteAuthVerdict(accepted: true, keyFingerprint: "")
        } else if let key = (try? await keychain.loadWebAPIKey()) ?? nil,
                  WorkshopQueryService.keyFingerprint(key) != rejectedKeyFingerprint {
            // A different key was saved since the rejection (save() validates
            // the candidate against Valve first, so it starts trusted).
            noteAuthVerdict(accepted: true, keyFingerprint: "")
        }
    }
}
#endif
