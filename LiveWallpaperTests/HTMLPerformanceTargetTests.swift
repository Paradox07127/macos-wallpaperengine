import AppKit
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import Testing
import WebKit
@testable import LiveWallpaper

/// W3a: the two policy signals HTML used to ignore.
///
/// Frame rate: `PlaybackCoordinator.applyFrameRateLimit` only ever cast to
/// `SceneWallpaperSession`, and the HTML view only ever read `.suspended`, so a
/// user asking for 30 FPS still got a WebContent process running rAF, JS and
/// WebGL at the display's refresh rate. WebKit exposes no frame-rate knob at all
/// (`WKWebpagePreferences` has none, and `setAllMediaPlaybackSuspended` is
/// documented as "audio or video presentation" — it cannot touch canvas/WebGL),
/// so the ceiling lands on the injected rAF gate.
///
/// Critical memory pressure: the signal is dispatched by protocol since
/// `ade11da`; the ambient session simply never conformed.
@MainActor
@Suite("HTML performance target")
struct HTMLPerformanceTargetTests {

    // MARK: - The target reaches the injected gate

    @Test("A 30 FPS ceiling becomes a ~33 ms rAF interval in the injected script")
    func thirtyFPSBecomesAThirtyThreeMillisecondInterval() {
        let interval = HTMLFramePacingPolicy.minimumFrameIntervalMilliseconds(for: .fps30)

        #expect(abs(interval - 33.333) < 0.01)

        let script = HTMLWallpaperRuntimeScript.rafTargetFrameInterval(milliseconds: interval)
        #expect(script.contains("window.__lwSetRafTargetInterval__(33.333)"))
    }

    @Test("Unlimited and an unset ceiling install no gate")
    func unlimitedInstallsNoGate() {
        #expect(HTMLFramePacingPolicy.minimumFrameIntervalMilliseconds(for: .unlimited) == 0)
        #expect(HTMLFramePacingPolicy.minimumFrameIntervalMilliseconds(for: nil) == 0)
        // WPE web wallpapers read `applyGeneralProperties({fps})` as their tempo
        // and have no "as fast as the display" value.
        #expect(HTMLFramePacingPolicy.wallpaperEngineFPS(for: .unlimited) == 60)
        #expect(HTMLFramePacingPolicy.wallpaperEngineFPS(for: nil) == 60)
        #expect(HTMLFramePacingPolicy.wallpaperEngineFPS(for: .fps30) == 30)
    }

    // MARK: - What the gate actually does to a running rAF loop

