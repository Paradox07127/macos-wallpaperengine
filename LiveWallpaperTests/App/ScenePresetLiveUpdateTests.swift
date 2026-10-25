#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
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

    /// Runs `body` with a patchable scene session showing a preset layered over keys `a` and `b`.
    private static func withPatchableScene(
        _ body: (ScreenManager, Screen, PresetPatchRecordingSceneSession, String) async throws -> Void
    ) async throws {
        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer { SettingsManager.shared.cleanAllSettings(applyLoginSetting: false) }
        let presetID = "preset-live-\(UUID().uuidString)"
        let original = preset(id: presetID, values: ["a": .number(0), "b": .number(0)])
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
        let session = PresetPatchRecordingSceneSession(rendered: original.values)
        screen.installRuntimeSession(session)
        var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(showing))
        configuration.displayFingerprint = screen.displayFingerprint
        manager.saveConfiguration(configuration)
        try await body(manager, screen, session, presetID)
    }

    private static func storedScene(_ manager: ScreenManager, _ screen: Screen) -> SceneDescriptor? {
        guard case let .scene(descriptor)? = manager.getConfiguration(for: screen)?.activeWallpaper else { return nil }
        return descriptor
    }

    @Test("Two preset edits in a row both reach a scene whose first patch is still being prepared")
    func backToBackEditsBothReachScene() async throws {
        try await Self.withPatchableScene { manager, screen, session, presetID in
            session.holdsFirstPrepare = true
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["a": .number(1), "b": .number(0)]))
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["a": .number(1), "b": .number(1)]))
            await Self.settle { session.heldPrepare != nil }
            await Self.settle { !session.committed.isEmpty }
            session.releaseHeldPrepare()
            let expected: [String: WallpaperEngineProjectPropertyValue] = ["a": .number(1), "b": .number(1)]
            await Self.settle { session.rendered == expected }

            #expect(Self.storedScene(manager, screen)?.presetSnapshot == expected)
            #expect(session.rendered == expected, "the renderer kept a value the saved configuration no longer has")
        }
    }

    @Test("A preset edit made while the previous edit's patch is still being prepared reaches the scene")
    func editDuringPreparedPatchReachesScene() async throws {
        try await Self.withPatchableScene { manager, screen, session, presetID in
            session.holdsFirstPrepare = true
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["a": .number(1), "b": .number(0)]))
            await Self.settle { session.heldPrepare != nil }
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["a": .number(1), "b": .number(1)]))
            await Self.settle { !session.committed.isEmpty }
            session.releaseHeldPrepare()
            let expected: [String: WallpaperEngineProjectPropertyValue] = ["a": .number(1), "b": .number(1)]
            await Self.settle { session.rendered == expected }

            #expect(Self.storedScene(manager, screen)?.presetSnapshot == expected)
            #expect(session.rendered == expected, "the renderer kept a value the saved configuration no longer has")
        }
    }

    @Test("Reverting a preset while its first patch finishes also reverts the rendered value")
    func revertDuringCommitReachesScene() async throws {
        try await Self.withPatchableScene { manager, screen, session, presetID in
            session.holdsFirstCommit = true
            defer { session.releaseHeldCommit() }
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["a": .number(1), "b": .number(0)]))
            await Self.settle { session.heldCommit != nil }
            try #require(session.heldCommit != nil)
            let expected: [String: WallpaperEngineProjectPropertyValue] = ["a": .number(0), "b": .number(0)]
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: expected))
            session.releaseHeldCommit()
            await Self.settle { session.rendered == expected }
            #expect(session.rendered == expected)
            #expect(Self.storedScene(manager, screen)?.presetSnapshot == expected)
        }
    }

    @Test("A queued preset update yields to a newer explicit wallpaper selection")
    func queuedEditYieldsToNewSelection() async throws {
        try await Self.withPatchableScene { manager, screen, session, presetID in
            session.holdsFirstPrepare = true
            defer { session.releaseHeldPrepare() }
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["a": .number(1), "b": .number(0)]))
            await Self.settle { session.heldPrepare != nil }
            try #require(session.heldPrepare != nil)
            await SettingsManager.shared.registerScenePreset(Self.preset(id: presetID, values: ["a": .number(1), "b": .number(1)]))
            let selection = manager.beginExplicitWallpaperSelection(for: screen)
            session.releaseHeldPrepare()
            await Self.settle { manager.scenePresetUpdateTasks[screen.id] == nil }
            let keptSelection = manager.isCurrentTransition(selection, for: screen.id)
            #expect(keptSelection)
            #expect(session.committed.isEmpty)
        }
    }
}

