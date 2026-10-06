import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Screen configuration cache refresh characterization", .serialized)
struct SettingsConfigurationCacheCharacterizationTests {
    @Test("Refreshed video bookmarks survive upper-cache reads and the real mute setter", arguments: [false, true])
    func refreshedVideoBookmarkSurvivesMutedSave(upperCacheWarm: Bool) throws {
        let defaults = try TestScratch.defaultsSuite(
            prefix: "LiveWallpaperTests.ConfigCacheRefresh.\(upperCacheWarm)"
        )
        defer { defaults.discard() }
        let nonce = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigCacheRefresh-\(nonce)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("synthetic.mp4")
        try Data([0]).write(to: video)
        // Synthetic bytes and an injected resolver exercise didRefresh without
        // acquiring a user's folder grant or retaining a security-scoped URL.
        let original = Data("original-\(nonce)".utf8)
        let refreshed = Data("refreshed-\(nonce)".utf8)
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { data in (video, data == original) },
            refreshData: { _ in refreshed }
        )
        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")),
            defaults: defaults.defaults, bookmarkResolver: resolver
        )
        defer { Task { await TestScratch.discard(root, flushing: manager) } }
        let screen = UndoTestManager.makeScreen("Config Cache \(nonce)", x: 0)
        var seeded = ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: original))
        seeded.displayFingerprint = screen.displayFingerprint
        manager.saveConfiguration(seeded)
        let store = WallpaperConfigurationStore(
            persistence: SettingsManagerScreenConfigurationPersistence(manager: manager)
        )
        if upperCacheWarm {
            #expect(store.get(for: screen.id, fingerprint: screen.displayFingerprint)?.videoBookmarkData == original)
        }
        let revisionBeforeValidation = store.revision(for: screen.id)

        // This is the same validator called immediately after PlaybackCoordinator
        // commits a video. It writes a didRefresh result through SettingsManager.
        try #require(manager.validateConfiguration(for: screen.id))
        try #require(manager.getConfiguration(for: screen.id)?.videoBookmarkData == refreshed,
                     "the injected stale-bookmark seam never exercised the lower-store refresh")
        let upperAfterRefresh = try #require(store.get(for: screen.id, fingerprint: screen.displayFingerprint))
        #expect(upperAfterRefresh.videoBookmarkData == refreshed,
                "a warm upper cache returned the obsolete bookmark after lower-store validation")
        let revisionAfterValidation = store.revision(for: screen.id)
        // Capture actual behavior even if the expectation above fails: the real
        // setter must still execute to test whether it writes old Data back down.
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(),
            validateSavedVideoConfiguration: { manager.validateConfiguration(for: $0) },
            applyPolicy: { _ in }, applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 }, screensProvider: { [screen] },
            markSessionStateChanged: {}, releaseRuntimeSession: { _ in },
            notifyWallpaperSessionChanged: {}, originReconciler: PreservingOriginReconciler()
        )
        let targetMuted = !seeded.muted
        coordinator.updateMuted(targetMuted, for: screen)
        let lowerAfterMute = try #require(manager.getConfiguration(for: screen.id))
        #expect(lowerAfterMute.muted == targetMuted, "the product mute setter did not save")
        #expect(lowerAfterMute.videoBookmarkData == refreshed,
                "the playback setter overwrote the lower store's refreshed bookmark")
        print("[5.6 baseline] warm=\(upperCacheWarm) upperKeptOriginal=\(upperAfterRefresh.videoBookmarkData == original) muteWroteOriginal=\(lowerAfterMute.videoBookmarkData == original) validationChangedUpperRevision=\(revisionAfterValidation != revisionBeforeValidation)")
    }

    @Test("Owner tokens retain exact-once store intent and ignore disk retries and other screens")
    func ownMutationsAndUnrelatedChanges() async throws {
        let fixture = try ConfigurationCacheFixture()
        defer { fixture.discard() }
        let store = fixture.store
        let manager = fixture.manager
        let config = ScreenConfiguration(screenID: 11, wallpaper: .video(bookmarkData: Data([1])))
        #expect(manager.loadConfigurations().isEmpty)
        #expect(manager.configurationMemoryRevision(for: 11) == 0)
        #expect(store.revision(for: 11) == 0)
        store.save(config)
        #expect(store.revision(for: 11) == 1)
        let ownerRevision = manager.configurationMemoryRevision(for: 11)
        store.save(config) // Same value is newer store intent, but unchanged owner data.
        #expect(store.revision(for: 11) == 2)
        manager.saveConfiguration(config)
        manager.saveConfiguration(ScreenConfiguration(screenID: 22, wallpaper: .video(bookmarkData: Data([2]))))
        #expect(await manager.flushPendingWrites())
        #expect(manager.configurationMemoryRevision(for: 11) == ownerRevision)
        #expect(store.revision(for: 11) == 2)
        #expect(store.get(for: 11) == config)
        store.remove(for: 11)
        #expect(store.revision(for: 11) == 3)
        #expect(store.get(for: 11) == nil)
        store.remove(for: 11) // Absent removal remains newer intent, exactly once.
        #expect(store.revision(for: 11) == 4)
    }

    enum ReadBoundary: CaseIterable {
        case get, revision, loadAll, clearCache
    }

    @Test("All cache read boundaries fence external edits and retain deletion tombstones", arguments: ReadBoundary.allCases)
    func externalChangesFencePreparedWork(boundary: ReadBoundary) throws {
        let fixture = try ConfigurationCacheFixture(function: "\(#function.prefix { $0 != "(" }).\(boundary)")
        defer { fixture.discard() }
        let store = fixture.store
        let manager = fixture.manager
        let original = ScreenConfiguration(screenID: 11, wallpaper: .video(bookmarkData: Data([1])))
        store.save(original)
        let preparedRevision = store.revision(for: 11)
        let refreshed = original.withUpdatedActiveBookmark(Data([2]))
        manager.saveConfiguration(refreshed)
        switch boundary {
        case .get: #expect(store.get(for: 11) == refreshed)
        case .revision: #expect(store.revision(for: 11) == preparedRevision + 1)
        case .loadAll: #expect(store.loadAll() == [refreshed])
        case .clearCache: store.clearCache()
        }
        #expect(store.revision(for: 11) == preparedRevision + 1)
        #expect(store.get(for: 11) == refreshed)
        #expect(store.revision(for: 11) == preparedRevision + 1)
        manager.cleanSettingsForScreen(11)
        #expect(store.get(for: 11) == nil)
        let deletedRevision = store.revision(for: 11)
        #expect(deletedRevision == preparedRevision + 2)
        store.clearCache()
        manager.saveConfiguration(original)
        #expect(store.revision(for: 11) == deletedRevision + 1)
        #expect(store.get(for: 11) == original)
    }

    @Test("Bulk changes compare each screen's ordered rows, including parked panels")
    func bulkAndParkedRows() throws {
        let fixture = try ConfigurationCacheFixture()
        defer { fixture.discard() }
        let manager = fixture.manager
        let live = ScreenConfiguration(screenID: 11, wallpaper: .video(bookmarkData: Data([1])))
        var parkedA = ScreenConfiguration(screenID: 0, wallpaper: .video(bookmarkData: Data([2])))
        parkedA.displayFingerprint = "panel:A"
        var parkedB = ScreenConfiguration(screenID: 0, wallpaper: .video(bookmarkData: Data([3])))
        parkedB.displayFingerprint = "panel:B"
        _ = manager.loadConfigurations()
        manager.replaceAllConfigurations([live, parkedA, parkedB])
        let liveRevision = manager.configurationMemoryRevision(for: 11)
        let parkedRevision = manager.configurationMemoryRevision(for: 0)
        manager.replaceAllConfigurations([parkedA, live, parkedB])
        #expect(manager.configurationMemoryRevision(for: 11) == liveRevision)
        #expect(manager.configurationMemoryRevision(for: 0) == parkedRevision)
        manager.replaceAllConfigurations([parkedB, live, parkedA])
        #expect(manager.configurationMemoryRevision(for: 0) == parkedRevision + 1)
        #expect(manager.getConfiguration(for: 0) == parkedB)
        var edited = parkedA
        edited.muted.toggle()
        manager.saveConfiguration(edited)
        #expect(manager.loadConfigurations() == [parkedB, live, edited])
        #expect(manager.configurationMemoryRevision(for: 0) == parkedRevision + 2)
        #expect(manager.configurationMemoryRevision(for: 11) == liveRevision)
        manager.replaceAllConfigurations([])
        #expect(manager.configurationMemoryRevision(for: 0) == parkedRevision + 3)
        #expect(manager.configurationMemoryRevision(for: 11) == liveRevision + 1)
        manager.replaceAllConfigurations([])
        #expect(manager.configurationMemoryRevision(for: 0) == parkedRevision + 3)
        #expect(manager.loadConfigurations().isEmpty)
    }

    @Test("Initial disk loading does not manufacture a memory mutation")
    func initialLoadKeepsZeroRevision() async throws {
        let fixture = try ConfigurationCacheFixture()
        let config = ScreenConfiguration(screenID: 11, wallpaper: .video(bookmarkData: Data([1])))
        fixture.manager.saveConfiguration(config)
        #expect(await fixture.manager.flushPendingWrites())
        let restarted = SettingsManager(directory: fixture.directory, defaults: fixture.defaults.defaults)
        defer { fixture.discard(flushing: restarted) }
        #expect(restarted.configurationMemoryRevision(for: 11) == 0)
        #expect(restarted.loadConfigurations() == [config])
        #expect(restarted.configurationMemoryRevision(for: 11) == 0)
        restarted.replaceAllConfigurations([])
        #expect(restarted.configurationMemoryRevision(for: 11) == 1)
        #expect(await restarted.flushPendingWrites())
    }

    @Test("A cold revision snapshot fences the first out-of-band bulk replacement")
    func coldRevisionFencesFirstReplacement() throws {
        let fixture = try ConfigurationCacheFixture()
        defer { fixture.discard() }
        let before = fixture.store.revision(for: 11) // Do not get/load a row first.
        let config = ScreenConfiguration(screenID: 11, wallpaper: .video(bookmarkData: Data([1])))
        fixture.manager.replaceAllConfigurations([config])
        try #require(fixture.manager.getConfiguration(for: 11) == config,
                     "the external replacement did not reach the lower owner")
        let after = fixture.store.revision(for: 11)
        #expect(after == before + 1, "the first external mutation reused the captured cold CAS revision")
        #expect(fixture.store.get(for: 11) == config)
        print("[5.6 cold revision] before=\(before) after=\(after) owner=\(fixture.manager.configurationMemoryRevision(for: 11))")
    }
}

@MainActor
private struct ConfigurationCacheFixture {
    let root: URL
    let defaults: TestScratch.DefaultsSuite
    let directory: ConfigurationDirectory
    let manager: SettingsManager
    let store: WallpaperConfigurationStore

    init(function: String = #function) throws {
        defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.ConfigCacheOwner", function: function)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigCacheOwner-\(UUID())")
        directory = ConfigurationDirectory(root: root)
        manager = SettingsManager(directory: directory, defaults: defaults.defaults)
        store = WallpaperConfigurationStore(persistence: SettingsManagerScreenConfigurationPersistence(manager: manager))
    }

    func discard(flushing other: SettingsManager? = nil) {
        Task {
            if let other {
                await TestScratch.discard(root, flushing: manager, other)
            } else {
                await TestScratch.discard(root, flushing: manager)
            }
            defaults.discard()
        }
    }
}
