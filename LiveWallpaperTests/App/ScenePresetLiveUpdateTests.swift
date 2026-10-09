#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("A preset library change reaches the scene showing that preset", .serialized, .timeLimit(.minutes(1)))
struct ScenePresetLiveUpdateTests {
    private static let baseWorkshopID = "preset-live-scene"

    private static func preset(id: String, values: [String: WallpaperEngineProjectPropertyValue]) -> ScenePreset {
        .local(name: "Night", baseWorkshopID: baseWorkshopID, values: values, id: id)
    }

    /// Runs `body` with the test display showing a scene layered with a preset whose id is passed in.
    private static func withShowingPreset(_ body: (ScreenManager, Screen, String) async throws -> Void) async throws {
        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer { SettingsManager.shared.cleanAllSettings(applyLoginSetting: false) }
        let presetID = "preset-live-\(UUID().uuidString)"
        let original = preset(id: presetID, values: ["tint": .number(1)])
        await SettingsManager.shared.registerScenePreset(original)
        let showing = SceneDescriptor(
            workshopID: baseWorkshopID, cacheRelativePath: "wpe-cache/\(baseWorkshopID)",
            entryFile: "scene.json", capabilityTier: .imageOnly
        ).withPresetLayer(id: presetID, snapshot: original.values)

        let screen = Screen(nsScreen: PresetLiveUpdateTestNSScreen())
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
        var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(showing))
        configuration.displayFingerprint = screen.displayFingerprint
        manager.saveConfiguration(configuration)
        try await body(manager, screen, presetID)
    }

    /// The descriptor the manager handed to the display's scene after the library change, if any.
    private static func handedScene(_ manager: ScreenManager, _ screen: Screen) -> SceneDescriptor? {
        guard case let .scene(descriptor)? = manager.wallpaperLoads.attempt(for: screen)?.configuration?.activeWallpaper else {
            return nil
        }
        return descriptor
    }

    private static func settle(until done: () -> Bool) async {
        for _ in 0 ..< 500 where !done() {
            await Task.yield()
        }
    }

    @Test("Updating the preset's values hands the showing scene the new values")
    func updatedValuesReachShowingScene() async throws {
        try await Self.withShowingPreset { manager, screen, presetID in
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["tint": .number(2)]))
            await Self.settle { Self.handedScene(manager, screen) != nil }

            guard let handed = Self.handedScene(manager, screen) else {
                Issue.record("the showing scene was never handed the updated preset")
                return
            }
            #expect(handed.presetID == presetID)
            #expect(handed.presetSnapshot == ["tint": .number(2)])
        }
    }

    @Test("Deleting the preset hands the showing scene the descriptor without it")
    func deletionReachesShowingScene() async throws {
        try await Self.withShowingPreset { manager, screen, presetID in
            SettingsManager.shared.removeScenePreset(id: presetID)
            await Self.settle { Self.handedScene(manager, screen) != nil }

            guard let handed = Self.handedScene(manager, screen) else {
                Issue.record("the showing scene kept the deleted preset")
                return
            }
            #expect(handed.presetID == nil)
            #expect(handed.presetSnapshot.isEmpty)
        }
    }
}

private final class PresetLiveUpdateTestNSScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0x9E5E_7A11)]
    }

    override var localizedName: String {
        "Scene Preset Live Update Test"
    }
}
#endif