    /// The acceptance number: a self-perpetuating rAF loop on a 60 Hz display,
    /// one simulated second, target 30 FPS.
    @Test("A 30 FPS target dispatches ~30 rAF callbacks per simulated second")
    func targetThirtyDispatchesThirtyCallbacksPerSecond() throws {
        let context = try makeRafHarness()
        context.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        context.evaluateScript("startLoop(); run(60, 1000 / 60);")

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("dispatched")?.toInt32() == 30)
    }

    /// Control group: the same loop, the same ticks, no ceiling. Without this the
    /// test above could pass on a gate that simply drops half of everything.
    @Test("With no ceiling the same loop runs every frame")
    func noCeilingRunsEveryFrame() throws {
        let context = try makeRafHarness()
        context.evaluateScript("startLoop(); run(60, 1000 / 60);")

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("dispatched")?.toInt32() == 60)
    }

    /// A divisor cannot express 30 on a 136 Hz panel, which is why the ceiling is
    /// an interval. 120 Hz makes the same point with round numbers.
    @Test("The ceiling holds 30 FPS on a 120 Hz display, where a divisor would give 60")
    func ceilingHoldsOnAHighRefreshDisplay() throws {
        let context = try makeRafHarness()
        context.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        context.evaluateScript("startLoop(); run(120, 1000 / 120);")

        #expect(context.evaluateScript("dispatched")?.toInt32() == 30)
    }

    /// Thermal ratio and user ceiling are two knobs, not one: each writes its own
    /// variable and the gate applies whichever is stricter. Ratio 2 alone on a
    /// 120 Hz display is 60 FPS; adding the 30 FPS ceiling must reach 30, and
    /// must not compound into 15.
    @Test("The thermal ratio and the user ceiling compose instead of overwriting")
    func thermalRatioAndCeilingCompose() throws {
        let ratioOnly = try makeRafHarness()
        ratioOnly.evaluateScript("window.__lwSetRafThrottle__(2);")
        ratioOnly.evaluateScript("startLoop(); run(120, 1000 / 120);")
        #expect(ratioOnly.evaluateScript("dispatched")?.toInt32() == 60)

        let both = try makeRafHarness()
        both.evaluateScript("window.__lwSetRafThrottle__(2);")
        both.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        both.evaluateScript("startLoop(); run(120, 1000 / 120);")
        #expect(both.evaluateScript("dispatched")?.toInt32() == 30)
    }

    /// `.suspended` stops the page; the ceiling only slows it down. A suspend
    /// must not clear the ceiling, and the resume must not restore full speed.
    @Test("A suspend/resume round trip keeps the ceiling")
    func suspendResumeKeepsTheCeiling() throws {
        let context = try makeRafHarness()
        context.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        context.evaluateScript("startLoop(); run(6, 1000 / 60);")

        // The frame already registered on the native rAF when the suspend lands
        // still fires once; what must stop is everything after it.
        context.evaluateScript("window.__lwSuspend__(); run(4, 1000 / 60);")
        let settled = context.evaluateScript("dispatched")?.toInt32()
        context.evaluateScript("run(30, 1000 / 60);")
        #expect(
            context.evaluateScript("dispatched")?.toInt32() == settled,
            "a suspended page queues rAF instead of running it"
        )

        context.evaluateScript("window.__lwResume__(); dispatched = 0; run(60, 1000 / 60);")
        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("dispatched")?.toInt32() == 30)
    }

    /// The host can only evaluate script in the main frame, so the ceiling rides
    /// the same `postMessage` relay the suspend phase already uses. This covers
    /// the frames that receive the injected script (`forMainFrameOnly: false`) —
    /// it is not a claim about frames WebKit never injects.
    @Test("The main frame relays the ceiling down to child frames")
    func mainFrameRelaysTheCeilingToChildFrames() throws {
        let context = try makeRafHarness()
        context.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("pacingPostedToChildren.length")?.toInt32() == 1)
        #expect(
            context.evaluateScript("pacingPostedToChildren[0].intervalMs")?.toDouble() == 33.333
        )
    }

    @Test("A child frame takes the ceiling from its parent and ignores other senders")
    func childFrameTakesTheCeilingFromItsParentOnly() throws {
        let context = try makeRafHarness(isTopFrame: false)
        context.evaluateScript(
            """
            deliverMessage({ __lwPacing__: { ratio: 1, intervalMs: 33.333 } }, { name: 'stranger' });
            startLoop(); run(60, 1000 / 60);
            var afterStranger = dispatched;
            dispatched = 0;
            deliverMessage({ __lwPacing__: { ratio: 1, intervalMs: 33.333 } }, parentFrame);
            run(60, 1000 / 60);
            var afterParent = dispatched;
            """
        )

        #expect(context.exception?.toString() == nil)
        #expect(context.objectForKeyedSubscript("afterStranger")?.toInt32() == 60)
        // 31, not 30: the frame already in flight when the ceiling arrives runs
        // ungated, and only its successor goes through the new wrapper.
        let afterParent = context.objectForKeyedSubscript("afterParent")?.toInt32() ?? 0
        #expect((29...31).contains(afterParent), "got \(afterParent)")
    }

    /// The ceiling is a ceiling, not a target to hover around. Restamping the
    /// deadline to the accepting timestamp folded each slack-sized early accept
    /// into the next deadline, so the error accumulated: 30 fps asked for on a
    /// 75 Hz panel was dispatched at 37.5. The bound below is `<=`, not "close
    /// to" — a rate above the user's choice is the whole defect.
    @Test(
        "A 30 FPS ceiling never averages above 30, whatever the panel refreshes at",
        arguments: [60, 75, 120]
    )
    func ceilingNeverAveragesAboveTheTarget(refreshHz: Int) throws {
        let seconds = 5
        let context = try makeRafHarness()
        context.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        context.evaluateScript(
            "startLoop(); run(\(refreshHz * seconds), 1000 / \(refreshHz));"
        )

        #expect(context.exception?.toString() == nil)
        let dispatched = Int(context.evaluateScript("dispatched")?.toInt32() ?? -1)
        let ceiling = 30 * seconds
        #expect(
            dispatched <= ceiling,
            "\(refreshHz) Hz dispatched \(dispatched) frames, ceiling is \(ceiling)"
        )
        // Control group: without it a gate that simply drops everything passes.
        #expect(
            dispatched >= ceiling - 2,
            "\(refreshHz) Hz dispatched only \(dispatched) of \(ceiling)"
        )
    }

    /// The catch-up guard. Advancing the deadline by one interval per accept is
    /// what keeps the average down, but a page that stalled for a second would
    /// then be a second behind schedule and run ungated until it caught up.
    @Test("A long stall does not buy the page a burst of catch-up frames")
    func aStallDoesNotBuyCatchUpFrames() throws {
        let context = try makeRafHarness()
        context.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        context.evaluateScript("startLoop(); run(6, 1000 / 60);")
        // One tick carrying a whole second of wall clock: the shape of a page
        // that was offscreen or blocked on a long task.
        context.evaluateScript("tick(1000); dispatched = 0; run(60, 1000 / 60);")

        #expect(context.exception?.toString() == nil)
        let dispatched = Int(context.evaluateScript("dispatched")?.toInt32() ?? -1)
        #expect(dispatched <= 30, "burst of \(dispatched) frames after the stall")
    }

    // MARK: - Frames that appear after the ceiling was pushed

    /// F2: the ceiling is fanned out once, by the frame that receives it. An
    /// iframe inserted afterwards was never in that broadcast and ran at the
    /// display rate until the next thermal or limit change happened to push
    /// again. It asks on arrival instead.
    @Test("A frame that joins after the broadcast pulls the current pacing")
    func lateChildFramePullsTheCurrentPacing() throws {
        let context = try makeRafHarness()
        context.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        context.evaluateScript(
            """
            function recordingFrame() {
                return {
                    received: [],
                    postMessage: function (message) { this.received.push(message); }
                };
            }
            var lateChild = recordingFrame();
            var stranger = recordingFrame();
            // Joins the tree strictly after the one and only broadcast.
            window.frames = [childFrame, lateChild];
            deliverMessage({ __lwPacingRequest__: true }, lateChild);
            deliverMessage({ __lwPacingRequest__: true }, stranger);
            """
        )

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("lateChild.received.length")?.toInt32() == 1)
        #expect(
            context.evaluateScript("lateChild.received[0].__lwPacing__.intervalMs")?
                .toDouble() == 33.333
        )
        // Only a frame we actually embed may pull our pacing.
        #expect(context.evaluateScript("stranger.received.length")?.toInt32() == 0)
    }

    @Test("A child frame asks its parent for the pacing as soon as it is injected")
    func childFrameAsksItsParentOnInstall() throws {
        let context = try makeRafHarness(isTopFrame: false)

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("postedToParent.length")?.toInt32() == 1)
        #expect(
            context.evaluateScript("postedToParent[0].__lwPacingRequest__")?.toBool() == true
        )
    }

    /// The two halves joined up: what the parent answers is what paces the late
    /// frame's loop. Covers the frames the script is injected into
    /// (`forMainFrameOnly: false`) — not a claim about frames WebKit skips.
    @Test("The answer a late frame pulls actually paces its loop")
    func theAnswerPacesTheLateFrame() throws {
        let parent = try makeRafHarness()
        parent.evaluateScript("window.__lwSetRafTargetInterval__(33.333);")
        parent.evaluateScript(
            """
            var lateChild = {
                received: [],
                postMessage: function (message) { this.received.push(message); }
            };
            window.frames = [lateChild];
            deliverMessage({ __lwPacingRequest__: true }, lateChild);
            """
        )
        #expect(parent.evaluateScript("lateChild.received.length")?.toInt32() == 1)
        let answered = try #require(
            parent.evaluateScript("lateChild.received[0].__lwPacing__.intervalMs")?.toDouble()
        )
        try #require(answered.isFinite)

        let child = try makeRafHarness(isTopFrame: false)
        child.evaluateScript("startLoop(); run(60, 1000 / 60);")
        #expect(
            child.evaluateScript("dispatched")?.toInt32() == 60,
            "control: the late frame runs unpaced until the answer lands"
        )
        child.evaluateScript(
            """
            dispatched = 0;
            deliverMessage({ __lwPacing__: { ratio: 1, intervalMs: \(answered) } }, parentFrame);
            run(60, 1000 / 60);
            """
        )

        #expect(child.exception?.toString() == nil)
        let paced = child.evaluateScript("dispatched")?.toInt32() ?? 0
        #expect((29...31).contains(paced), "got \(paced)")
    }

    // MARK: - Host dispatch

    @Test("Setting the target on the view pushes the interval to the web view")
    func viewPushesTheIntervalOnce() async {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        defer { view.cleanup() }

        view.setTargetFrameRate(.fps30)

        #expect(view.targetFrameRateLimit == .fps30)
        #expect(abs(view.lastRafTargetFrameIntervalMilliseconds - 33.333) < 0.01)
    }

    /// The ceiling is a resource setting, not play intent: pushing one at a
    /// suspended view must not wake it.
    @Test("A ceiling pushed at a suspended view does not resume it")
    func ceilingDoesNotResumeASuspendedView() async {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        defer { view.cleanup() }
        view.applyPerformanceProfile(.suspended)

        view.setTargetFrameRate(.fps30)

        #expect(view.mediaPlaybackSuspended)
        #expect(abs(view.lastRafTargetFrameIntervalMilliseconds - 33.333) < 0.01)
    }

    /// End to end through the real coordinator: the setter a user's 30 FPS choice
    /// lands on has to reach the HTML runtime. This is the assertion the missing
    /// `AmbientWallpaperSession` branch in `applyFrameRateLimit` fails.
    @Test("A user frame-rate change reaches the HTML runtime through the coordinator")
    func coordinatorRoutesTheLimitToTheHTMLRuntime() throws {
        let harness = try HTMLPacingHarness()
        defer { harness.teardown() }

        harness.coordinator.updateFrameRateLimit(.fps30, for: harness.screen)

        #expect(harness.target.targets == [.fps30])
    }

    /// The branch must carry every choice, not only the throttling ones: routing
    /// on `enforcesCompositionCap` (the video rule) would drop `unlimited`.
    @Test("An unlimited choice still reaches the HTML runtime")
    func coordinatorRoutesUnlimitedToo() throws {
        let harness = try HTMLPacingHarness()
        defer { harness.teardown() }

        harness.coordinator.updateFrameRateLimit(.unlimited, for: harness.screen)

        #expect(harness.target.targets == [.unlimited])
    }

    // MARK: - Critical memory pressure

    /// The dispatch points select on the protocol; conforming is the whole wiring.
    @Test("The ambient session satisfies the capability both dispatch points select on")
    func ambientSessionSatisfiesTheCapability() {
        #expect(
            (AmbientWallpaperSession.self as Any) is WallpaperCriticalMemoryPressureResponding.Type
        )
    }

    /// The view's absence dwell is 20s and its manual-pause dwell 300s; only the
    /// immediate handover can push eligibility inside a test.
    @Test("Critical pressure hands a suspended HTML session straight into deep sleep")
    func criticalPressureDeepSleepsASuspendedSession() {
        let harness = PressureHarness()
        defer { harness.session.cleanup() }

        harness.session.applyPerformanceProfile(.suspended)
        harness.pushCriticalMemoryPressure(true)

        #expect(harness.target.eligibility.last == true)
        #expect(
            harness.target.immediate.last == true,
            "the emergency must skip the dwell, not queue behind it"
        )
        // Resource depth only — the signal must not rewrite play intent.
        #expect(harness.session.userIntendsToPlay)
    }

    /// Control group: without the signal the same suspended session stays warm,
    /// so the assertions above are pinned to the pressure and not to the suspend.
    @Test("A suspended HTML session with no pressure signal is not made eligible")
    func suspendedSessionWithoutPressureStaysWarm() {
        let harness = PressureHarness()
        defer { harness.session.cleanup() }

        harness.session.applyPerformanceProfile(.suspended)

        #expect(harness.target.eligibility.isEmpty)
    }

    /// `critical` is graded as a hard safety suspend, so the profile always lands
    /// first. Deepening a session the profile still has at `.quality` would be
    /// this signal overriding the profile instead of layering on it.
    @Test("Critical pressure does not deepen a session the profile still has at quality")
    func criticalPressureDoesNotDeepenAQualityProfile() {
        let harness = PressureHarness()
        defer { harness.session.cleanup() }

        harness.session.applyPerformanceProfile(.quality)
        harness.pushCriticalMemoryPressure(true)

        #expect(!harness.target.eligibility.contains(true))
    }

    /// Fall-back race: the view's dwell is armed as a task even at zero delay, so
    /// a clear landing in the same turn has to revoke it. Re-folding from live
    /// state is what does that; pushing a bare `false` would also cancel an
    /// unrelated absence countdown.
    @Test("Clearing the pressure revokes the eligibility it armed")
    func clearingThePressureRevokesTheEligibility() {
        let harness = PressureHarness()
        defer { harness.session.cleanup() }

        harness.session.applyPerformanceProfile(.suspended)
        harness.pushCriticalMemoryPressure(true)
        harness.pushCriticalMemoryPressure(false)

        #expect(harness.target.eligibility.last == false)
    }

    /// The view owns one eligibility slot shared by absence, manual pause and
    /// pressure, and `ScreenManager` pushes absence ineligibility on every policy
    /// refresh. A teardown only survives if every push site OR-folds all three.
    @Test("Routine absence pushes never cancel a pressure teardown")
    func routineAbsencePushesDoNotCancelThePressureTeardown() {
        let harness = PressureHarness()
        defer { harness.session.cleanup() }

        harness.session.applyPerformanceProfile(.suspended)
        harness.pushCriticalMemoryPressure(true)
        // The exact pair a refresh for an unrelated reason emits mid-emergency.
        harness.session.applyPerformanceProfile(.suspended)
        harness.session.setHibernationEligible(false)

        #expect(harness.target.eligibility.last == true)
    }

    /// The deep-sleep path itself, on a real `WKWebView`: pressure drops the
    /// document to `about:blank` behind the snapshot cover, and the ordinary
    /// resume rebuilds the source.
    @Test("Critical pressure drops the document, and the resume rebuilds it")
    func criticalPressureDropsAndRestoresTheDocument() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWHTMLPacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<html><body>live</body></html>".utf8)
            .write(to: folder.appendingPathComponent("index.html"))
        let bookmark = try #require(ResourceUtilities.createBookmark(for: folder))
        let source = HTMLSource.folder(bookmarkData: bookmark, indexFileName: "index.html")

        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let session = AmbientWallpaperSession(
            window: window,
            wallpaperType: .html,
            performanceTarget: view
        )
        defer { session.cleanup() }

        view.loadSource(source)
        try await poll("the source finishes loading") {
            view.completedNavigationGeneration == view.preparationGeneration
        }

        session.applyPerformanceProfile(.suspended)
        pushCriticalMemoryPressure(true, to: session)
        try await poll("the document is dropped for hibernation") {
            view.webView.url == HTMLWallpaperView.aboutBlank
        }

        // Pressure clearing releases the policy suspend; the wake is ordinary.
        session.applyPerformanceProfile(.quality)
        pushCriticalMemoryPressure(false, to: session)
        try await poll("the source is rebuilt on the way back") {
            view.webView.url?.scheme == FolderURLSchemeHandler.scheme
        }
    }

    /// F3: the cover is a `takeSnapshot` round trip, so every reason to
    /// hibernate has to be re-read when the reply lands. A wallpaper the user
    /// had manually paused stays `mediaPlaybackSuspended` after the pressure
    /// clears, so that check alone let the teardown run anyway — releasing the
    /// document minutes into a 300s warm dwell the user never saw expire.
    @Test("A pressure clear inside the cover request leaves the document alone")
    func pressureClearInsideTheCoverRequestKeepsTheDocument() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWHTMLCover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<html><body>live</body></html>".utf8)
            .write(to: folder.appendingPathComponent("index.html"))
        let bookmark = try #require(ResourceUtilities.createBookmark(for: folder))
        let source = HTMLSource.folder(bookmarkData: bookmark, indexFileName: "index.html")

        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 256, height: 256),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let session = AmbientWallpaperSession(
            window: window,
            wallpaperType: .html,
            performanceTarget: view,
            // The manual-pause dwell must not fire during the test; the point is
            // that the wallpaper still has that whole dwell left.
            userPauseHibernationDelay: .seconds(600)
        )
        defer { session.cleanup() }

        view.loadSource(source)
        try await poll("the source finishes loading") {
            view.completedNavigationGeneration == view.preparationGeneration
        }

        session.applyPerformanceProfile(.suspended)
        try await poll("the suspend snapshot lands") { view.isSnapshotOverlayPresenting }
        // `presentHibernationCover` answers synchronously while the overlay is
        // already up, and then there is no window at all. Pressure arriving
        // before the suspend snapshot settled is the case with one.
        view.hideSnapshotOverlay()

        pushCriticalMemoryPressure(true, to: session)
        try await spinUntil("the cover request is in flight") {
            view.hibernationState.isPresentingCover
        }
        // No suspension point between these two lines, so the clear provably
        // lands while the snapshot reply is still outstanding rather than after.
        #expect(view.hibernationState.isPresentingCover)
        pushCriticalMemoryPressure(false, to: session)

        try await poll("the cover reply lands") { !view.hibernationState.isPresentingCover }
        #expect(
            view.webView.url != HTMLWallpaperView.aboutBlank,
            "the teardown ran on a wallpaper that is no longer eligible"
        )
        #expect(view.hibernationState.phase == .live)
    }

    // MARK: - Harnesses

    /// Yields rather than sleeps: the window this waits for is one main-actor
    /// job wide, and a millisecond poll would step over it.
    private func spinUntil(
        _ what: String,
        iterations: Int = 100_000,
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Spun out waiting for: \(what)")
        throw HarnessError.timedOut(what)
    }

    private func poll(
        _ what: String,
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for: \(what)")
        throw HarnessError.timedOut(what)
    }

    private enum HarnessError: Error {
        case timedOut(String)
    }

    /// Dispatched exactly the way both `ScreenManager` sites do: through the
    /// capability protocol on an erased session. A dropped conformance then
    /// fails here instead of silently reaching nobody in production.
    private func pushCriticalMemoryPressure(
        _ active: Bool,
        to session: any WallpaperRuntimeSession
    ) {
        (session as? any WallpaperCriticalMemoryPressureResponding)?
            .setCriticalMemoryPressureActive(active)
    }

    /// Stubs the globals the lifecycle controller patches at document start, plus
    /// a driven rAF clock: `tick` is the display's vsync, `run` a stretch of them.
    private func makeRafHarness(isTopFrame: Bool = true) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = this;
            var now = 0;
            window.performance = { now: function () { return now; } };

            var nativeTimers = {};
            var nextNativeTimerId = 1;
            window.setTimeout = function (callback) {
                var id = nextNativeTimerId++;
                nativeTimers[id] = callback;
                return id;
            };
            window.clearTimeout = function (id) { delete nativeTimers[id]; };
            window.setInterval = window.setTimeout;
            window.clearInterval = window.clearTimeout;

            var rafPending = [];
            var rafNextId = 1;
            window.requestAnimationFrame = function (cb) {
                var id = rafNextId++;
                rafPending.push({ id: id, cb: cb });
                return id;
            };
            window.cancelAnimationFrame = function (id) {
                for (var i = 0; i < rafPending.length; i++) {
                    if (rafPending[i].id === id) { rafPending.splice(i, 1); return; }
                }
            };
            var dispatched = 0;
            function startLoop() {
                function frame(t) {
                    dispatched += 1;
                    window.requestAnimationFrame(frame);
                }
                window.requestAnimationFrame(frame);
            }
            function tick(intervalMs) {
                now += intervalMs;
                var due = rafPending;
                rafPending = [];
                for (var i = 0; i < due.length; i++) due[i].cb(now);
            }
            function run(frames, intervalMs) {
                for (var i = 0; i < frames; i++) tick(intervalMs);
            }

            var messageListeners = [];
            window.addEventListener = function (type, handler) {
                if (type === 'message') messageListeners.push(handler);
            };
            function deliverMessage(data, source) {
                for (var i = 0; i < messageListeners.length; i++) {
                    messageListeners[i]({ data: data, source: source });
                }
            }

            var pacingPostedToChildren = [];
            var childFrame = {
                postMessage: function (message) {
                    if (message.__lwPacing__) pacingPostedToChildren.push(message.__lwPacing__);
                }
            };

            function Event(type) { this.type = type; }
            function Document() {}
            var document = Object.create(Document.prototype);
            var installedStyle = null;
            document.dispatchEvent = function () {};
            document.getElementById = function () { return installedStyle; };
            document.createElement = function () { return { id: '', textContent: '' }; };
            document.querySelectorAll = function () { return []; };
            document.documentElement = {
                classList: { toggle: function () {} },
                appendChild: function (element) { installedStyle = element; }
            };
            document.head = { appendChild: function (element) { installedStyle = element; } };

            function NativeWorker() {
                this.postMessage = function () {};
                this.terminate = function () {};
            }
            window.Worker = NativeWorker;
            """
        )
        if isTopFrame {
            context.evaluateScript(
                "window.top = window; window.parent = window; window.frames = [childFrame];"
            )
        } else {
            context.evaluateScript(
                """
                var postedToParent = [];
                var parentFrame = {
                    postMessage: function (message) { postedToParent.push(message); }
                };
                window.top = { name: 'top' };
                window.parent = parentFrame;
                window.frames = [];
                """
            )
        }
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )
        #expect(context.exception?.toString() == nil)
        return context
    }
}

/// Records what the session pushes down to the HTML runtime.
@MainActor
private final class RecordingHTMLPerformanceTarget:
    WallpaperPerformanceConfigurable,
    WallpaperHibernationEligible,
    HTMLWallpaperFrameRateTargeting
{
    private(set) var profiles: [WallpaperPerformanceProfile] = []
    private(set) var eligibility: [Bool] = []
    private(set) var immediate: [Bool] = []
    private(set) var targets: [FrameRateLimit] = []

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        profiles.append(profile)
    }

    func setHibernationEligible(_ eligible: Bool, immediately: Bool) {
        eligibility.append(eligible)
        immediate.append(immediately)
    }

    func setTargetFrameRate(_ limit: FrameRateLimit) {
        targets.append(limit)
    }
}

@MainActor
private struct PressureHarness {
    let target = RecordingHTMLPerformanceTarget()
    let session: AmbientWallpaperSession

    /// See `pushCriticalMemoryPressure(_:to:)`: the protocol hop is the point.
    func pushCriticalMemoryPressure(_ active: Bool) {
        let runtime: any WallpaperRuntimeSession = session
        (runtime as? any WallpaperCriticalMemoryPressureResponding)?
            .setCriticalMemoryPressureActive(active)
    }

    init() {
        session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target,
            // Longer than any test could wait out, so only the immediate
            // handover can produce an eligibility push.
            userPauseHibernationDelay: .seconds(600)
        )
    }
}

/// A real `PlaybackCoordinator` over a screen running an ambient HTML session.
@MainActor
private struct HTMLPacingHarness {
    let screen: Screen
    let target = RecordingHTMLPerformanceTarget()
    let session: AmbientWallpaperSession
    let coordinator: PlaybackCoordinator

    init() throws {
        let nsScreen = try #require(NSScreen.screens.first)
        screen = Screen(nsScreen: nsScreen)
        session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target
        )
        screen.installRuntimeSession(session)

        let store = WallpaperConfigurationStore(persistence: HTMLPacingPersistence())
        var configuration = ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: .url(URL(string: "about:blank")!), config: .default),
            frameRateLimit: .fps60
        )
        configuration.displayFingerprint = screen.displayFingerprint
        store.save(configuration)

        let screenForClosure = screen
        coordinator = PlaybackCoordinator(
            configurationStore: store,
            playableVideoLoader: FakePlayableVideoLoader(),
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in (URL(fileURLWithPath: "/tmp/html-pacing"), false) },
                refreshData: { _ in Data() }
            ),
            applyPolicy: { _ in },
            applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 },
            screensProvider: { [screenForClosure] },
            markSessionStateChanged: {},
            releaseRuntimeSession: { _ in },
            notifyWallpaperSessionChanged: {},
            originReconciler: PreservingOriginReconciler()
        )
    }

    func teardown() {
        session.cleanup()
        screen.resetRuntimeSession()
    }
}

private final class HTMLPacingPersistence: ScreenConfigurationPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations[screenID] = nil
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(configurations.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(
            uniqueKeysWithValues: configurations.map { ($0.screenID, $0) }
        )
    }
}
