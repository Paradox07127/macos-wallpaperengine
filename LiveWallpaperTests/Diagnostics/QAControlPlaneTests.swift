#if DEBUG
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("QA control plane defaults tool", .serialized)
@MainActor
struct QAControlPlaneDefaultsTests {
    private func call(_ tool: String, _ arguments: String) async -> [String: Any] {
        let line = #"{"tool":"\#(tool)","arguments":\#(arguments)}"#
        let response = await QAControlPlane.shared.respond(to: line)
        return (try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]) ?? [:]
    }

    /// `UserDefaults.set(NSNull())` raises an ObjC exception; a JSON null has to mean "remove".
    @Test("A null value removes the key instead of crashing the app")
    func nullRemovesKey() async {
        let key = "loomscreen.qa.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let set = await call("defaults.set", #"{"key":"\#(key)","value":1}"#)
        #expect(set["ok"] as? Bool == true)
        #expect(UserDefaults.standard.integer(forKey: key) == 1)

        let cleared = await call("defaults.set", #"{"key":"\#(key)","value":null}"#)
        #expect(cleared["ok"] as? Bool == true)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(await call("defaults.get", #"{"key":"\#(key)"}"#)["ok"] as? Bool == true)
    }

    @Test("A non-property-list value is refused, not written")
    func nonPropertyListIsRefused() async {
        let key = "loomscreen.qa.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let refused = await call("defaults.set", #"{"key":"\#(key)","value":{"nested":null}}"#)
        #expect(refused["ok"] as? Bool == false)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}

@Suite("QA control plane screen identity", .serialized)
@MainActor
struct QAControlPlaneScreenIdentityTests {
    @Test("Explicit playback repeats preserve intent instead of toggling")
    func explicitPlaybackIsIdempotent() async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        let arguments = #"{"screenID":\#(fixture.screen.id),"playing":false}"#
        for _ in 0 ..< 2 {
            #expect(try await fixture.call("playback.set", arguments: arguments)["ok"] as? Bool == true)
        }
        #expect(!fixture.session.userIntendsToPlay)
        #expect(fixture.session.toggleCount == 1)
        let play = #"{"screenID":\#(fixture.screen.id),"playing":true}"#
        for _ in 0 ..< 2 {
            _ = try await fixture.call("playback.set", arguments: play)
        }
        #expect(fixture.session.userIntendsToPlay)
        #expect(fixture.session.toggleCount == 2)
        #expect(try await fixture.call("playback.set", arguments: #"{"screenID":\#(fixture.screen.id),"playing":1}"#)["ok"] as? Bool == false)
        #expect(fixture.session.toggleCount == 2)
    }

    @Test("Malformed JSON screen identities cannot toggle a real target or change its revision")
    func invalidIdentitiesDoNotReachPlayback() async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        let id = UInt64(fixture.screen.id)
        let invalid = [String(id + (1 << 32)), String(Int64(id) - (1 << 32)),
                       "\(id).5", "true", "false", "\"\(id)\"", "null", "1e400"]
        let revision = fixture.manager.configurationStore.revision(for: fixture.screen.id)
        for value in invalid {
            let result = try await fixture.call("wallpaper.togglePlayback", arguments: #"{"screenID":\#(value)}"#)
            #expect(result["ok"] as? Bool == false, "accepted invalid screenID: \(value)")
            #expect(fixture.session.toggleCount == 0, "invalid identity reached the playback setter")
            #expect(fixture.manager.configurationStore.revision(for: fixture.screen.id) == revision)
        }
    }

    @Test("Non-finite NSNumber inputs are refused by the same product resolver")
    func nonFiniteValuesAreRejected() {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        for value in [Double.infinity, -.infinity, .nan] {
            do {
                _ = try fixture.control.wallpaperTogglePlayback(["screenID": NSNumber(value: value)])
                Issue.record("Accepted non-finite screen identity")
            } catch {
                #expect(String(describing: error).contains("Rejected screenID"))
            }
            #expect(fixture.session.toggleCount == 0)
        }
    }

    @Test("A legal ID still reaches the same target through JSON routing")
    func validIdentityReachesPlayback() async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        let result = try await fixture.call("wallpaper.togglePlayback", arguments: #"{"screenID":\#(fixture.screen.id)}"#)
        #expect(result["ok"] as? Bool == true)
        #expect(fixture.session.toggleCount == 1)
        #expect(!fixture.session.userIntendsToPlay)
        let read = try await fixture.call("runtime.state", arguments: #"{"screenID":\#(fixture.screen.id)}"#)
        #expect(read["ok"] as? Bool == true)
    }

    @MainActor
    private struct Fixture {
        let screen = Screen(nsScreen: QATestScreen())
        let session = QAPlaybackSession()
        let manager: ScreenManager
        let control: QAControlPlane

        init() {
            manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
                featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
            ))
            screen.installRuntimeSession(session)
            control = QAControlPlane(screenManager: manager)
        }

        func call(_ tool: String, arguments: String) async throws -> [String: Any] {
            let response = await control.respond(to: #"{"tool":"\#(tool)","arguments":\#(arguments)}"#)
            return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        }
    }
}

@Suite("QA control plane active wallpaper window", .serialized)
@MainActor
struct QAControlPlaneWindowObservationTests {
    @Test("A video candidate is not observed until committed, for file and package sources",
          arguments: [false, true])
    func videoWindowRequiresCommittedSession(packaged: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        let player = fixture.makePlayer(packaged: packaged)
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }
        let window = VideoWallpaperWindow(frame: fixture.screen.frame)
        player.installPlaybackWindowForTesting(window)

        try await fixture.expectWindow(nil)
        fixture.screen.installRuntimeSession(session)
        try await fixture.expectWindow(window)
        #expect(session.wallpaperWindow == nil)
        #expect(fixture.screen.activeWallpaperWindow == nil, "QA must not change the non-video UI contract")

        session.setTransitionHold(true)
        try await fixture.expectWindow(window)
        session.setTransitionHold(false)
        try await fixture.expectWindow(window)
    }

    @Test("An installed video without a playback window remains unobservable, then clears after cleanup")
    func videoWindowTracksPlayerLifecycle() async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        let player = fixture.makePlayer()
        let session = VideoWallpaperSession(player: player)
        fixture.screen.installRuntimeSession(session)
        try await fixture.expectWindow(nil)

        let window = VideoWallpaperWindow(frame: fixture.screen.frame)
        player.installPlaybackWindowForTesting(window)
        try await fixture.expectWindow(window)
        session.cleanup()
        try await fixture.expectWindow(nil)
        #expect(player.playbackWindow == nil)
        #expect(fixture.screen.runtimeSession === session)
    }

    @Test("A retiring video window is never reported as the new session's active window")
    func retiringWindowDoesNotMaskMissingIncomingWindow() async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        fixture.screen.transitionEnvironment.reduceMotion = { false }
        fixture.screen.transitionEnvironment.lowPowerMode = { false }
        fixture.screen.transitionEnvironment.plan = { _, _ in .crossfade }
        let oldPlayer = fixture.makePlayer()
        let oldWindow = VideoWallpaperWindow(frame: fixture.screen.frame)
        oldPlayer.installPlaybackWindowForTesting(oldWindow)
        let oldSession = VideoWallpaperSession(player: oldPlayer)
        fixture.screen.installRuntimeSession(oldSession)
        try await fixture.expectWindow(oldWindow)

        let currentPlayer = fixture.makePlayer()
        let currentSession = VideoWallpaperSession(player: currentPlayer)
        fixture.screen.installRuntimeSession(currentSession)
        #expect(fixture.screen.retiringSessions[ObjectIdentifier(oldSession)] != nil)
        #expect(oldPlayer.playbackWindow === oldWindow)
        try await fixture.expectWindow(nil)

        let currentWindow = VideoWallpaperWindow(frame: fixture.screen.frame)
        currentPlayer.installPlaybackWindowForTesting(currentWindow)
        try await fixture.expectWindow(currentWindow)
        fixture.screen.resetRuntimeSession()
        try await fixture.expectWindow(nil)
        #expect(oldPlayer.playbackWindow == nil && currentPlayer.playbackWindow == nil)
    }

    @Test("Retry observes a replacement only after successful preparation", arguments: [false, true])
    func retryWindowTracksCurrentPlayer(prepared: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        let oldPlayer = fixture.makePlayer()
        let oldWindow = VideoWallpaperWindow(frame: fixture.screen.frame)
        oldPlayer.installPlaybackWindowForTesting(oldWindow)
        let replacement = fixture.makePlayer()
        let newWindow = VideoWallpaperWindow(frame: fixture.screen.frame)
        replacement.installPlaybackWindowForTesting(newWindow)
        let session = VideoWallpaperSession(
            player: oldPlayer,
            retryPlayerFactory: { _, _, _, _ in replacement },
            retryPreparation: { _ in prepared ? .ready : .failed }
        )
        fixture.screen.installRuntimeSession(session)
        try await fixture.expectWindow(oldWindow)

        await session.retry()
        try await fixture.expectWindow(prepared ? newWindow : oldWindow)
        #expect(oldPlayer.isCleanedUp == prepared)
        #expect(replacement.isCleanedUp == !prepared)
        #expect(fixture.screen.activeWallpaperWindow == nil)
    }

    @Test("Non-video sessions keep their existing active-window observation", arguments: [WallpaperType.html, .scene])
    func nonVideoWindowRemainsObservable(type: WallpaperType) async throws {
        let fixture = Fixture()
        defer { fixture.manager.tearDownForTermination() }
        let window = VideoWallpaperWindow(frame: fixture.screen.frame)
        let session = AmbientWallpaperSession(window: window, wallpaperType: type, performanceTarget: nil)
        fixture.screen.installRuntimeSession(session)
        try await fixture.expectWindow(window)
        #expect(fixture.screen.activeWallpaperWindow === window)
        fixture.screen.resetRuntimeSession()
        try await fixture.expectWindow(nil)
    }

    @MainActor
    private struct Fixture {
        let screen: Screen
        let manager: ScreenManager
        let control: QAControlPlane

        init() {
            let nsScreen = QATestScreen()
            nsScreen.displayID = 0xEDFA_009B
            screen = Screen(nsScreen: nsScreen)
            manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
                featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
            ))
            control = QAControlPlane(screenManager: manager)
        }

        func makePlayer(packaged: Bool = false) -> WallpaperVideoPlayer {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("qa-window-\(UUID().uuidString).\(packaged ? "pkg" : "mp4")")
            return WallpaperVideoPlayer(
                url: url, frame: screen.frame,
                packageEntryName: packaged ? "videos/background.mp4" : nil,
                startsHidden: true, loadImmediately: false
            )
        }

        func expectWindow(_ window: NSWindow?) async throws {
            let response = await control.respond(to: #"{"tool":"state.dump","arguments":{}}"#)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            #expect(envelope["ok"] as? Bool == true)
            let result = try #require(envelope["result"] as? [String: Any])
            let screens = try #require(result["screens"] as? [[String: Any]])
            let entry = try #require(screens.first(where: { ($0["screenID"] as? NSNumber)?.uint32Value == screen.id }))
            #expect(entry["hasActiveWindow"] as? Bool == (window != nil))
            if let window {
                #expect(entry["wallpaperWindowNumber"] as? Int == window.windowNumber)
            } else {
                #expect(entry["wallpaperWindowNumber"] is NSNull)
            }
        }
    }
}

