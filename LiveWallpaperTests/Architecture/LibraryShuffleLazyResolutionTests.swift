#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Library shuffle resolves Workshop imports lazily", .serialized, .timeLimit(.minutes(1)))
struct LibraryShuffleLazyResolutionTests {
    private static func history(_ count: Int) -> [WPEHistoryEntry] {
        (0 ..< count).map { index in
            WPEHistoryEntry(
                origin: WPEOrigin(
                    workshopID: "lazy-\(index)", title: "Lazy \(index)", originalType: .scene,
                    sourceFolderBookmark: Data([UInt8(index)]), cacheRelativePath: "wpe-cache/lazy-\(index)", previewFileName: nil
                ),
                importedAt: Date(timeIntervalSince1970: 1)
            )
        }
    }

    private static func content(for origin: WPEOrigin) -> WallpaperContent {
        .html(source: .inline(origin.workshopID), config: .default)
    }

    @Test("Only the item the selection lands on is resolved")
    func resolvesUntilFirstSuccess() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let current = WallpaperContent.html(source: .inline("showing"), config: .default)
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: current)
        initial.wallpaperMode = .libraryShuffle
        let persistence = LazyShuffleConfigurationPersistence([initial])
        let store = WallpaperConfigurationStore(persistence: persistence)
        let items = Self.history(5)
        var resolutions = 0
        let candidates = LibraryShufflePolicy.workshopCandidates(in: items) { origin in
            resolutions += 1
            return Self.content(for: origin)
        }
        #expect(resolutions == 0, "listing the library opened its items")
        var committed: [WallpaperContent] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                committed.append(proposed.activeWallpaper)
                store.save(proposed)
                return .ready
            },
            libraryEntries: { candidates }, libraryEntryAvailable: { _ in true }
        )
        orchestrator.advanceLibraryShuffle(for: screen)
        for _ in 0 ..< 100 where committed.isEmpty {
            await Task.yield()
        }

        #expect(committed.count == 1)
        #expect(resolutions == 1, "resolved \(resolutions) of \(items.count) items to pick one")
    }

    @Test("The showing Workshop scene is excluded by its id without resolving anything")
    func excludesShowingSceneByWorkshopID() {
        let items = Self.history(3)
        var resolutions = 0
        let candidates = LibraryShufflePolicy.workshopCandidates(in: items) { origin in
            resolutions += 1
            return Self.content(for: origin)
        }
        let showing = SceneDescriptor(
            workshopID: items[1].id, cacheRelativePath: "wpe-cache/\(items[1].id)", entryFile: "scene.json", capabilityTier: .imageOnly
        )

        let remaining = LibraryShufflePolicy.candidates(in: candidates, excluding: .scene(showing), origin: nil)
        let byOrigin = LibraryShufflePolicy.candidates(
            in: candidates, excluding: .video(bookmarkData: Data([9])), origin: items[2].origin
        )

        #expect(remaining.map(\.id) == ["workshop:\(items[0].id)", "workshop:\(items[2].id)"])
        #expect(byOrigin.map(\.id) == ["workshop:\(items[0].id)", "workshop:\(items[1].id)"])
        #expect(resolutions == 0)
    }
}

@MainActor
private final class LazyShuffleConfigurationPersistence: ScreenConfigurationPersisting {
    private var configurations: [ScreenConfiguration]

    init(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations.first { $0.screenID == screenID }
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations.removeAll { $0.screenID == configuration.screenID }
        configurations.append(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations.removeAll { $0.screenID == screenID }
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        configurations
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }
}
#endif
