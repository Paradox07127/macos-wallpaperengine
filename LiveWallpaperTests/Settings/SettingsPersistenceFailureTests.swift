import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Latest settings snapshots survive write failures", .serialized)
@MainActor
struct SettingsPersistenceFailureTests {
    @Test("All four domains retain failed edits through upper-store reload, then retry durably")
    func failureKeepsLatestAcrossOwners() async throws {
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.SM01")
        defer { defaults.discard() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SM01-\(UUID())")
        let directory = ConfigurationDirectory(root: root)
        let files = PromotionFailureFileManager()
        let manager = SettingsManager(directory: directory, defaults: defaults.defaults, fileManager: files)
        let configurations = WallpaperConfigurationStore(
            persistence: SettingsManagerScreenConfigurationPersistence(manager: manager)
        )
        let bookmarks = BookmarkStore(persistence: SettingsManagerBookmarkPersistence(manager: manager))
        let schemes = SchemeStore(persistence: SettingsManagerSchemePersistence(manager: manager))
        var config = ScreenConfiguration(screenID: 91, wallpaper: .video(bookmarkData: Data([1])))
        configurations.save(config)
        let bookmark = bookmarks.add(label: "Before", content: .video(bookmarkData: Data([2])))
        let scheme = schemes.add(name: "Before", configuration: config,
                                 overlay: MonitorOverlayConfiguration(enabled: true, level: .front))
        var global = manager.loadGlobalSettings()
        global.globalPauseOnBattery = false
        manager.saveGlobalSettings(global)
        #expect(await manager.flushPendingWrites())

        let diskConfigBefore = AtomicFileStore<[ScreenConfiguration]>(fileURL: directory.url(for: .screenConfigurations)).read()
        let diskBookmarksBefore = AtomicFileStore<[WallpaperBookmark]>(fileURL: directory.url(for: .wallpaperBookmarks)).read()
        let diskSchemesBefore = AtomicFileStore<[ScreenScheme]>(fileURL: directory.url(for: .screenSchemes)).read()
        files.failPromotions(to: [directory.url(for: .screenConfigurations), directory.url(for: .globalSettings),
                                  directory.url(for: .wallpaperBookmarks), directory.url(for: .screenSchemes)])
        config.playbackSpeed = 1.25
        configurations.save(config)
        bookmarks.rename(bookmark.id, to: "After")
        schemes.rename(scheme.id, to: "After")
        global.globalPauseOnBattery = true
        manager.saveGlobalSettings(global)
        let expectedBookmarks = bookmarks.bookmarks
        let expectedSchemes = schemes.schemes
        await manager.waitForPendingWrites() // Waits for actual completion, never a timer.

        #expect(manager.persistenceStatus.hasFailure)
        #expect(manager.persistenceStatus.hasUnsavedChanges)
        #expect(!manager.persistenceStatus.isSaving)
        for domain in SettingsPersistenceDomain.allCases {
            guard case .some(.failed) = manager.persistenceStatus.phases[domain] else {
                Issue.record("Missing failure status for \(domain)")
                continue
            }
        }
        for name in ["screen-configurations.json", "global-settings.json", "wallpaper-bookmarks.json", "screen-schemes.json"] {
            #expect(files.refusedPromotions(to: name) > 0, "Fault injector never reached \(name)")
        }
        #expect(configurations.get(for: 91) == config)
        #expect(configurations.loadAll() == [config]) // Previously repopulated its cache from old disk.
        bookmarks.reload()
        schemes.reload()
        #expect(bookmarks.bookmarks == expectedBookmarks)
        #expect(schemes.schemes == expectedSchemes)
        #expect(manager.loadGlobalSettings().globalPauseOnBattery)
        // The old disk copy survives; retaining desired memory does not pretend the disk write succeeded.
        #expect(AtomicFileStore<[ScreenConfiguration]>(fileURL: directory.url(for: .screenConfigurations)).read() == diskConfigBefore)
        #expect(AtomicFileStore<[WallpaperBookmark]>(fileURL: directory.url(for: .wallpaperBookmarks)).read() == diskBookmarksBefore)
        #expect(AtomicFileStore<[ScreenScheme]>(fileURL: directory.url(for: .screenSchemes)).read() == diskSchemesBefore)
        #expect(AtomicFileStore<GlobalSettings>(fileURL: directory.url(for: .globalSettings)).read()?.globalPauseOnBattery == false)
        #expect(await !(manager.flushPendingWrites())) // Persistent fault must not yield a successful flush.

        files.allowPromotions()
        #expect(await manager.flushPendingWrites()) // No additional edit is needed to recover.
        #expect(!manager.persistenceStatus.hasFailure)
        #expect(!manager.persistenceStatus.hasUnsavedChanges)
        let restarted = SettingsManager(directory: directory, defaults: defaults.defaults)
        #expect(restarted.loadConfigurations() == [config])
        #expect(restarted.loadWallpaperBookmarks() == expectedBookmarks)
        #expect(restarted.loadScreenSchemes() == expectedSchemes)
        #expect(restarted.loadGlobalSettings().globalPauseOnBattery)
        await TestScratch.discard(root, flushing: manager, restarted)
    }

    @Test("A failing global domain does not make a successful screen snapshot dirty; newer edits win on retry")
    func independentDomainsAndNewestRetry() async throws {
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.SM01")
        defer { defaults.discard() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SM01-\(UUID())")
        let directory = ConfigurationDirectory(root: root)
        let files = PromotionFailureFileManager()
        let manager = SettingsManager(directory: directory, defaults: defaults.defaults, fileManager: files)
        var global = manager.loadGlobalSettings()
        global.globalPauseOnBattery = false
        manager.saveGlobalSettings(global)
        #expect(await manager.flushPendingWrites())
        files.failPromotions(to: [directory.url(for: .globalSettings)])
        global.globalPauseOnBattery = true
        manager.saveGlobalSettings(global)
        let config = ScreenConfiguration(screenID: 92, wallpaper: .video(bookmarkData: Data([3])))
        manager.saveConfiguration(config)
        await manager.waitForPendingWrites()
        #expect(manager.persistenceStatus.phases[.configurations] == .saved)
        #expect(manager.persistenceStatus.phases[.globalSettings]?.error != nil)

        files.allowPromotions()
        global.globalPauseOnBattery = false
        manager.saveGlobalSettings(global)
        // Failure remains visible while the user-triggered replacement is still in flight.
        #expect(manager.persistenceStatus.hasFailure)
        #expect(manager.persistenceStatus.isSaving)
        global.globalPauseOnBattery = true
        manager.saveGlobalSettings(global)
        await manager.waitForPendingWrites()
        #expect(!manager.persistenceStatus.hasFailure)
        #expect(manager.loadGlobalSettings().globalPauseOnBattery)
        #expect(AtomicFileStore<GlobalSettings>(fileURL: directory.url(for: .globalSettings)).read()?.globalPauseOnBattery == true)
        #expect(AtomicFileStore<[ScreenConfiguration]>(fileURL: directory.url(for: .screenConfigurations)).read() == [config])
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("Failed generations fence older writes; same-generation retry works; reset fences resurrection")
    func actorGenerationFenceSurvivesFailureAndReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SM01-actor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = ConfigurationDirectory(root: root)
        let files = PromotionFailureFileManager()
        let configs = AtomicFileStore<[ScreenConfiguration]>(fileURL: directory.url(for: .screenConfigurations), fileManager: files)
        let actor = WallpaperPersistenceActor(
            store: configs,
            globalSettingsStore: AtomicFileStore(fileURL: directory.url(for: .globalSettings)),
            bookmarksStore: AtomicFileStore(fileURL: directory.url(for: .wallpaperBookmarks)),
            schemesStore: AtomicFileStore(fileURL: directory.url(for: .screenSchemes))
        )
        let old = ScreenConfiguration(screenID: 93, wallpaper: .video(bookmarkData: Data([4])))
        var newest = old
        newest.playbackSpeed = 1.5
        try await actor.write([old], generation: 1)
        files.failPromotions(to: [directory.url(for: .screenConfigurations)])
        do {
            try await actor.write([newest], generation: 2)
            Issue.record("Injected write unexpectedly succeeded")
        } catch {
            #expect(files.refusedPromotions(to: "screen-configurations.json") == 1)
        }
        // Deterministically submit an older value AFTER generation 2 has failed.
        try await actor.write([], generation: 1)
        #expect(files.refusedPromotions(to: "screen-configurations.json") == 1, "Stale write reached disk")
        #expect(configs.read() == [old])
        files.allowPromotions()
        try await actor.write([newest], generation: 2)
        #expect(configs.read() == [newest])
        await actor.delete(generation: 3)
        try await actor.write([old], generation: 2)
        #expect(configs.read() == nil)
        // Intentionally do not call cleanAllSettings: it also reaches shared cover/bookmark owners.
    }
}

/// Only fails the actual tmp → primary promotion, allowing backup rotation and rollback.
/// Every mutation of the injector is protected: FileManager is called on the persistence actor.
private final class PromotionFailureFileManager: FileManager, @unchecked Sendable {
    private let gate = NSLock()
    private var blocked: Set<String> = []
    private var receipts: [String: Int] = [:]

    func failPromotions(to urls: [URL]) {
        gate.lock()
        blocked = Set(urls.map(\.standardizedFileURL.path))
        receipts = [:]
        gate.unlock()
    }

    func allowPromotions() {
        gate.lock()
        blocked = []
        gate.unlock()
    }

    func refusedPromotions(to name: String) -> Int {
        gate.lock()
        defer { gate.unlock() }
        return receipts[name, default: 0]
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        gate.lock()
        let shouldFail = srcURL.pathExtension == "tmp" && blocked.contains(dstURL.standardizedFileURL.path)
        if shouldFail {
            receipts[dstURL.lastPathComponent, default: 0] += 1
        }
        gate.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
