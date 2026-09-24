import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Edit Desk display states", .serialized)
struct DisplayStateResolverTests {
    @Test("A failed prepare updates the mounted home without a configuration change", arguments: [true, false])
    func loadFailure(configured: Bool) async {
        let harness = Harness(configured: configured)
        defer { harness.close() }
        let healthy: StageDisplay.State = configured ? .ok : .empty
        await harness.waitUntil { harness.state == healthy }
        let configuration = harness.manager.getConfiguration(for: harness.screen)
        let revision = harness.manager.configurationStore.revision(for: harness.screen.id)
        let loads = harness.manager.wallpaperLoads
        let id = loads.begin(for: harness.screen, title: "Broken scene")
        let cause = WallpaperFailureCause.runtime(.wallpaperPreparationFailed(type: .scene, timedOut: false))
        loads.update(id, for: harness.screen) {
            $0.phase = .failed
            $0.failure = WallpaperFailureSnapshot(
                id: id, title: "Broken scene", workshopID: nil, displayName: harness.screen.name,
                stage: "loading", cause: cause, previousWallpaper: nil, timestamp: Date(), diagnostics: ""
            )
        }

        await harness.waitUntil { harness.state == Self.failed(cause) }
        #expect(harness.manager.getConfiguration(for: harness.screen) == configuration)
        #expect(harness.manager.configurationStore.revision(for: harness.screen.id) == revision)
        loads.clear(for: harness.screen, matching: id)
        await harness.waitUntil { harness.state == healthy }
    }

    @Test("Transient and session runtime errors update and recover without a configuration change", arguments: [true, false])
    func runtimeError(transient: Bool) async {
        let harness = Harness(configured: true)
        defer { harness.close() }
        await harness.waitUntil { harness.state == .ok }
        let configuration = harness.manager.getConfiguration(for: harness.screen)
        let revision = harness.manager.configurationStore.revision(for: harness.screen.id)
        let error = WallpaperRuntimeError.networkOffline
        if transient {
            harness.manager.setTransientRuntimeError(error, for: harness.screen.id)
        } else {
            harness.session.recordRuntimeError(error)
        }

        await harness.waitUntil { harness.state == Self.failed(.runtime(error)) }
        if transient {
            harness.manager.setTransientRuntimeError(nil, for: harness.screen.id)
        } else {
            await harness.session.retry()
        }
        await harness.waitUntil { harness.state == .ok }
        #expect(harness.manager.getConfiguration(for: harness.screen) == configuration)
        #expect(harness.manager.configurationStore.revision(for: harness.screen.id) == revision)
    }

