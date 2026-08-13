#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WorkshopQueryCache")
struct WorkshopQueryCacheTests {

    @Test("Cache writes, reads, sizes, and clears pages on disk")
    func cacheRoundTripsPagesOnDisk() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("workshop-query-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let cache = WorkshopQueryCache(
            directoryURL: directory,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let page = WorkshopQueryPage(
            items: [
                WorkshopQueryItem(
                    id: 123,
                    title: "Aurora",
                    shortDescription: "Test item",
                    creatorID: "76561190000000000",
                    creatorPersonaName: "Creator",
                    previewImageURL: URL(string: "https://steamuserimages-a.akamaihd.net/test.jpg"),
                    fileSizeBytes: 42,
                    timeUpdated: Date(timeIntervalSince1970: 9_000),
                    subscriptionCount: 7,
                    voteScore: 0.9,
                    tags: ["Scene"],
                    visibility: .public,
                    isBanned: false,
                    steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=123")!
                )
            ],
            nextCursor: "next",
            totalAvailable: 1
        )

        await cache.write(page, forKey: "test-key")

        #expect(await cache.read(forKey: "test-key") == page)
        #expect(await cache.sizeBytes() > 0)

        await cache.clear()

        #expect(await cache.read(forKey: "test-key") == nil)
        #expect(await cache.sizeBytes() == 0)
    }
}

/// Fake legacy slot. Defaults to the ad-hoc reality the migration has to
/// survive: the item is readable but `delete()` never actually removes it.
private final class LegacySlotSpy: @unchecked Sendable { // state guarded by `lock`
    private let lock = NSLock()
    private var outcomes: [WorkshopLegacyKeychainSlot.ReadOutcome]
    private var _readCount = 0
    private var _deletable: Bool
    private var _present: Bool

    init(outcomes: [WorkshopLegacyKeychainSlot.ReadOutcome], deletable: Bool = false) {
        self.outcomes = outcomes
        _deletable = deletable
        _present = true
    }

    var readCount: Int { lock.withLock { _readCount } }

    func slot() -> WorkshopLegacyKeychainSlot {
        WorkshopLegacyKeychainSlot(
            exists: { [self] in lock.withLock { _present } },
            read: { [self] in
                lock.withLock {
                    _readCount += 1
                    guard _present, !outcomes.isEmpty else { return .absent }
                    return outcomes.count == 1 ? outcomes[0] : outcomes.removeFirst()
                }
            },
            delete: { [self] in lock.withLock { if _deletable { _present = false } } }
        )
    }
}

@Suite("WorkshopKeychainStore")
struct WorkshopKeychainStoreTests {

    private static let sampleKey = String(repeating: "a1b2c3d4", count: 4)

    private static func makeStore(
        legacy: LegacySlotSpy
    ) -> (store: WorkshopKeychainStore, directory: URL, suiteName: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-apikey-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "workshop-apikey-tests-\(UUID().uuidString)"
        let store = WorkshopKeychainStore(
            directory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            legacySlot: legacy.slot()
        )
        return (store, directory, suiteName)
    }

    @Test("Forget is terminal even when the legacy keychain item survives deletion")
    func forgetIsNotUndoneByLegacyReimport() async throws {
        let legacy = LegacySlotSpy(outcomes: [.found(Self.sampleKey)], deletable: false)
        let env = Self.makeStore(legacy: legacy)
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            UserDefaults.standard.removePersistentDomain(forName: env.suiteName)
        }

        try await env.store.setWebAPIKey(Self.sampleKey)
        #expect(await env.store.hasWebAPIKey())

        try await env.store.deleteWebAPIKey()

        #expect(await env.store.hasWebAPIKey() == false)
        #expect(try await env.store.loadWebAPIKey() == nil)
    }

    @Test("Legacy import runs once and is not retried after the file is gone")
    func legacyImportIsOneShot() async throws {
        let legacy = LegacySlotSpy(outcomes: [.found(Self.sampleKey)], deletable: false)
        let env = Self.makeStore(legacy: legacy)
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            UserDefaults.standard.removePersistentDomain(forName: env.suiteName)
        }

        #expect(try await env.store.loadWebAPIKey() == Self.sampleKey)
        #expect(legacy.readCount == 1)

        // Simulate the file disappearing for any reason other than Forget.
        try FileManager.default.removeItem(at: env.directory)

        #expect(try await env.store.loadWebAPIKey() == nil)
        #expect(legacy.readCount == 1)
    }

    @Test("A cancelled keychain prompt does not burn the one-shot import")
    func cancelledPromptKeepsImportAvailable() async throws {
        let legacy = LegacySlotSpy(outcomes: [.denied, .found(Self.sampleKey)], deletable: false)
        let env = Self.makeStore(legacy: legacy)
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            UserDefaults.standard.removePersistentDomain(forName: env.suiteName)
        }

        #expect(try await env.store.loadWebAPIKey() == nil)
        #expect(try await env.store.loadWebAPIKey() == Self.sampleKey)
    }
}
#endif
