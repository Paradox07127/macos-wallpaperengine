#if !LITE_BUILD
import Darwin
import Foundation
import Security
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

/// In-memory stand-in for the login-keychain slot. Shared with the Workshop
/// service tests so no test ever writes the developer's real keychain.
final class WorkshopKeychainSlotSpy: @unchecked Sendable { // state guarded by `lock`
    private let lock = NSLock()
    private var stored: String?
    private let readDenied: Bool
    private let writeStatus: OSStatus

    init(stored: String? = nil, readDenied: Bool = false, writeStatus: OSStatus = errSecSuccess) {
        self.stored = stored
        self.readDenied = readDenied
        self.writeStatus = writeStatus
    }

    var storedKey: String? { lock.withLock { stored } }

    func slot() -> WorkshopKeychainSlot {
        WorkshopKeychainSlot(
            exists: { [self] in lock.withLock { stored != nil } },
            read: { [self] in
                lock.withLock {
                    if readDenied { return .denied }
                    return stored.map { .found($0) } ?? .absent
                }
            },
            write: { [self] key in
                lock.withLock {
                    guard writeStatus == errSecSuccess else { return writeStatus }
                    stored = key
                    return errSecSuccess
                }
            },
            delete: { [self] in lock.withLock { stored = nil; return errSecSuccess } }
        )
    }
}

@Suite("WorkshopKeychainStore")
struct WorkshopKeychainStoreTests {

    private static let sampleKey = String(repeating: "a1b2c3d4", count: 4)

    private static func makeStore(
        slot: WorkshopKeychainSlotSpy
    ) -> (store: WorkshopKeychainStore, fileURL: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-apikey-\(UUID().uuidString)", isDirectory: true)
        let store = WorkshopKeychainStore(directory: directory, slot: slot.slot())
        return (store, directory.appendingPathComponent("steam-webapi.key"), directory)
    }

    private static func writeContainerFile(_ key: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(key.utf8).write(to: url)
    }