    @Test("Home playback controls and battery policy produce distinguishable pause pills")
    func manualAndPolicyPause() async throws {
        let harness = Harness(configured: true)
        defer { harness.close() }
        await harness.waitUntil { harness.state == .ok }
        let stage = try #require(harness.stageView?.model)
        stage.emit(.playbackTapped(harness.screen.id, .toggle))
        let manual = StageDisplay.State.paused(reasonText: String(localized: "Paused", bundle: .appLanguage))
        await harness.waitUntil { harness.state == manual }
        #expect(!harness.session.userIntendsToPlay)

        harness.manager.togglePlayback(for: harness.screen)
        await harness.waitUntil { harness.state == .ok }
        harness.session.applyPerformanceProfile(.suspended)
        harness.manager.suspendReasonsByScreen[harness.screen.id] = [.battery]
        let policy = try StageDisplay.State.paused(reasonText: #require(SuspendReasonText.localized(for: [.battery])))
        await harness.waitUntil { harness.state == policy }
        #expect(harness.session.userIntendsToPlay)
        #expect(manual != policy)
        harness.session.applyPerformanceProfile(.quality)
        harness.manager.suspendReasonsByScreen.removeValue(forKey: harness.screen.id)
        await harness.waitUntil { harness.state == .ok }
    }

    @Test("Under a policy pause the stage's middle button offers Pause, and pressing it pauses")
    func policyPausedButtonPauses() async throws {
        let harness = Harness(configured: true)
        defer { harness.close() }
        await harness.waitUntil { harness.state == .ok }
        let stage = try #require(harness.stageView?.model)
        harness.session.applyPerformanceProfile(.suspended)
        harness.manager.suspendReasonsByScreen[harness.screen.id] = [.battery]
        let policy = try StageDisplay.State.paused(reasonText: #require(SuspendReasonText.localized(for: [.battery])))
        await harness.waitUntil { harness.state == policy }
        #expect(harness.display?.playbackGlyph == "pause.fill", "policy stopped the picture; the user still wants it playing")
        stage.emit(.playbackTapped(harness.screen.id, .toggle))
        await harness.waitUntil { !harness.session.userIntendsToPlay }
        await harness.waitUntil { harness.display?.playbackGlyph == "play.fill" }
        harness.session.applyPerformanceProfile(.quality)
        harness.manager.suspendReasonsByScreen.removeValue(forKey: harness.screen.id)
    }

    @Test("Turning wallpapers off marks a configured display off; an emptied one shows as empty")
    func wallpapersTurnedOff() async {
        let harness = Harness(configured: true)
        let defaults = UserDefaults.appScoped()
        let key = ScreenManager.globallyEnabledDefaultsKey
        let saved = defaults.object(forKey: key)
        defer {
            // Not through the setter: switching back on would build a real session for the fixture.
            harness.manager.wallpapersGloballyEnabled = true
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            harness.close()
        }
        await harness.waitUntil { harness.state == .ok }
        harness.manager.setWallpapersEnabled(false)
        await harness.waitUntil { harness.state == .off(text: String(localized: "Turned Off", bundle: .appLanguage)) }
        // Control: a display with no wallpaper has nothing to turn off.
        harness.manager.clearWallpaperForScreen(harness.screen)
        await harness.waitUntil { harness.state == .empty }
    }

    @Test("A Finder drop of an unsupported file toasts and shakes that display", .timeLimit(.minutes(1)))
    func unsupportedFinderDrop() async throws {
        let harness = Harness(configured: true)
        defer { harness.close() }
        await harness.waitUntil { harness.state == .ok }
        let view = try #require(harness.stageView)
        view.model.emit(.filesDropped([URL(fileURLWithPath: "/private/tmp/loomscreen-drop/notes.txt")], onto: harness.screen.id))
        await harness.waitUntil { harness.toasts.toasts.map(\.text) == [DropFailure.unrecognizedDrop.toastText] }
        #expect(view.debugShakenDisplays == [harness.screen.id])
    }

    @Test("The display menu offers rename always, and clear and apply-to-all only when they can act")
    func displayMenuRows() async throws {
        let harness = Harness(configured: true)
        defer {
            harness.manager.setCustomName(nil, for: harness.screen)
            harness.close()
        }
        await harness.waitUntil { harness.state == .ok }
        let stage = try #require(harness.stageView?.model)
        let rename = String(localized: "Rename", bundle: .appLanguage)
        let systemName = String(localized: "Use System Name", bundle: .appLanguage)
        let applyAll = String(localized: "Apply to All Displays", bundle: .appLanguage)
        let clear = String(localized: "Clear Wallpaper", bundle: .appLanguage)
        func rows() -> [[String]] {
            (stage.displayMenu?(harness.screen.id) ?? []).map { $0.map { "\($0.title)=\($0.isEnabled)" } }
        }
        // One display: there is no other display to apply to.
        #expect(rows() == [["\(rename)=true"], ["\(applyAll)=false", "\(clear)=true"]])
        harness.manager.setCustomName("Desk", for: harness.screen)
        #expect(rows() == [["\(rename)=true", "\(systemName)=true"], ["\(applyAll)=false", "\(clear)=true"]])
        harness.manager.clearWallpaperForScreen(harness.screen)
        await harness.waitUntil { harness.state == .empty }
        #expect(rows() == [["\(rename)=true", "\(systemName)=true"], ["\(applyAll)=false", "\(clear)=false"]])
    }

    @Test("A display rename or rearrangement re-labels the shelf's ON badge at once")
    func onBadgeFollowsTheDisplayName() async throws {
        let harness = Harness(configured: true)
        let store = BookmarkStore.shared
        let saved = store.add(label: "Badge fixture", content: .html(source: .inline("Test"), config: .default))
        defer {
            store.remove(saved.id)
            harness.manager.setCustomName(nil, for: harness.screen)
            harness.close()
        }
        await harness.waitUntil { harness.state == .ok }
        let stage = try #require(harness.stageView?.model)
        func badge() -> String? {
            stage.shelfItems.first { $0.id == "bookmark:\(saved.id)" }?.onBadge
        }
        await harness.waitUntil { badge() == "ON \(harness.screen.systemName)" }
        harness.manager.setCustomName("Desk", for: harness.screen)
        NotificationCenter.default.post(name: .screensRefreshed, object: nil)
        await harness.waitUntil { badge() == "ON Desk" }
    }

    private static func failed(_ cause: WallpaperFailureCause) -> StageDisplay.State {
        let classification = cause.failureClass
        return .failed(StageFailureChip(
            symbol: classification.symbol, text: classification.kickerText, tint: NSColor(classification.tint).cgColor
        ))
    }

    @MainActor
    private final class Harness {
        let screen = Screen(nsScreen: DisplayStateTestScreen())
        let manager: ScreenManager
        let session: AmbientWallpaperSession
        let target = RetryTarget()
        let toasts = EditDeskToastCenter()
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(configured: Bool) {
            manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
                featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
            ))
            session = AmbientWallpaperSession(window: NSWindow(), wallpaperType: .html, performanceTarget: target)
            if configured {
                var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("Test"), config: .default))
                configuration.displayFingerprint = screen.displayFingerprint
                manager.configurationStore.save(configuration)
                screen.installRuntimeSession(session)
                manager.observeRuntimeErrors(for: session)
                manager.markWallpaperSessionStateChanged()
            }
            let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
            host = NSHostingView(rootView: AnyView(HomePage(router: router, toasts: toasts).environment(manager)))
            host.sizingOptions = []
            window = NSWindow(
                contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
        }

        var stageView: EditDeskStageView? {
            func find(_ view: NSView) -> EditDeskStageView? {
                if let stage = view as? EditDeskStageView {
                    return stage
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        var display: StageDisplay? {
            stageView?.model.displays.first(where: { $0.id == screen.id })
        }

        var state: StageDisplay.State? {
            display?.state
        }

        func waitUntil(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(1)
            while !condition(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await Task.yield()
            }
            #expect(condition(), "The mounted HomePage must update within one second")
        }

        func close() {
            window.close()
            window.contentView = nil
            manager.tearDownForTermination()
            session.cleanup()
            manager.configurationStore.remove(for: screen.id)
        }
    }

    private final class RetryTarget: WallpaperPerformanceConfigurable, HTMLWallpaperRetrying {
        func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
        func retryCurrentSource(timeout _: Duration) async -> WallpaperPreparationResult {
            .ready
        }
    }
}

private final class DisplayStateTestScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xED01_0001)]
    }

    override var localizedName: String {
        "Display State Test"
    }

    /// `ScreenManager.getScreenRefreshRate` falls back to this for an id CoreGraphics does not know;
    /// AppKit traps when a screen built with `init()` is asked.
    override var maximumFramesPerSecond: Int {
        60
    }
}
