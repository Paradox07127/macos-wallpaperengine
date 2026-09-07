#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Security
import Testing

/// A verdict names the key that earned it. A 403 for a key the user has
/// since replaced must not mark the new key rejected, so the rejection is
/// checked against the key the store last read or wrote.
@Suite("Workshop services key verdicts")
@MainActor
struct WorkshopServicesTests {
    private static let currentKey = String(repeating: "a1b2c3d4", count: 4)
    private static let currentFingerprint = WorkshopQueryService.keyFingerprint(currentKey)
    private static let replacementKey = String(repeating: "0f1e2d3c", count: 4)
    private static let replacementFingerprint = WorkshopQueryService.keyFingerprint(replacementKey)

    @Test("A rejection for a replaced key does not mark the current one")
    func staleRejectionIsIgnored() async throws {
        let (services, keychain) = Self.makeServices()
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()
        try #require(services.hasWebAPIKey)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: "stale")

        #expect(!services.apiKeyRejected)
        #expect(!services.isKeyless)
    }

    @Test("A rejection for the current key marks it; its own acceptance clears it")
    func currentKeyRejectionRoundTrips() async throws {
        let (services, keychain) = Self.makeServices()
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()

        await services.noteAuthVerdict(accepted: false, keyFingerprint: Self.currentFingerprint)
        #expect(services.apiKeyRejected)
        #expect(services.isKeyless)

        await services.noteAuthVerdict(accepted: true, keyFingerprint: Self.currentFingerprint)
        #expect(!services.apiKeyRejected)
        #expect(!services.isKeyless)
    }

    /// The store tracks the key every save writes and every fetch reads, so a
    /// verdict compares against that — not against a snapshot the last
    /// `refreshAPIKeyStatus()` took, which a save-then-fetch can outrun.
    @Test("A rejection for a key saved since the last refresh marks it")
    func rejectionForKeySavedAfterRefreshCounts() async throws {
        let (services, keychain) = Self.makeServices()
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()
        try await keychain.setWebAPIKey(Self.replacementKey)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: Self.replacementFingerprint)

