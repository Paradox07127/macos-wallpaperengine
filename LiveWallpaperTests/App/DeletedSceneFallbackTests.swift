#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Deleting the showing scene moves the display on by its mode", .serialized, .timeLimit(.minutes(1)))
struct DeletedSceneFallbackTests {
    private struct Item {
        let entry: WallpaperQueueEntry
        let descriptor: SceneDescriptor
        let history: WPEHistoryEntry
    }

    private static func makeItem(_ name: String) -> Item {
        let workshopID = "deleted-scene-\(name)-\(UUID().uuidString)"
        let origin = WPEOrigin(
            workshopID: workshopID, title: name, originalType: .scene, sourceFolderBookmark: Data([0xA1]),
            cacheRelativePath: "wpe-cache/\(workshopID)", previewFileName: nil
        )
        let descriptor = SceneDescriptor(workshopID: workshopID, cacheRelativePath: "wpe-cache/\(workshopID)",
                                         entryFile: "scene.json", capabilityTier: .imageOnly)
        return Item(
            entry: WallpaperQueueEntry(id: "queue-\(name)", title: name, content: .scene(descriptor), origin: origin),
            descriptor: descriptor,
            history: WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil)
        )
    }

    private static func showing(_ item: Item) -> ScreenConfiguration {
        var configuration = ScreenConfiguration(screenID: 0, wallpaper: .scene(item.descriptor))
        configuration.wpeOrigin = item.entry.origin
        return configuration
    }

    /// Runs `body` against a manager whose automatic selection commits every candidate except those whose workshop id is in `failing`.
    private static func withManager(
        seeding seeded: ScreenConfiguration, deleting deleted: Item,
        library: [WallpaperQueueEntry] = [], failing: Set<String> = [],
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer { SettingsManager.shared.cleanAllSettings(applyLoginSetting: false) }
        let screen = Screen(nsScreen: DeletedSceneTestNSScreen())
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
        ))
        defer {
            manager.tearDownForTermination()
            manager.configurationStore.remove(for: screen.id)
        }
        manager.automationOrchestrator = WallpaperAutomationOrchestrator(
            configurationStore: manager.configurationStore, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { manager.saveConfiguration($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { manager.bumpTransition(for: $0) },
            isCurrentTransition: { manager.isCurrentTransition($0, for: $1) },
            prepareAutomation: { screen, proposed, _, intended in
                // Mirrors the product commit: a revision that moved after the prepare began voids the candidate.
                let revision = manager.configurationStore.revision(for: screen.id)
                await Task.yield()
                let failed = proposed.wpeOrigin.map { failing.contains($0.workshopID) } ?? false
                guard !failed, intended(), manager.configurationStore.revision(for: screen.id) == revision else { return .failed }
                manager.saveConfiguration(proposed)
                return .ready
            },
            libraryEntries: { library.map(LibraryShuffleCandidate.init) },
            libraryEntryAvailable: { _ in true }
        )
        SettingsManager.shared.recordWPEImport(deleted.history)
        var configuration = seeded
        configuration.screenID = screen.id
        configuration.displayFingerprint = screen.displayFingerprint
        manager.saveConfiguration(configuration)
        #expect(manager.removeWPEImport(workshopID: deleted.history.origin.workshopID, matchingImportedAt: deleted.history.importedAt))
        try await body(manager, screen)
    }

    private static func settle(until done: () -> Bool) async {
        for _ in 0 ..< 500 where !done() {
            await Task.yield()
        }
    }

    @Test("A playlist moves to its next entry and keeps its row, queue and other scene edits")
    func playlistMovesToNextEntry() async throws {
        let (a, b, c) = (Self.makeItem("A"), Self.makeItem("B"), Self.makeItem("C"))
        let editedC = c.descriptor.withPropertyOverrides(["enabled": .bool(false)])
        let queue = [a.entry, b.entry, c.entry]
        var seeded = Self.showing(a)
        seeded.wallpaperQueue = queue
        seeded.playlistCursorIndex = 0
        seeded.savedSceneCustomizations = [editedC]
        try await Self.withManager(seeding: seeded, deleting: a) { manager, screen in
            await Self.settle { manager.getConfiguration(for: screen)?.wpeOrigin == b.entry.origin }

            guard let stored = manager.getConfiguration(for: screen) else {
                Issue.record("the row was deleted instead of moving on")
                return
            }
            guard case let .scene(showing) = stored.activeWallpaper else {
                Issue.record("the display does not show a scene: \(stored.activeWallpaper)")
                return
            }
            #expect(showing.isSameScene(as: b.descriptor))
            #expect(stored.wpeOrigin == b.entry.origin)
            #expect(stored.playlistCursorIndex == 1)
            #expect(stored.wallpaperQueue == queue)
            #expect(stored.savedSceneCustomizations.contains(editedC))
        }
    }

    @Test("A playlist whose only entry is the deleted scene loses its row")
    func playlistWithOnlyDeletedEntryClears() async throws {
        let a = Self.makeItem("A")
        var seeded = Self.showing(a)
        seeded.wallpaperQueue = [a.entry]
        try await Self.withManager(seeding: seeded, deleting: a) { manager, screen in
            await Self.settle { manager.getConfiguration(for: screen) == nil }
            #expect(manager.getConfiguration(for: screen) == nil)
        }
    }

    @Test("A playlist whose remaining entries all fail to load loses its row")
    func playlistWithFailingEntriesClears() async throws {
        let (a, b) = (Self.makeItem("A"), Self.makeItem("B"))
        var seeded = Self.showing(a)
        seeded.wallpaperQueue = [a.entry, b.entry]
        try await Self.withManager(seeding: seeded, deleting: a, failing: [b.history.origin.workshopID]) { manager, screen in
            await Self.settle { manager.getConfiguration(for: screen) == nil }
            #expect(manager.getConfiguration(for: screen) == nil)
        }
    }

    @Test("A schedule loses its row even with a saved video to fall back on")
    func scheduleClears() async throws {
        let a = Self.makeItem("A")
        var seeded = Self.showing(a)
        seeded.savedVideoBookmarkData = Data("saved-video".utf8)
        seeded.wallpaperMode = .schedule
        seeded.scheduleFallback = a.entry
        try await Self.withManager(seeding: seeded, deleting: a) { manager, screen in
            await Self.settle { manager.getConfiguration(for: screen) == nil }
            #expect(manager.getConfiguration(for: screen) == nil)
        }
    }

    @Test("Library shuffle moves to another library item")
    func libraryShuffleMovesToAnotherItem() async throws {
        let (a, b) = (Self.makeItem("A"), Self.makeItem("B"))
        var seeded = Self.showing(a)
        seeded.wallpaperMode = .libraryShuffle
        try await Self.withManager(seeding: seeded, deleting: a, library: [a.entry, b.entry]) { manager, screen in
            await Self.settle { manager.getConfiguration(for: screen)?.wpeOrigin == b.entry.origin }
            guard let stored = manager.getConfiguration(for: screen) else {
                Issue.record("the row was deleted instead of moving on")
                return
            }
            #expect(stored.wpeOrigin == b.entry.origin)
            #expect(stored.wallpaperMode == .libraryShuffle)
        }
    }
}

private final class DeletedSceneTestNSScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xDE1E_7E5C)]
    }

    override var localizedName: String {
        "Deleted Scene Fallback Test"
    }
}
#endif