    /// The keychain outranks the file: a save writes the keychain first and only
    /// then drops the file, so whenever both exist the file is the stale side (a
    /// failed removal, a backup restore, a half-written legacy copy).
    @Test("A corrupt leftover file does not shadow a valid keychain key")
    func corruptFileDoesNotShadowKeychain() async throws {
        let spy = WorkshopKeychainSlotSpy(stored: Self.sampleKey)
        let env = Self.makeStore(slot: spy)
        try Self.writeContainerFile("not-a-hex-key!", at: env.fileURL)

        let loaded = try await env.store.loadWebAPIKey()
        #expect(loaded == Self.sampleKey)
        #expect(!FileManager.default.fileExists(atPath: env.fileURL.path),
                "the corrupt leftover is dropped, not kept to shadow the next load")
    }

    @Test("A leftover file never overwrites a newer keychain key")
    func leftoverFileNeverOverwritesKeychain() async throws {
        let newerKey = String(repeating: "f9e8d7c6", count: 4)
        let spy = WorkshopKeychainSlotSpy(stored: newerKey)
        let env = Self.makeStore(slot: spy)
        // Same shape-valid content the pre-keychain versions persisted.
        try Self.writeContainerFile(Self.sampleKey, at: env.fileURL)

        let loaded = try await env.store.loadWebAPIKey()
        #expect(loaded == newerKey, "the keychain value wins")
        #expect(spy.storedKey == newerKey, "migration must not write the stale file over it")
        #expect(!FileManager.default.fileExists(atPath: env.fileURL.path))
    }

    @Test("Saving stores the key in the keychain, and Forget takes it back out")
    func saveAndForgetRoundTrip() async throws {
        let spy = WorkshopKeychainSlotSpy()
        let env = Self.makeStore(slot: spy)
        defer { try? FileManager.default.removeItem(at: env.directory) }

        try await env.store.setWebAPIKey(Self.sampleKey)
        #expect(spy.storedKey == Self.sampleKey)
        #expect(await env.store.hasWebAPIKey())
        #expect(try await env.store.loadWebAPIKey() == Self.sampleKey)

        try await env.store.deleteWebAPIKey()

        #expect(await env.store.hasWebAPIKey() == false)
        #expect(try await env.store.loadWebAPIKey() == nil)
    }

    @Test("The container file is imported into the keychain and then removed")
    func containerFileMigratesIntoTheKeychain() async throws {
        let spy = WorkshopKeychainSlotSpy()
        let env = Self.makeStore(slot: spy)
        defer { try? FileManager.default.removeItem(at: env.directory) }
        try Self.writeContainerFile(Self.sampleKey, at: env.fileURL)

        #expect(try await env.store.loadWebAPIKey() == Self.sampleKey)

        #expect(spy.storedKey == Self.sampleKey)
        #expect(FileManager.default.fileExists(atPath: env.fileURL.path) == false)
    }

    @Test("A legacy symlink is rejected without changing its target")
    func legacySymlinkIsRejectedWithoutChangingTarget() async throws {
        let spy = WorkshopKeychainSlotSpy()
        let env = Self.makeStore(slot: spy)
        defer { try? FileManager.default.removeItem(at: env.directory) }
        try FileManager.default.createDirectory(
            at: env.directory, withIntermediateDirectories: true
        )
        let targetURL = env.directory.appendingPathComponent("symlink-target.key")
        try Data(Self.sampleKey.utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: env.fileURL,
            withDestinationURL: targetURL
        )

        #expect(try await env.store.loadWebAPIKey() == nil)
        #expect(spy.storedKey == nil)
        #expect(FileManager.default.fileExists(atPath: env.fileURL.path) == false)
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == Self.sampleKey)
        #expect(await env.store.hasWebAPIKey() == false)
    }

    @Test("An oversized legacy file is rejected and removed")
    func oversizedLegacyFileIsRejected() async throws {
        let spy = WorkshopKeychainSlotSpy()
        let env = Self.makeStore(slot: spy)
        defer { try? FileManager.default.removeItem(at: env.directory) }
        try Self.writeContainerFile(String(repeating: "a", count: 65), at: env.fileURL)

        #expect(try await env.store.loadWebAPIKey() == nil)
        #expect(spy.storedKey == nil)
        #expect(FileManager.default.fileExists(atPath: env.fileURL.path) == false)
    }

    @Test("Legacy metadata requires a regular file owned by the current user")
    func legacyMetadataRequiresExpectedOwner() throws {
        let spy = WorkshopKeychainSlotSpy()
        let env = Self.makeStore(slot: spy)
        defer { try? FileManager.default.removeItem(at: env.directory) }
        try Self.writeContainerFile(Self.sampleKey, at: env.fileURL)

        #expect(WorkshopKeychainStore.legacyFileMetadataIsSafe(at: env.fileURL))
        #expect(
            WorkshopKeychainStore.legacyFileMetadataIsSafe(
                at: env.fileURL,
                expectedOwner: geteuid() &+ 1
            ) == false
        )
    }

    @Test("A refused keychain write keeps the container file and the key")
    func refusedWriteKeepsTheContainerFile() async throws {
        let spy = WorkshopKeychainSlotSpy(writeStatus: errSecAuthFailed)
        let env = Self.makeStore(slot: spy)
        defer { try? FileManager.default.removeItem(at: env.directory) }
        try Self.writeContainerFile(Self.sampleKey, at: env.fileURL)

        #expect(try await env.store.loadWebAPIKey() == Self.sampleKey)

        #expect(spy.storedKey == nil)
        #expect(FileManager.default.fileExists(atPath: env.fileURL.path))
    }

    @Test("A refused read reports denial, not a missing key")
    func deniedReadIsDistinctFromNoKey() async throws {
        let spy = WorkshopKeychainSlotSpy(stored: Self.sampleKey, readDenied: true)
        let env = Self.makeStore(slot: spy)
        defer { try? FileManager.default.removeItem(at: env.directory) }

        await #expect(throws: WorkshopKeychainStore.WorkshopKeychainError.accessDenied) {
            _ = try await env.store.loadWebAPIKey()
        }
        #expect(await env.store.readWasDenied)
        // The attribute probe must keep saying "there is a key here", or the UI
        // sends the user back to Steam for one they already have.
        #expect(await env.store.hasWebAPIKey())
    }
}
#endif
