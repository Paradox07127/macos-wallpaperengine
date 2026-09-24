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

    @Test("A preset change and a reset report the descriptors around them once they have landed; an attempt's owner reports nothing", .timeLimit(.minutes(1)))
    func landedChangesReportBeforeAndAfter() async throws {
        let harness = try Harness(displayID: 0xED33_0003)
        defer { harness.close() }
        var reports: [(action: EditDeskUndoStack.Action, before: SceneDescriptor, after: SceneDescriptor)] = []
        let owner = try harness.appliedOwner { action, before, after, _ in
            #expect(harness.applied == .scene(after), "reported before the change landed")
            reports.append((action, before, after))
        }
        owner.applyPreset(nil)
        await Self.waitUntil { reports.count == 1 }
        #expect(reports.first?.action == .changePreset)
        #expect(reports.first?.before.propertyOverrides["gain"] == .number(0.5))
        #expect(reports.first?.after.propertyOverrides.isEmpty == true)

        let gain = try #require(owner.editor.presentation?.sections[1].properties.first)
        owner.setValue(.number(0.75), for: gain, commit: .immediate)
        await Self.waitUntil { harness.applied?.sceneDescriptor?.propertyOverrides["gain"] == .number(0.75) }
        owner.resetOverrides()
        await Self.waitUntil { reports.count == 2 }
        #expect(reports.map(\.action) == [.changePreset, .resetSceneSettings], "a slider edit is not a step")
        #expect(reports.last?.before.propertyOverrides["gain"] == .number(0.75))
        #expect(reports.last?.after.propertyOverrides.isEmpty == true)

        var attemptReports = 0
        let attempt = try Harness(displayID: 0xED33_0004) { _, _, _, _ in attemptReports += 1 }
        attempt.owner.setValue(.number(0.75), for: gain, commit: .immediate)
        await Self.waitUntil { attempt.attemptOverrides["gain"] == .number(0.75) }
        attempt.owner.resetOverrides()
        await Self.waitUntil { attempt.attemptOverrides.isEmpty }
        #expect(attemptReports == 0)
    }

    @Test("Undo lands the pending edit of the display's current owner, not of the released one that recorded the step", .timeLimit(.minutes(1)))
    func undoFlushesTheCurrentOwner() async throws {
        let harness = try Harness(displayID: 0xED33_0005)
        defer { harness.close() }
        let bookmarks = BookmarkStore(persistence: DeferredBookmarkPersistence())
        let undo = EditDeskUndoStack(
            manager: harness.manager,
            router: ApplyRouter(manager: harness.manager, bookmarks: bookmarks, sceneCapable: true),
            bookmarks: bookmarks
        )
        let record: SceneSettingsOwner.UndoableChange = { action, before, _, flush in
            undo.recordSceneChange(action, from: before, on: harness.screen, flush: flush)
        }
        var recorder: SceneSettingsOwner? = try harness.appliedOwner(onUndoableChange: record)
        let before = try #require(harness.applied?.sceneDescriptor)
        recorder?.applyPreset(nil)
        await Self.waitUntil { undo.undoSteps.count == 1 }
        // Switching the detail page to Overlay and back rebuilds the settings panel around a new owner.
        recorder = nil
        let after = try #require(harness.applied?.sceneDescriptor)
        let current = try SceneSettingsOwner(
            screen: harness.screen, screenManager: harness.manager, descriptor: after,
            schema: Self.schema(), onUndoableChange: record
        )
        let gain = try #require(current.editor.presentation?.sections[1].properties.first)
        current.setValue(.number(0.9), for: gain, commit: .coalesced)
        let debounce = try #require(current.commitTask)

        _ = try #require(await undo.undo())
        // What the panel does when the display's descriptor changes under it.
        try current.synchronize(descriptor: #require(harness.applied?.sceneDescriptor))
        await debounce.value
        #expect(harness.applied == .scene(before), "the pending slider commit landed over the undo")
        #expect(current.editor.overrides == before.propertyOverrides)
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
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

        init(displayID: UInt32 = 0xED33_0001, onUndoableChange: SceneSettingsOwner.UndoableChange? = nil) throws {
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
                schema: SceneSettingsOwnerTests.schema(), attemptID: attemptID, onUndoableChange: onUndoableChange
            )
        }

        /// What the display runs.
        var applied: WallpaperContent? {
            manager.getConfiguration(for: screen)?.activeWallpaper
        }

        var attemptOverrides: [String: WallpaperEngineProjectPropertyValue] {
            manager.wallpaperLoads.attempt(for: screen)?.configuration?.activeWallpaper.sceneDescriptor?.propertyOverrides ?? [:]
        }

        /// An owner of the wallpaper the display runs, whose commits land at once: wallpapers are off, so no session is built.
        func appliedOwner(onUndoableChange: @escaping SceneSettingsOwner.UndoableChange) throws -> SceneSettingsOwner {
            let descriptor = SceneDescriptor(
                workshopID: "probe", cacheRelativePath: "probe", entryFile: "scene.json", capabilityTier: .imageOnly
            ).withPropertyOverrides(["gain": .number(0.5)])
            var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
            configuration.displayFingerprint = screen.displayFingerprint
            manager.configurationStore.save(configuration)
            manager.wallpapersGloballyEnabled = false
            return try SceneSettingsOwner(
                screen: screen, screenManager: manager, descriptor: descriptor,
                schema: SceneSettingsOwnerTests.schema(), onUndoableChange: onUndoableChange
            )
        }

        func close() {
            manager.tearDownForTermination()
            manager.configurationStore.remove(for: screen.id)
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
