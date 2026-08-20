import Testing
import Foundation
import JavaScriptCore
import WebKit
import LiveWallpaperCore
@testable import LiveWallpaper

/// Harness for the lifecycle controller: the globals it patches at document
/// start, stubbed just far enough to observe suspend/resume side effects.
private func makeLifecycleHarnessContext(isTopFrame: Bool) throws -> JSContext {
    let context = try #require(JSContext())
    context.evaluateScript(
        """
        var window = this;
        var nativeTimers = {};
        var nextNativeTimerId = 1;
        window.performance = { now: function () { return 100; } };
        window.setTimeout = function (callback, delay) {
            var id = nextNativeTimerId++;
            nativeTimers[id] = callback;
            return id;
        };
        window.clearTimeout = function (id) { delete nativeTimers[id]; };
        window.setInterval = window.setTimeout;
        window.clearInterval = window.clearTimeout;
        window.requestAnimationFrame = function () { return 1; };
        window.cancelAnimationFrame = function () {};

        var messageListeners = [];
        window.addEventListener = function (type, handler) {
            if (type === 'message') messageListeners.push(handler);
        };
        function deliverMessage(data, source) {
            for (var i = 0; i < messageListeners.length; i++) {
                messageListeners[i]({ data: data, source: source });
            }
        }

        var postedToChildren = [];
        var childFrame = {
            postMessage: function (message) { postedToChildren.push(message.__lwLifecycle__); }
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

        var workerMessages = [];
        var liveWorkers = 0;
        function NativeWorker() {
            liveWorkers += 1;
            this.postMessage = function (message) { workerMessages.push(message.type); };
            this.terminate = function () { liveWorkers -= 1; };
        }
        window.Worker = NativeWorker;
        """
    )
    if isTopFrame {
        context.evaluateScript("window.top = window; window.parent = window; window.frames = [childFrame];")
    } else {
        context.evaluateScript(
            """
            var parentFrame = { postMessage: function () {} };
            window.top = { name: 'top' };
            window.parent = parentFrame;
            window.frames = [];
            """
        )
    }
    return context
}

@Suite("HTML wallpaper subframe and worker lifecycle")
struct HTMLWallpaperFrameLifecycleTests {

    // MARK: - Criterion 2: Worker auto-wrapping

    @Test("A Worker the page never registers is still suspended and resumed")
    func unregisteredWorkerIsAutoManaged() throws {
        let context = try makeLifecycleHarnessContext(isTopFrame: true)
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )
        #expect(context.exception?.toString() == nil)

        context.evaluateScript(
            """
            var worker = new window.Worker('worker.js');
            var isRealWorker = worker instanceof NativeWorker;
            window.__lwSuspend__();
            window.__lwResume__();
            """
        )