        #expect(services.apiKeyRejected)
        #expect(services.rejectedKeyFingerprint == Self.replacementFingerprint)
    }

    @Test("Control: a rejection for the key that was replaced is still ignored")
    func rejectionForReplacedKeyStaysIgnored() async throws {
        let (services, keychain) = Self.makeServices()
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()
        try await keychain.setWebAPIKey(Self.replacementKey)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: Self.currentFingerprint)

        #expect(!services.apiKeyRejected)
    }

    /// Control: a key that is stored but has never been read or written through
    /// this store has no fingerprint on record, and every rejection counts.
    @Test("Control: with no fingerprint on record a rejection is taken at face value")
    func unknownCurrentKeyStaysConservative() async throws {
        let (services, _) = Self.makeServices(stored: Self.currentKey)
        await services.refreshAPIKeyStatus()
        try #require(services.hasWebAPIKey)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: "stale")

        #expect(services.apiKeyRejected)
    }

    // MARK: - Refresh under a standing rejection

    /// A keychain read can raise the ACL prompt; `refreshAPIKeyStatus` runs on
    /// every pane appearance, so under a rejection it must decide from the
    /// fingerprint the store already holds, never from a read of its own.
    @Test("A refresh under a standing rejection does not read the key")
    func refreshUnderRejectionDoesNotReadKey() async throws {
        let slot = CountingKeychainSlot()
        let (services, keychain) = Self.makeServices(slot: slot)
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()
        await services.noteAuthVerdict(accepted: false, keyFingerprint: Self.currentFingerprint)
        try #require(services.apiKeyRejected)

        await services.refreshAPIKeyStatus()

        #expect(slot.readCount == 0)
        #expect(services.apiKeyRejected)
        #expect(services.hasWebAPIKey)
    }

    @Test("A refresh clears the rejection once a different key was saved, still without a read")
    func refreshClearsRejectionForReplacedKeyWithoutRead() async throws {
        let slot = CountingKeychainSlot()
        let (services, keychain) = Self.makeServices(slot: slot)
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()
        await services.noteAuthVerdict(accepted: false, keyFingerprint: Self.currentFingerprint)
        try await keychain.setWebAPIKey(Self.replacementKey)

        await services.refreshAPIKeyStatus()

        #expect(!services.apiKeyRejected)
        #expect(slot.readCount == 0)
    }

    /// Control: a key the store has never read or written has no fingerprint,
    /// and "unknown" is not "different" — the rejection stands.
    @Test("Control: with no fingerprint on record a refresh keeps the rejection")
    func refreshKeepsRejectionWhenFingerprintUnknown() async throws {
        let (services, _) = Self.makeServices(stored: Self.currentKey)
        await services.refreshAPIKeyStatus()
        await services.noteAuthVerdict(accepted: false, keyFingerprint: "stale")
        try #require(services.apiKeyRejected)

        await services.refreshAPIKeyStatus()

        #expect(services.apiKeyRejected)
    }

    // MARK: - Saving again

    /// A key can be refused and later pass validation again (a Valve-side
    /// disable that was lifted). Saving it must clear the rejection: the
    /// stored fingerprint has not changed, so the refresh cannot tell.
    @Test("Saving the rejected key again after it validates clears the rejection")
    func resavingRejectedKeyClearsRejection() async throws {
        let (services, keychain) = Self.makeServices()
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()
        await services.noteAuthVerdict(accepted: false, keyFingerprint: Self.currentFingerprint)
        try #require(services.isKeyless)

        var dependencies = SteamWebAPIKeyEntryModel.Dependencies.live(services: services)
        dependencies.validationDelayNanoseconds = 0
        dependencies.validateAPIKey = { _ in true }
        let model = SteamWebAPIKeyEntryModel(dependencies: dependencies)
        model.apiKey = Self.currentKey
        model.keyChanged()
        while model.validation == .validating {
            await Task.yield()
        }
        try #require(await model.save())

        #expect(!services.apiKeyRejected)
        #expect(!services.isKeyless)
    }

    // MARK: - Verdict generations

    /// A's late 403 asks the store for the current fingerprint and is answered
    /// "A"; before it resumes on the main actor, B is saved and accepted. The
    /// fingerprint snapshot alone would then mark A rejected over B.
    @Test("A rejection that straddles a save is discarded")
    func verdictStraddlingSaveIsDropped() async throws {
        let slot = CountingKeychainSlot(blockingReads: true)
        let (services, keychain) = Self.makeServices(slot: slot)
        try await keychain.setWebAPIKey(Self.currentKey)
        await services.refreshAPIKeyStatus()

        // Park the store on a read so the verdict's fingerprint lookup queues
        // behind it — and is answered "A" once released.
        let holder = Task { _ = try? await keychain.loadWebAPIKey() }
        while !slot.isBlockedInRead {
            await Task.yield()
        }
        let verdict = Task { @MainActor in
            await services.noteAuthVerdict(accepted: false, keyFingerprint: Self.currentFingerprint)
        }
        await Task.yield()
        slot.releaseReads()
        // No suspension between here and `verdict.value`: the acceptance lands
        // before the stale verdict can resume.
        await services.noteAuthVerdict(accepted: true, keyFingerprint: Self.replacementFingerprint)
        await holder.value
        await verdict.value

        #expect(!services.apiKeyRejected)
    }

    private static func makeServices(
        stored: String? = nil, slot: CountingKeychainSlot? = nil
    ) -> (WorkshopServices, WorkshopKeychainStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-services-\(UUID().uuidString)", isDirectory: true)
        let keychain = WorkshopKeychainStore(
            directory: directory, slot: slot?.slot() ?? WorkshopKeychainSlotSpy(stored: stored).slot()
        )
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let service = WorkshopQueryService(keychain: keychain, cache: cache, countIssuedRequest: {})
        return (WorkshopServices(keychain: keychain, cache: cache, queryService: service), keychain)
    }
}

/// A keychain slot that counts reads, and can hold the first one open until
/// released (only the first: a code path that reads again after the release
/// must not hang the run).
/// @unchecked Sendable: every access to the stored state goes through `lock`.
private final class CountingKeychainSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var reads = 0
    private var blockedInRead = false
    private var released = false
    private let blockingReads: Bool
    private let gate = DispatchSemaphore(value: 0)

    init(blockingReads: Bool = false) {
        self.blockingReads = blockingReads
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    var isBlockedInRead: Bool {
        lock.withLock { blockedInRead }
    }

    func releaseReads() {
        lock.withLock { released = true }
        gate.signal()
    }

    func slot() -> WorkshopKeychainSlot {
        WorkshopKeychainSlot(
            exists: { [self] in lock.withLock { stored != nil } },
            read: { [self] in
                let blocks: Bool = lock.withLock {
                    reads += 1
                    let blocks = blockingReads && !released
                    blockedInRead = blocks
                    return blocks
                }
                if blocks {
                    gate.wait()
                    lock.withLock { blockedInRead = false }
                }
                return lock.withLock { stored.map { .found($0) } ?? .absent }
            },
            write: { [self] key in
                lock.withLock { stored = key }
                return errSecSuccess
            },
            delete: { [self] in
                lock.withLock { stored = nil }
                return errSecSuccess
            }
        )
    }
}
#endif
