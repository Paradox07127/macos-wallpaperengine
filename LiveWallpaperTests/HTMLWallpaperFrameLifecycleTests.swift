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
    /// Stuck at `.restoring`, `setHibernationEligible` refused forever and the
    /// screen never hibernated again for the rest of the session.
    @Test("A suspend during an in-flight restore returns to a hibernatable phase")
    func suspendDuringRestoreStaysHibernatable() {
        var state = HibernationPhase()
        #expect(state.begin() == .presentCover)
        #expect(state.coverDidPresent(true, generation: state.generation) == .releaseResources)
        #expect(state.requestRestore() == .rebuild)

        state.noteSuspendedDuringRestore()
        #expect(state.phase == .hibernated)
        // And the next resume drives a real restore rather than a bare uncover.
        #expect(state.requestRestore() == .rebuild)
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
