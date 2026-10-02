#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Workshop shared-repository mutation gate", .serialized)
struct WorkshopMutationGateTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)

    private func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
    }

    /// Steam names Workshop folders by a numeric id; `steamFolderItemID` ignores anything else.
    private static func uniqueID() -> String {
        String(UInt64.random(in: 1_000_000_000 ... 9_999_999_999))
    }

    private func folder(_ relativePath: String) throws -> URL {
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func steamFolder(_ folderID: String) throws -> URL {
        try folder("steamapps/workshop/content/431960/\(folderID)")
    }

    private static func descriptor(_ workshopID: String) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: "wpe-cache/\(workshopID)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
    }

    /// `source` nil = the item's own Steam Workshop folder.
    private func origin(
        _ workshopID: String,
        source: URL? = nil,
        type: WPEType = .scene,
        dependencies: [String] = []
    ) throws -> WPEOrigin {
        try WPEOrigin(
            workshopID: workshopID,
            title: workshopID,
            originalType: type,
            sourceFolderBookmark: #require(ResourceUtilities.createBookmark(for: source ?? steamFolder(workshopID))),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: nil,
            dependencyWorkshopIDs: dependencies
        )
    }

    private static func sceneConfiguration(_ origin: WPEOrigin, for screenID: CGDirectDisplayID) -> ScreenConfiguration {
        var configuration = ScreenConfiguration(screenID: screenID, wallpaper: .scene(descriptor(origin.workshopID)))
        configuration.wpeOrigin = origin
        return configuration
    }

    private static func post(_ name: Notification.Name, _ workshopID: String) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["workshopID": workshopID])
    }

    private static func drainMainQueue() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        await Task.yield()
    }

    /// `playing` nil = no saved configuration; otherwise the display is saved as showing that scene item.
    private func withScreen(
        playing origin: WPEOrigin? = nil,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async rethrows {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let original = SettingsManager.shared.loadConfigurations()
        defer {
            screen.resetRuntimeSession()
            SettingsManager.shared.replaceAllConfigurations(original)
            try? FileManager.default.removeItem(at: root)
        }
        SettingsManager.shared.replaceAllConfigurations(origin.map { [Self.sceneConfiguration($0, for: screen.id)] } ?? [])
        let manager = makeManager()
        manager.screens = [screen]
        try await body(manager, screen)
        manager.bumpTransition(for: screen.id)
        await Self.drainMainQueue()
    }

    @Test("Applying an item while it is being rewritten saves it, builds no session, and reloads after the rewrite")
    func applyDuringMutationIsDeferredUntilDidMutate() async throws {
        let itemID = Self.uniqueID()
        let origin = try origin(itemID)
        await withScreen { manager, screen in
            Self.post(.workshopItemWillMutate, itemID)

            manager.setSceneWallpaper(descriptor: Self.descriptor(itemID), origin: origin, for: screen)

            #expect(screen.runtimeSession == nil)
            #expect(manager.wallpaperLoads.attempt(for: screen) == nil)
            #expect(manager.configurationStore.get(for: screen.id)?.wpeOrigin?.workshopID == itemID)
            #expect(manager.workshopMutationSuspendedScreenIDs[itemID]?.contains(screen.id) == true)

            Self.post(.workshopItemDidMutate, itemID)

            #expect(manager.workshopMutationSuspendedScreenIDs[itemID] == nil)
            #expect(manager.wallpaperLoads.attempt(for: screen) != nil)
        }
    }

    @Test("A scene that depends on the rewritten item is suspended and reloaded with it")
    func dependentSceneIsSuspendedAndReloaded() async throws {
        let dependencyID = Self.uniqueID()
        let origin = try origin(Self.uniqueID(), dependencies: [dependencyID])
        await withScreen(playing: origin) { manager, screen in
            screen.installRuntimeSession(GateFakeRuntimeSession())

            Self.post(.workshopItemWillMutate, dependencyID)

            #expect(screen.runtimeSession == nil)
            #expect(manager.workshopMutationSuspendedScreenIDs[dependencyID]?.contains(screen.id) == true)

            Self.post(.workshopItemDidMutate, dependencyID)

            #expect(manager.wallpaperLoads.attempt(for: screen) != nil)
        }
    }

    @Test("A display switched to another wallpaper during the rewrite is not switched back")
    func switchAwayDuringMutationIsKept() async throws {
        let itemID = Self.uniqueID()
        let origin = try origin(itemID)
        await withScreen { manager, screen in
            Self.post(.workshopItemWillMutate, itemID)
            manager.setSceneWallpaper(descriptor: Self.descriptor(itemID), origin: origin, for: screen)

            let replacement = ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([0xC0, 0xDE])))
            manager.saveConfiguration(replacement)

            Self.post(.workshopItemDidMutate, itemID)

            #expect(manager.wallpaperLoads.attempt(for: screen) == nil)
            #expect(manager.configurationStore.get(for: screen.id)?.activeWallpaper == replacement.activeWallpaper)
        }
    }

    @Test("A local copy that shares the rewritten item's manifest id keeps playing")
    func localCopyIsNotSuspended() async throws {
        let itemID = Self.uniqueID()
        let origin = try origin(itemID, source: folder("Wallpapers/\(itemID)"))
        await withScreen(playing: origin) { manager, screen in
            screen.installRuntimeSession(GateFakeRuntimeSession())

            Self.post(.workshopItemWillMutate, itemID)

            #expect(screen.runtimeSession != nil)
            #expect(manager.workshopMutationSuspendedScreenIDs[itemID]?.contains(screen.id) != true)

            Self.post(.workshopItemDidMutate, itemID)
        }
    }

    @Test("An item whose Steam folder id differs from its manifest id is suspended when that folder is rewritten")
    func steamFolderIDIsMatched() async throws {
        let manifestID = Self.uniqueID()
        let folderID = Self.uniqueID()
        let origin = try origin(manifestID, source: steamFolder(folderID))
        await withScreen(playing: origin) { manager, screen in
            screen.installRuntimeSession(GateFakeRuntimeSession())

            Self.post(.workshopItemWillMutate, folderID)

            #expect(screen.runtimeSession == nil)
            #expect(manager.workshopMutationSuspendedScreenIDs[folderID]?.contains(screen.id) == true)

            Self.post(.workshopItemDidMutate, folderID)

            #expect(manager.wallpaperLoads.attempt(for: screen) != nil)
        }
    }

    @Test(
        "An automatic video switch to an item being rewritten builds no player, saves the switch, and reloads after",
        .timeLimit(.minutes(1))
    )
    func videoSwitchDuringMutationIsDeferred() async throws {
        let itemID = Self.uniqueID()
        let video = try steamFolder(itemID).appendingPathComponent("video.mp4")
        try Data([0x00]).write(to: video)
        let bookmark = try #require(ResourceUtilities.createBookmark(for: video))
        let origin = try origin(itemID, type: .video)
        await withScreen { manager, screen in
            var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmark)
            configuration.wpeOrigin = origin
            Self.post(.workshopItemWillMutate, itemID)

            var result: WallpaperPreparationResult?
            manager.playbackCoordinator.setupVideoPlayback(
                url: video, screen: screen, proposedConfiguration: configuration, completion: { result = $0 }
            )

            #expect(result == .ready, "a player was built for a file SteamCMD is rewriting")
            #expect(screen.runtimeSession == nil)
            #expect(manager.configurationStore.get(for: screen.id)?.wpeOrigin == origin)
            #expect(manager.workshopMutationSuspendedScreenIDs[itemID]?.contains(screen.id) == true)

            let parked = manager.bumpTransition(for: screen.id)
            Self.post(.workshopItemDidMutate, itemID)

            #expect(!manager.isCurrentTransition(parked, for: screen.id), "the parked video was not reloaded")
        }
    }

    @Test(
        "A scene still preparing when its item starts rewriting is cancelled and prepared again after the rewrite",
        .timeLimit(.minutes(1))
    )
    func preparingCandidateIsCancelledAndRetried() async throws {
        let itemID = Self.uniqueID()
        let origin = try origin(itemID)
        await withScreen { manager, screen in
            let attemptID = manager.wallpaperLoads.begin(for: screen, title: itemID, origin: origin)
            manager.wallpaperLoads.update(attemptID, for: screen) {
                $0.configuration = Self.sceneConfiguration(origin, for: screen.id)
                $0.phase = .preparing
            }
            let candidate = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
            let work = RuntimePreparationWork()
            work.task = candidate
            _ = manager.transitionRegistry.setRuntimePreparation(work, for: screen.id)

            Self.post(.workshopItemWillMutate, itemID)

            #expect(candidate.isCancelled)
            #expect(manager.configurationStore.get(for: screen.id) == nil)
            #expect(manager.workshopMutationSuspendedScreenIDs[itemID]?.contains(screen.id) == true)

            Self.post(.workshopItemDidMutate, itemID)

            let retried = manager.wallpaperLoads.attempt(for: screen)
            #expect(retried?.id != attemptID)
            #expect(retried?.origin?.workshopID == itemID)
        }
    }
}

private final class GateFakeRuntimeSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene

    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(wallpaperType: .scene, activity: .active, supportsPlaybackControl: false, subtitle: nil)
    }

    var videoPlayer: WallpaperVideoPlayer? {
        nil
    }

    var wallpaperWindow: NSWindow? {
        nil
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func cleanup() {}
}
#endif