#if !LITE_BUILD
@Suite("QA control plane scene property patch", .serialized)
@MainActor
struct QAControlPlaneScenePatchTests {
    @Test("A patch that rebuilds the scene reports accepted, not applied", .timeLimit(.minutes(1)))
    func rebuildIsAccepted() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-scene-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = #"{"general":{"properties":{"gain":{"type":"slider","text":"Gain","value":0,"min":0,"max":1,"order":0}}}}"#
        try Data(project.utf8).write(to: folder.appendingPathComponent("project.json"))

        let nsScreen = QATestScreen()
        nsScreen.displayID = 0xEDFA_009A
        let screen = Screen(nsScreen: nsScreen)
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
        manager.wallpapersGloballyEnabled = true
        let descriptor = SceneDescriptor(
            workshopID: "qa-scene-patch", cacheRelativePath: "wpe-cache/qa-scene-patch-\(UUID().uuidString)",
            entryFile: "scene.json", capabilityTier: .imageOnly
        )
        var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.wpeOrigin = try WPEOrigin(
            workshopID: "qa-scene-patch", title: "QA patch", originalType: .scene,
            sourceFolderBookmark: #require(ResourceUtilities.createBookmark(for: folder)),
            cacheRelativePath: nil, previewFileName: nil
        )
        manager.saveConfiguration(configuration)

        let control = QAControlPlane(screenManager: manager)
        let response = await control.respond(
            to: #"{"tool":"scene.properties.patch","arguments":{"screenID":\#(screen.id),"values":{"gain":0.5}}}"#
        )
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        #expect(envelope["ok"] as? Bool == true, "\(response)")
        let result = try #require(envelope["result"] as? [String: Any])
        #expect(result["status"] as? String == "accepted")
    }
}
#endif

@MainActor
private final class QAPlaybackSession: WallpaperPlaybackControllable {
    let wallpaperType = WallpaperType.video
    let summary = WallpaperSessionSummary.notConfigured
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    var userIntendsToPlay = true
    var isPlaying: Bool {
        userIntendsToPlay
    }

    private(set) var toggleCount = 0

    func play() {
        userIntendsToPlay = true; toggleCount += 1
    }

    func pause() {
        userIntendsToPlay = false; toggleCount += 1
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func cleanup() {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }
}

private final class QATestScreen: NSScreen {
    var displayID: UInt32 = 0xEDFA_0099

    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "QA identity test"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}
#endif
