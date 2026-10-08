#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("ScreenManager scene span groups", .serialized, .timeLimit(.minutes(1)))
struct ScreenManagerSceneSpanTests {
    private static func makeDescriptor() -> SceneDescriptor {
        SceneDescriptor(workshopID: "span-manager-\(UUID().uuidString)", cacheRelativePath: "wpe-cache/span-manager-\(UUID().uuidString)",
                        entryFile: "scene.json", capabilityTier: .imageOnly)
    }

    private static func withManager(seeding configurations: [ScreenConfiguration] = [],
                                    _ body: (ScreenManager, Screen) throws -> Void) throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let original = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(original) }
        SettingsManager.shared.replaceAllConfigurations(configurations)
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        try body(manager, screen)
    }

    @Test("A scene edit reaches the stored configuration of a disconnected span member")
    func descriptorEditReachesOfflineMember() throws {
        let original = Self.makeDescriptor()
        let edited = original.withPropertyOverrides(["enabled": .bool(false)])
        let id = UUID()
        let offlineID: CGDirectDisplayID = 0x5EED_0FF1
        var offline = ScreenConfiguration(screenID: offlineID, wallpaper: .scene(original))
        offline.sceneSpanGroupID = id
        var unrelated = ScreenConfiguration(screenID: offlineID &+ 1, wallpaper: .scene(original))
        unrelated.sceneSpanGroupID = UUID()
        try Self.withManager(seeding: [offline, unrelated]) { manager, screen in
            manager.persistSceneSpanDescriptor(edited, groupID: id, excluding: screen.id)

            let stored = manager.configurationStore.loadAll()
            #expect(stored.first { $0.screenID == offlineID }?.activeWallpaper == .scene(edited))
            #expect(stored.first { $0.screenID == offlineID }?.savedSceneDescriptor == edited)
            #expect(stored.first { $0.screenID == offlineID &+ 1 }?.activeWallpaper == .scene(original))
        }
    }

    @Test("A scene edit reaches the schedule entry of another span member")
    func descriptorEditReachesMemberSchedule() throws {
        let original = Self.makeDescriptor()
        let edited = original.withPropertyOverrides(["enabled": .bool(false)])
        let id = UUID()
        let memberID: CGDirectDisplayID = 0x5EED_0FF3
        var member = ScreenConfiguration(screenID: memberID, wallpaper: .scene(original))
        member.sceneSpanGroupID = id
        member.wallpaperMode = .schedule
        member.scheduleFallback = WallpaperQueueEntry(title: "", content: .scene(original))
        try Self.withManager(seeding: [member]) { manager, screen in
            manager.persistSceneSpanDescriptor(edited, groupID: id, excluding: screen.id)

            let stored = manager.configurationStore.loadAll().first { $0.screenID == memberID }
            #expect(stored?.scheduleFallback?.content == .scene(edited), "the next run of the plan would bring the old values back")
        }
    }
}
#endif