/// Applies each committed patch's changed keys to `rendered`, the way a live renderer would.
@MainActor
private final class PresetPatchRecordingSceneSession: SceneWallpaperRuntime {
    private(set) var rendered: [String: WallpaperEngineProjectPropertyValue]
    private(set) var committed: [WPEScenePropertyPatch] = []
    var holdsFirstPrepare = false
    private(set) var heldPrepare: CheckedContinuation<Void, Never>?
    var holdsFirstCommit = false
    private(set) var heldCommit: CheckedContinuation<Void, Never>?
    private let mutationAuthority = ScenePropertyMutationAuthority()
    private let posterGate = ScenePropertyPosterCommitGate()

    init(rendered: [String: WallpaperEngineProjectPropertyValue]) {
        self.rendered = rendered
    }

    func releaseHeldPrepare() {
        heldPrepare?.resume()
        heldPrepare = nil
    }

    func releaseHeldCommit() {
        heldCommit?.resume()
        heldCommit = nil
    }

    let wallpaperType = WallpaperType.scene
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    let isPlaying = true
    var playbackMachine = WallpaperPlaybackStateMachine()
    let loadFailureCause: WallpaperFailureCause? = nil
    let loadError: SceneRenderingError? = nil
    let loadProgress: String? = nil
    let hasPresentedFrame: Bool? = true
    let rendererDiagnostics: SceneRendererDiagnostics? = nil
    let rendererRuntimeActivity: WPESceneRuntimeActivity? = nil
    let mayPerformRuntimeWork = true
    let isHibernated = false
    var onRuntimeErrorChange: (@MainActor () -> Void)?
    var onRuntimeActivityChange: (@MainActor () -> Void)?
    let frameRateController: (any WallpaperFrameRateConfigurable)? = nil
    let audioController: (any WallpaperAudioConfigurable)? = nil

    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(wallpaperType: .scene, activity: .active, supportsPlaybackControl: true, subtitle: nil)
    }

    var userIntendsToPlay: Bool {
        playbackMachine.userIntendsToPlay
    }

    func show() {}

    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}

    func updateFrame(to _: CGRect) {}

    func cleanup() {}

    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func play() {}

    func pause() {}

    func setCriticalMemoryPressureActive(_: Bool) {}

    func pollRendererState() async {}

    func captureLivePosterFromNextFrame() async -> NSImage? {
        nil
    }

    func setHibernationEligible(_: Bool) {}

    func setMouseInteractionEnabled(_: Bool) {}

    func setClickCaptureEnabled(_: Bool) {}

    func setSceneFitMode(_: VideoFitMode) {}

    func scenePropertyBindings() async -> [String: [WPEScenePropertyBinding]] {
        Dictionary(uniqueKeysWithValues: ["a", "b"].map { key in
            (key, [WPEScenePropertyBinding(propertyKey: key, target: .generalField(name: key), kind: .general, action: .incremental)])
        })
    }

    @discardableResult func advanceScenePropertyMutationIntent() -> ScenePropertyMutationToken {
        mutationAuthority.advance()
    }

    func currentScenePropertyMutationToken() -> ScenePropertyMutationToken {
        mutationAuthority.currentToken()
    }

    func isCurrentScenePropertyMutationIntent(_ token: ScenePropertyMutationToken) -> Bool {
        mutationAuthority.isCurrent(token)
    }

    func prepareScenePropertyPatch(
        _ patch: WPEScenePropertyPatch,
        expectedIntent _: ScenePropertyMutationToken
    ) async -> PreparedScenePropertyPatch? {
        if holdsFirstPrepare {
            holdsFirstPrepare = false
            await withCheckedContinuation { heldPrepare = $0 }
        }
        return PreparedScenePropertyPatch(patch: patch, rendererGeneration: 0)
    }

    func stageScenePropertyPosterCommit(overrides: [String: WallpaperEngineProjectPropertyValue]) -> ScenePropertyPosterCommit {
        posterGate.stage(overrides: overrides)
    }

    func commitScenePropertyPatch(
        _ prepared: PreparedScenePropertyPatch,
        posterCommit _: ScenePropertyPosterCommit,
        updatedDescriptor _: SceneDescriptor
    ) async -> Bool {
        committed.append(prepared.patch)
        for key in prepared.patch.changedKeys {
            rendered[key] = prepared.patch.newValues[key]
        }
        if holdsFirstCommit {
            holdsFirstCommit = false
            await withCheckedContinuation { heldCommit = $0 }
        }
        return true
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
