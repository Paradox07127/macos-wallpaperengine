#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Workshop shared-repository mutation gate")
struct WorkshopMutationGateTests {
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

    private static func uniqueID() -> String {
        "gate-\(UUID().uuidString)"
    }

    private static func descriptor(_ workshopID: String) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: "wpe-cache/\(workshopID)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
    }

    private static func origin(_ workshopID: String, dependencies: [String] = []) -> WPEOrigin {
        WPEOrigin(
            workshopID: workshopID,
            title: workshopID,
            originalType: .scene,
            sourceFolderBookmark: Data(),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: nil,
            dependencyWorkshopIDs: dependencies
        )
    }

    private static func sceneConfiguration(
        _ workshopID: String,
        dependencies: [String] = [],
        for screenID: CGDirectDisplayID
    ) -> ScreenConfiguration {
        var configuration = ScreenConfiguration(screenID: screenID, wallpaper: .scene(descriptor(workshopID)))
        configuration.wpeOrigin = origin(workshopID, dependencies: dependencies)
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

    private func withScreen(
        configuration: ((CGDirectDisplayID) -> ScreenConfiguration)?,
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
        }
        SettingsManager.shared.replaceAllConfigurations(configuration.map { [$0(screen.id)] } ?? [])
        let manager = makeManager()
        manager.screens = [screen]
        try await body(manager, screen)
        await Self.drainMainQueue()
    }

    @Test("Applying an item while it is being rewritten saves it, builds no session, and reloads after the rewrite")
    func applyDuringMutationIsDeferredUntilDidMutate() async {
        let itemID = Self.uniqueID()
        await withScreen(configuration: nil) { manager, screen in
            Self.post(.workshopItemWillMutate, itemID)

            manager.setSceneWallpaper(descriptor: Self.descriptor(itemID), origin: Self.origin(itemID), for: screen)

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
    func dependentSceneIsSuspendedAndReloaded() async {
        let dependencyID = Self.uniqueID()
        let sceneID = Self.uniqueID()
        let configuration: (CGDirectDisplayID) -> ScreenConfiguration = {
            Self.sceneConfiguration(sceneID, dependencies: [dependencyID], for: $0)
        }
        await withScreen(configuration: configuration) { manager, screen in
            screen.installRuntimeSession(GateFakeRuntimeSession())

            Self.post(.workshopItemWillMutate, dependencyID)

            #expect(screen.runtimeSession == nil)
            #expect(manager.workshopMutationSuspendedScreenIDs[dependencyID]?.contains(screen.id) == true)

            Self.post(.workshopItemDidMutate, dependencyID)

            #expect(manager.wallpaperLoads.attempt(for: screen) != nil)
        }
    }

    @Test("A display switched to another wallpaper during the rewrite is not switched back")
    func switchAwayDuringMutationIsKept() async {
        let itemID = Self.uniqueID()
        await withScreen(configuration: nil) { manager, screen in
            Self.post(.workshopItemWillMutate, itemID)
            manager.setSceneWallpaper(descriptor: Self.descriptor(itemID), origin: Self.origin(itemID), for: screen)

            let replacement = ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([0xC0, 0xDE])))
            manager.saveConfiguration(replacement)

            Self.post(.workshopItemDidMutate, itemID)

            #expect(manager.wallpaperLoads.attempt(for: screen) == nil)
            #expect(manager.configurationStore.get(for: screen.id)?.activeWallpaper == replacement.activeWallpaper)
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
