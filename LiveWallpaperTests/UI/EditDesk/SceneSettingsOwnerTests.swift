#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Scene settings owner")
struct SceneSettingsOwnerTests {
    @Test("Filtering preserves the editor, values, expansion and pending task")
    func searchDoesNotReloadEditor() throws {
        let harness = try Harness()
        let owner = try #require(harness.owner)
        owner.editor.toggleSection("effects")
        let property = try #require(owner.editor.presentation?.sections[1].properties.first)
        owner.setValue(.number(0.75), for: property, commit: .coalesced)
        let editor = owner.editor
        let task = try #require(owner.commitTask)
        let values = editor.overrides
        let rows = editor.rows
        let expanded = editor.expandedSections
        owner.query = "gain"
        #expect(owner.editor === editor)
        #expect(owner.commitTask == task)
        #expect(editor.overrides == values && editor.rows == rows && editor.expandedSections == expanded)
        owner.cancelPendingCommit()
    }

    @Test("A scheduled commit lands on its original display after filtering and releasing the owner")
    func commitSurvivesQueryAndDisplayChange() async throws {
        let harness = try Harness()
        var owner: SceneSettingsOwner? = harness.owner
        harness.owner = nil
        let editor = try #require(owner?.editor)
        let property = try #require(editor.presentation?.sections[1].properties.first)
        owner?.setValue(.number(0.75), for: property, commit: .coalesced)
        let task = try #require(owner?.commitTask)
        owner?.query = "no matching settings"
        let other = try Harness(displayID: 0xED33_0002)
        owner = nil
        await task.value
        let attempt = try #require(harness.manager.wallpaperLoads.attempt(for: harness.screen))
        guard case let .scene(descriptor) = attempt.configuration?.activeWallpaper else {
            Issue.record("The commit must retain the scene attempt")
            return
        }
        #expect(descriptor.propertyOverrides["gain"] == .number(0.75))
        #expect(other.owner.editor.overrides.isEmpty)
    }

    private static func schema() throws -> WallpaperEngineProjectPropertySchema {
        let json = #"{"general":{"properties":{"layers":{"type":"group","text":"Layers","order":0},"stars":{"type":"bool","text":"Stars","value":true,"order":1},"clouds":{"type":"bool","text":"Clouds","value":true,"order":2},"effects":{"type":"group","text":"Effects","order":3},"gain":{"type":"slider","text":"Gain","value":0,"min":0,"max":1,"order":4},"colors":{"type":"group","text":"Colors","order":5},"tint":{"type":"color","text":"Tint","value":"1 1 1","order":6}}}}"#
        return try WallpaperEngineProjectPropertySchema.parse(data: Data(json.utf8))
    }

    @MainActor
    private final class Harness {
        let screen: Screen
        let manager: ScreenManager
        var owner: SceneSettingsOwner!

        init(displayID: UInt32 = 0xED33_0001) throws {
            screen = Screen(nsScreen: SceneSettingsTestScreen(displayID: displayID))
            manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
                featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
            ))
            let descriptor = SceneDescriptor(
                workshopID: "probe", cacheRelativePath: "probe", entryFile: "scene.json", capabilityTier: .imageOnly
            )
            let attemptID = manager.wallpaperLoads.begin(for: screen, title: "Probe")
            manager.wallpaperLoads.update(attemptID, for: screen) {
                $0.configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
            }
            owner = try SceneSettingsOwner(
                screen: screen, screenManager: manager, descriptor: descriptor,
                schema: SceneSettingsOwnerTests.schema(), attemptID: attemptID
            )
        }
    }
}

private final class SceneSettingsTestScreen: NSScreen {
    let displayID: UInt32

    init(displayID: UInt32) {
        self.displayID = displayID
        super.init()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Scene settings test"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}
#endif