        #expect(context.exception?.toString() == nil)
        #expect(context.objectForKeyedSubscript("isRealWorker")?.toBool() == true)
        #expect(
            context.evaluateScript("workerMessages.join(',')")?.toString()
                == "livewallpaper:suspend,livewallpaper:resume"
        )
    }

    @Test("A terminated worker stops receiving lifecycle messages")
    func terminatedWorkerIsUntracked() throws {
        let context = try makeLifecycleHarnessContext(isTopFrame: true)
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )

        context.evaluateScript(
            """
            var worker = new window.Worker('worker.js');
            worker.terminate();
            window.__lwSuspend__();
            """
        )

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("workerMessages.length")?.toInt32() == 0)
        // The wrapper must forward terminate, not swallow it.
        #expect(context.objectForKeyedSubscript("liveWorkers")?.toInt32() == 0)
    }

    @Test("A worker created while suspended is caught up immediately")
    func workerCreatedWhileSuspendedIsSignalled() throws {
        let context = try makeLifecycleHarnessContext(isTopFrame: true)
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )

        context.evaluateScript(
            """
            window.__lwSuspend__();
            var worker = new window.Worker('worker.js');
            """
        )

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("workerMessages.join(',')")?.toString() == "livewallpaper:suspend")
    }

    // MARK: - Criterion 1: subframe lifecycle

    @Test("The main frame relays suspend and resume down to child frames")
    func mainFrameBroadcastsToChildFrames() throws {
        let context = try makeLifecycleHarnessContext(isTopFrame: true)
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )

        context.evaluateScript("window.__lwSuspend__(); window.__lwResume__();")

        #expect(context.exception?.toString() == nil)
        #expect(context.evaluateScript("postedToChildren.join(',')")?.toString() == "suspend,resume")
    }

    @Test("A child frame suspends on its parent's relay and ignores other senders")
    func childFrameHonoursParentRelayOnly() throws {
        let context = try makeLifecycleHarnessContext(isTopFrame: false)
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )
        #expect(context.exception?.toString() == nil)

        context.evaluateScript(
            """
            deliverMessage({ __lwLifecycle__: 'suspend' }, { name: 'stranger' });
            var hiddenAfterStranger = document.hidden === true;
            deliverMessage({ __lwLifecycle__: 'suspend' }, parentFrame);
            var hiddenAfterParent = document.hidden === true;
            deliverMessage({ __lwLifecycle__: 'resume' }, parentFrame);
            var hiddenAfterResume = document.hidden === true;
            """
        )

        #expect(context.exception?.toString() == nil)
        #expect(context.objectForKeyedSubscript("hiddenAfterStranger")?.toBool() == false)
        #expect(context.objectForKeyedSubscript("hiddenAfterParent")?.toBool() == true)
        #expect(context.objectForKeyedSubscript("hiddenAfterResume")?.toBool() == false)
    }

    @Test("The top frame installs no relay listener")
    func topFrameDoesNotListenForRelayMessages() throws {
        let context = try makeLifecycleHarnessContext(isTopFrame: true)
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )

        #expect(context.evaluateScript("messageListeners.length")?.toInt32() == 0)
    }

    @MainActor
    @Test("The lifecycle controller is injected into every frame, the baseline only into the main frame")
    func lifecycleScriptIsInjectedIntoAllFrames() {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { view.cleanup() }

        let scripts = view.webView.configuration.userContentController.userScripts
        let allFrameScripts = scripts.filter { !$0.isForMainFrameOnly }
        #expect(allFrameScripts.count == 1)
        #expect(allFrameScripts.first?.source.contains("window.__lwSuspend__") == true)
        #expect(allFrameScripts.first?.injectionTime == .atDocumentStart)
        // The baseline (page CSS, transform, audio) must not leak into iframes.
        let mainFrameScripts = scripts.filter(\.isForMainFrameOnly)
        #expect(mainFrameScripts.contains { $0.source.contains("lw-user-css") })
        #expect(!allFrameScripts.contains { $0.source.contains("lw-user-css") })
    }

    // MARK: - Todo E: WebGL antialias

    @Test("Explicit antialias:false survives the MSAA forcer")
    func explicitAntialiasFalseIsPreserved() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = this;
            var capturedAttrs = null;
            var capturedType = null;
            function HTMLCanvasElement() {}
            HTMLCanvasElement.prototype.getContext = function (type, attrs) {
                capturedType = type;
                capturedAttrs = attrs;
                return {};
            };
            var canvas = Object.create(HTMLCanvasElement.prototype);
            """
        )
        context.evaluateScript(HTMLWallpaperRuntimeScript.gpuCanvasMSAAForcer())
        #expect(context.exception?.toString() == nil)

        context.evaluateScript("canvas.getContext('webgl', { antialias: false, depth: true });")
        #expect(context.evaluateScript("capturedAttrs.antialias")?.toBool() == false)
        #expect(context.evaluateScript("capturedAttrs.depth")?.toBool() == true)
    }

    @Test("An unspecified antialias is still forced on")
    func unspecifiedAntialiasIsForcedOn() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = this;
            var capturedAttrs = null;
            function HTMLCanvasElement() {}
            HTMLCanvasElement.prototype.getContext = function (type, attrs) {
                capturedAttrs = attrs;
                return {};
            };
            var canvas = Object.create(HTMLCanvasElement.prototype);
            """
        )
        context.evaluateScript(HTMLWallpaperRuntimeScript.gpuCanvasMSAAForcer())

        context.evaluateScript("canvas.getContext('webgl2');")
        #expect(context.evaluateScript("capturedAttrs.antialias")?.toBool() == true)

        context.evaluateScript("canvas.getContext('webgl', {});")
        #expect(context.evaluateScript("capturedAttrs.antialias")?.toBool() == true)

        // WebIDL treats an explicit `undefined` as absent, so it defaults too.
        context.evaluateScript("canvas.getContext('webgl', { antialias: undefined });")
        #expect(context.evaluateScript("capturedAttrs.antialias")?.toBool() == true)
    }

    @Test("Explicit antialias:true is left alone and 2D contexts are untouched")
    func explicitAntialiasTrueAndTwoDAreUntouched() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = this;
            var capturedAttrs = null;
            function HTMLCanvasElement() {}
            HTMLCanvasElement.prototype.getContext = function (type, attrs) {
                capturedAttrs = attrs;
                return {};
            };
            var canvas = Object.create(HTMLCanvasElement.prototype);
            var twoDAttrs = { alpha: false };
            """
        )
        context.evaluateScript(HTMLWallpaperRuntimeScript.gpuCanvasMSAAForcer())

        context.evaluateScript("canvas.getContext('webgl', { antialias: true });")
        #expect(context.evaluateScript("capturedAttrs.antialias")?.toBool() == true)

        context.evaluateScript("canvas.getContext('2d', twoDAttrs);")
        #expect(context.evaluateScript("capturedAttrs === twoDAttrs")?.toBool() == true)
    }
}

// MARK: - Criterion 3: absence-dwell hibernation ordering

@Suite("HTML wallpaper absence-dwell hibernation")
struct HTMLWallpaperHibernationStateTests {

    @Test("The dwell first asks for the snapshot cover, never for about:blank")
    func dwellExpiryCoversBeforeTearingDown() {
        var state = HibernationPhase()

        let first = state.begin()
        #expect(first == .presentCover)
        #expect(state.phase == .live)
        #expect(state.isPresentingCover)

        let second = state.coverDidPresent(true, generation: state.generation)
        #expect(second == .releaseResources)
        #expect(state.phase == .hibernated)
    }

    @Test("A failed cover never drops the document")
    func failedSnapshotDoesNotHibernate() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)

        #expect(state.coverDidPresent(false, generation: state.generation) == nil)
        #expect(state.phase == .live)
        #expect(!state.isPresentingCover)
    }

    @Test("A snapshot reply from an abandoned dwell cannot decide for the next one")
    func staleSnapshotReplyIsRejected() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        let staleGeneration = state.generation

        // The source reloaded mid-capture, then the dwell armed again: the
        // in-flight reply describes a document that is no longer on screen.
        state.noteRebuildStarted()
        #expect(state.begin() == .presentCover)
        #expect(state.generation != staleGeneration)

        #expect(state.coverDidPresent(true, generation: staleGeneration) == nil)
        #expect(state.phase == .live)
        #expect(state.coverDidPresent(true, generation: state.generation) == .releaseResources)
    }

    @Test("A resume while the cover is being captured cancels the teardown")
    func resumeDuringCaptureCancelsTeardown() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        let generation = state.generation

        #expect(state.requestRestore() == nil)

        #expect(state.coverDidPresent(true, generation: generation) == nil)
        #expect(state.phase == .live)
    }

    @Test("Only a hibernated view rebuilds on resume")
    func restoreOnlyFromHibernated() {
        var state = HibernationPhase()
        #expect(state.requestRestore() == nil)

        #expect(state.begin() == .presentCover)
        #expect(state.coverDidPresent(true, generation: state.generation) == .releaseResources)

        #expect(state.requestRestore() == .rebuild)
        #expect(state.phase == .restoring)
    }

    @Test("The cover is dropped exactly once, when the rebuilt document paints")
    func restoreCompletionIsSingleShot() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        #expect(state.coverDidPresent(true, generation: state.generation) == .releaseResources)
        #expect(state.requestRestore() == .rebuild)

        // The restore reload runs through the normal source path.
        state.noteRebuildStarted()
        #expect(state.phase == .restoring)

        // Hoisted: `#expect` on a bare Bool captures the expression immutably,
        // so a mutating call has to happen outside the macro.
        let firstRestore = state.didRestore()
        #expect(firstRestore)
        #expect(state.phase == .live)
        let secondRestore = state.didRestore()
        #expect(!secondRestore)
    }

    @Test("A source load outside the teardown puts a real document back")
    func sourceLoadClearsHibernation() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        #expect(state.coverDidPresent(true, generation: state.generation) == .releaseResources)

        state.noteRebuildStarted()
        #expect(state.phase == .live)
        // Having gone back to live, the dwell can arm again.
        #expect(state.begin() == .presentCover)
    }

    /// A second resume arriving while the previous restore is still loading must
    /// NOT uncover: what is on screen is `about:blank` or a half-built document.
    /// This used to force `.live` and return nil, which the view reads as
    /// "hide the overlay" — a blank desktop.
    @Test("A resume during an in-flight restore keeps the cover")
    func resumeDuringRestoreKeepsTheCover() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        #expect(state.coverDidPresent(true, generation: state.generation) == .releaseResources)
        #expect(state.requestRestore() == .rebuild)

        #expect(state.requestRestore() == .keepCover)
        #expect(state.phase == .restoring, "the reload is still running underneath")
    }

    /// A suspend landing mid-restore has to leave a phase the dwell can arm from.
    /// Both runtimes' eligibility guards only arm from `.live`, and the rebuild in
    /// flight is about to make the resources live again — so `.hibernated` here is
    /// doubly wrong: it claims they are gone AND blocks the dwell that would
    /// release them, so nothing ever would.
    @Test("A suspend during an in-flight restore returns to an armable phase")
    func suspendDuringRestoreStaysArmable() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        #expect(state.coverDidPresent(true, generation: state.generation) == .releaseResources)
        #expect(state.requestRestore() == .rebuild)

        state.noteSuspendedDuringRestore()
        #expect(state.phase == .live, "the rebuild in flight will make resources live")
        #expect(!state.isPresentingCover)
        // The dwell can arm again, which is the whole point.
        #expect(state.begin() == .presentCover)
    }

    @Test("A suspend outside a restore leaves the phase alone")
    func suspendOutsideRestoreIsANoOp() {
        var state = HibernationPhase()
        state.noteSuspendedDuringRestore()
        #expect(state.phase == .live, "control: only `.restoring` is rewritten")
        #expect(state.begin() == .presentCover)
    }

    @Test("Cleanup drops any in-flight hibernation decision")
    func invalidateResetsPhase() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        let staleGeneration = state.generation

        state.invalidate()

        #expect(state.phase == .live)
        #expect(!state.isPresentingCover)
        #expect(state.coverDidPresent(true, generation: staleGeneration) == nil)
    }
}

// MARK: - Manual-pause deep hibernation (parity with the scene session)

/// Records what the session pushes down to the HTML runtime. The view's own
/// dwell/cover/teardown are exercised by `HTMLWallpaperHibernationStateTests`;
/// what is under test here is which eligibility the session folds and when.
@MainActor
private final class RecordingHibernationTarget:
    WallpaperPerformanceConfigurable,
    WallpaperHibernationEligible
{
    private(set) var appliedProfiles: [WallpaperPerformanceProfile] = []
    private(set) var eligibilityPushes: [Bool] = []
    private(set) var immediatePushes: [Bool] = []

    var lastEligibility: Bool? { eligibilityPushes.last }
    var lastPushWasImmediate: Bool? { immediatePushes.last }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        appliedProfiles.append(profile)
    }

    func setHibernationEligible(_ eligible: Bool, immediately: Bool) {
        eligibilityPushes.append(eligible)
        immediatePushes.append(immediately)
    }
}

@MainActor
private struct ManualPauseHarness {
    let target: RecordingHibernationTarget
    let session: AmbientWallpaperSession

    init(userPauseHibernationDelay: Duration) {
        let target = RecordingHibernationTarget()
        self.target = target
        session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target,
            userPauseHibernationDelay: userPauseHibernationDelay
        )
    }

    static func poll(
        _ what: String,
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }
}

@MainActor
@Suite("HTML manual-pause hibernation")
struct HTMLManualPauseHibernationTests {

    @Test("A manual pause makes the HTML runtime hibernation-eligible after its own dwell")
    func manualPauseBecomesEligibleAfterDwell() async throws {
        let harness = ManualPauseHarness(userPauseHibernationDelay: .milliseconds(60))
        defer { harness.session.cleanup() }

        harness.session.pause()

        #expect(harness.target.appliedProfiles.last == .suspended)
        #expect(harness.target.lastEligibility == nil, "the dwell has not elapsed yet")
        try await ManualPauseHarness.poll("eligibility after the pause dwell") {
            harness.target.lastEligibility == true
        }
        #expect(
            harness.target.lastPushWasImmediate == true,
            "the pause dwell is the whole wait; the view must not dwell again on top of it"
        )
    }

    @Test("Routine absence-ineligibility pushes cannot cancel the manual-pause hibernation")
    func absenceIneligibilityDoesNotCancelManualPause() async throws {
        let harness = ManualPauseHarness(userPauseHibernationDelay: .milliseconds(60))
        defer { harness.session.cleanup() }

        harness.session.pause()
        // Every policy refresh pushes absence ineligibility for a non-absent
        // manual pause; the view has one dwell slot, so the fold happens here.
        harness.session.setHibernationEligible(false)
        try await ManualPauseHarness.poll("eligibility after the pause dwell") {
            harness.target.lastEligibility == true
        }

        harness.session.setHibernationEligible(false)

        #expect(harness.target.lastEligibility == true)
    }

    @Test("Unpausing before the dwell elapses cancels it")
    func unpauseBeforeDwellCancels() async throws {
        let harness = ManualPauseHarness(userPauseHibernationDelay: .milliseconds(60))
        defer { harness.session.cleanup() }

        harness.session.pause()
        harness.session.play()
        try await Task.sleep(for: .milliseconds(400))

        #expect(!harness.target.eligibilityPushes.contains(true))
        #expect(harness.target.appliedProfiles.last == .quality)
    }

    @Test("Unpausing a hibernated wallpaper drops the eligibility and resumes it")
    func unpauseAfterHibernationRestores() async throws {
        let harness = ManualPauseHarness(userPauseHibernationDelay: .milliseconds(60))
        defer { harness.session.cleanup() }

        harness.session.pause()
        try await ManualPauseHarness.poll("eligibility after the pause dwell") {
            harness.target.lastEligibility == true
        }

        harness.session.play()

        #expect(harness.target.lastEligibility == false)
        // Resume is the view's normal restore path (reload + cover deadline).
        #expect(harness.target.appliedProfiles.last == .quality)
        #expect(harness.session.isPlaying)
    }

    @Test("A pause still inside its dwell stays resident")
    func pauseWithinDwellStaysResident() async throws {
        // Control for the short-dwell tests: they would also pass if the
        // countdown fired immediately.
        let harness = ManualPauseHarness(userPauseHibernationDelay: .seconds(3600))
        defer { harness.session.cleanup() }

        harness.session.pause()
        try await Task.sleep(for: .milliseconds(400))

        #expect(!harness.target.eligibilityPushes.contains(true))
    }

    /// D3 parity, driven through a real view rather than the recording target:
    /// the session's 300s dwell used to be followed by the view's own 20s
    /// absence dwell, making the true figure 320s while the scene released at
    /// 300s. The view keeps its production dwell here, so only an immediate
    /// handover can flip the phase inside this test's budget.
    @Test("A manual pause hibernates the HTML view without also waiting its absence dwell")
    func manualPauseReleaseDoesNotStackTheViewDwell() async throws {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        defer { view.cleanup() }
        view.loadSource(.inline("<html><body></body></html>"))
        let session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: view,
            userPauseHibernationDelay: .milliseconds(120)
        )
        defer { session.cleanup() }

        session.pause()

        try await ManualPauseHarness.poll("the view leaves .live without its own dwell") {
            view.hibernationState.phase != .live
        }
    }

    @Test("A policy suspend with play intent never arms the pause dwell")
    func policySuspendDoesNotArmPauseDwell() async throws {
        let harness = ManualPauseHarness(userPauseHibernationDelay: .milliseconds(60))
        defer { harness.session.cleanup() }

        harness.session.applyPerformanceProfile(.suspended)
        try await Task.sleep(for: .milliseconds(400))

        #expect(harness.session.userIntendsToPlay)
        #expect(!harness.target.eligibilityPushes.contains(true))
    }
}
