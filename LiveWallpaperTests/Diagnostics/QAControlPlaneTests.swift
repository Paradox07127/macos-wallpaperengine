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
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xEDFA_0099)]
    }

    override var localizedName: String {
        "QA identity test"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}
#endif
