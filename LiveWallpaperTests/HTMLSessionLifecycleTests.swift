import Testing
import Foundation
import JavaScriptCore
import WebKit
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("FolderURLSchemeHandler session lifecycle")
@MainActor
struct FolderURLSchemeHandlerLifecycleTests {

    @Test("Range request returns 206 with Content-Range header and trimmed payload")
    func rangeRequestReturns206() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data((0..<2048).map { UInt8($0 % 256) })
        let asset = folder.appendingPathComponent("blob.bin")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/blob.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")",
            range: "bytes=0-99"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 0-99/2048")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(task.totalReceivedBytes == 100)
    }

    @Test("Suffix range bytes=-N returns the trailing N bytes")
    func suffixRangeReturnsTrailingBytes() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data((0..<512).map { UInt8($0 % 256) })
        let asset = folder.appendingPathComponent("trail.bin")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/trail.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")",
            range: "bytes=-64"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 448-511/512")
        #expect(task.totalReceivedBytes == 64)
    }

    @Test("Plain GET without Range returns 200 + full payload")
    func plainRequestReturns200WithFullPayload() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data("hello world".utf8)
        let asset = folder.appendingPathComponent("hello.txt")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/hello.txt",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == nil)
        #expect(task.totalReceivedBytes == payload.count)
    }

    @Test("CSP enforcement on attaches the enforced Content-Security-Policy header")
    func cspEnforcementOnAttachesHeader() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("body {}".utf8).write(to: folder.appendingPathComponent("style.css"))

        let handler = FolderURLSchemeHandler()
        handler.cspEnforcementEnabled = true
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/style.css",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(
            response.value(forHTTPHeaderField: "Content-Security-Policy")
                == FolderURLSchemeHandler.contentSecurityPolicy
        )
    }

    @Test("CSP enforcement off (the config default) omits the Content-Security-Policy header")
    func cspEnforcementOffOmitsHeader() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("body {}".utf8).write(to: folder.appendingPathComponent("style.css"))

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/style.css",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy") == nil)
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy-Report-Only") == nil)
    }

    @Test("Stop after start prevents finish from firing")
    func stopAfterStartCancelsDelivery() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data(repeating: 0xAB, count: 1 * 1024 * 1024)
        let asset = folder.appendingPathComponent("large.bin")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/large.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        handler.webView(WKWebView(), stop: task)

        try await Task.sleep(for: .milliseconds(50))
        #expect(!task.didFinishCalled)
    }

    @Test("Reassigning folderURL cancels in-flight workers from the previous folder")
    func reassigningFolderCancelsInFlightWorkers() async throws {
        let firstFolder = makeTemporaryFolder()
        let secondFolder = makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: firstFolder)
            try? FileManager.default.removeItem(at: secondFolder)
        }

        let payload = Data(repeating: 0x55, count: 512 * 1024)
        try payload.write(to: firstFolder.appendingPathComponent("big.bin"))

        let handler = FolderURLSchemeHandler()
        handler.folderURL = firstFolder
        let firstNonce = handler.currentSessionNonce ?? ""

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/big.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(firstNonce)"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        handler.folderURL = secondFolder

        try await Task.sleep(for: .milliseconds(50))
        #expect(!task.didFinishCalled)
        #expect(handler.currentSessionNonce != firstNonce)
    }

    @Test("Path traversal escapes the folder root and fails")
    func pathTraversalIsRejected() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("ok".utf8).write(to: folder.appendingPathComponent("ok.txt"))

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/../../../etc/passwd",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskFails(task)

        #expect(task.failedError != nil)
        #expect(task.didFinishCalled == false)
    }

    private func makeTemporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWLifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func subresourceRequest(
        url: String,
        mainDocument: String,
        range: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.mainDocumentURL = URL(string: mainDocument)
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }

    private func waitUntilTaskCompletes(
        _ task: FakeURLSchemeTask,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await waitUntil(timeout: timeout) {
            task.didFinishCalled || task.failedError != nil
        }
        if let error = task.failedError {
            Issue.record("Expected success but task failed: \(error)")
        }
    }

    private func waitUntilTaskFails(
        _ task: FakeURLSchemeTask,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await waitUntil(timeout: timeout) {
            task.failedError != nil
        }
    }

    private func waitUntil(
        timeout: Duration,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite("HTML wallpaper runtime scripts")
struct HTMLWallpaperRuntimeScriptTests {
    @Test("Physical-pixel script exposes the native device pixel ratio and toggle flag")
    func physicalPixelScriptExposesNativeDevicePixelRatio() {
        let enabled = HTMLWallpaperRuntimeScript.physicalPixelState(enabled: true, backingScale: 2)

        #expect(enabled.contains("__liveWallpaperNativeDevicePixelRatio = 2"))
        #expect(enabled.contains("__liveWallpaperPhysicalPixelLayout = true"))
        #expect(!enabled.contains("Object.defineProperty(window, 'devicePixelRatio'"))
        #expect(!enabled.contains("dispatchEvent(new Event('resize'))"))

        let disabled = HTMLWallpaperRuntimeScript.physicalPixelState(enabled: false, backingScale: 2)
        #expect(disabled.contains("__liveWallpaperPhysicalPixelLayout = false"))
    }

    @Test("Wallpaper Engine general properties script sends fps")
    func wallpaperEngineGeneralPropertiesScriptSendsFPS() {
        let script = HTMLWallpaperRuntimeScript.wallpaperEngineGeneralProperties(fps: 1)

        #expect(script.contains("applyGeneralProperties"))
        #expect(script.contains("\"fps\":1"))
    }

    @Test("Lifecycle script keeps throttle changes made while suspended")
    func lifecycleScriptKeepsSuspendedThrottleChanges() throws {
        let script = HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        let installerStart = try #require(script.range(of: "function installRafThrottle(ratio)"))
        let installerEnd = try #require(
            script.range(of: "function ensurePauseStyle()", range: installerStart.upperBound..<script.endIndex)
        )
        let installer = script[installerStart.lowerBound..<installerEnd.lowerBound]
        let ratioAssignment = try #require(installer.range(of: "rafThrottleRatio = ratio;"))
        let suspendedGuard = try #require(installer.range(of: "if (rafBackup) return;"))

        #expect(ratioAssignment.lowerBound < suspendedGuard.lowerBound)

        let resumeStart = try #require(script.range(of: "window.__lwResume__ = function ()"))
        let resumeEnd = try #require(
            script.range(of: "window.__lwSetRafThrottle__", range: resumeStart.upperBound..<script.endIndex)
        )
        let resume = script[resumeStart.lowerBound..<resumeEnd.lowerBound]

        #expect(resume.contains("restoreRaf();"))
        #expect(resume.contains("installRafThrottle(rafThrottleRatio);"))
        #expect(!resume.contains("if (rafThrottleRatio > 1)"))
    }

    @Test("Lifecycle script parks page timers instead of letting callbacks wake while suspended")
    func lifecycleScriptParksTimers() {
        let script = HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)

        #expect(script.contains("var nativeSetTimeout = window.setTimeout;"))
        #expect(script.contains("window.setInterval = function"))
        #expect(script.contains("function suspendTimers()"))
        #expect(script.contains("function resumeTimers()"))
        #expect(script.contains("nativeClearTimeout.call(window, record.nativeId);"))
        #expect(script.contains("suspendTimers();"))
        #expect(script.contains("resumeTimers();"))
    }

    @Test("Lifecycle script offers opt-in suspend and resume messages to cooperative workers")
    func lifecycleScriptSignalsWorkers() {
        let script = HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)

        #expect(script.contains("function installWorkerLifecycle()"))
        #expect(script.contains("__lwRegisterWorkerForLifecycle__"))
        #expect(script.contains("livewallpaper:suspend"))
        #expect(script.contains("livewallpaper:resume"))
        #expect(script.contains("worker.postMessage"))
        #expect(script.contains("signalWorkers('suspend');"))
        #expect(script.contains("signalWorkers('resume');"))
        #expect(!script.contains("window.Worker = ManagedWorker"))
    }

    @Test("Lifecycle timer and worker state machine executes in JavaScriptCore")
    func lifecycleTimerAndWorkerStateMachineExecutes() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = this;
            var nativeSetCalls = 0;
            var nativeClearCalls = 0;
            var nextNativeTimerId = 1;
            var nativeTimers = {};
            window.performance = { now: function () { return 100; } };
            window.setTimeout = function (callback, delay) {
                nativeSetCalls += 1;
                var id = nextNativeTimerId++;
                nativeTimers[id] = callback;
                return id;
            };
            window.clearTimeout = function (id) {
                nativeClearCalls += 1;
                delete nativeTimers[id];
            };
            window.setInterval = window.setTimeout;
            window.clearInterval = window.clearTimeout;
            window.requestAnimationFrame = function () { return 1; };
            window.cancelAnimationFrame = function () {};

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
            document.head = {
                appendChild: function (element) { installedStyle = element; }
            };

            var workerMessages = [];
            function NativeWorker() {
                this.postMessage = function (message) { workerMessages.push(message.type); };
                this.terminate = function () {};
            }
            window.Worker = NativeWorker;
            """
        )
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.lifecycleController(aggressiveSuspend: false)
        )
        #expect(context.exception?.toString() == nil)

        context.evaluateScript(
            """
            var intervalErrorWasRethrown = false;
            var intervalId = window.setInterval(function () {
                throw new Error('interval failed');
            }, 16);
            try {
                nativeTimers[1]();
            } catch (error) {
                intervalErrorWasRethrown = error.message === 'interval failed';
            }
            var managedWorker = new window.Worker('worker.js');
            window.__lwRegisterWorkerForLifecycle__(managedWorker);
            window.__lwSuspend__();
            var timeoutWhileSuspended = window.setTimeout(function () {}, 25);
            """
        )

        // The repeating callback reschedules exactly once before surfacing its
        // error. No unmanaged error-reporting timer is created.
        #expect(context.objectForKeyedSubscript("intervalErrorWasRethrown")?.toBool() == true)
        #expect(context.objectForKeyedSubscript("nativeSetCalls")?.toInt32() == 2)
        #expect(context.objectForKeyedSubscript("nativeClearCalls")?.toInt32() == 1)
        #expect(context.evaluateScript("workerMessages.join(',')")?.toString() == "livewallpaper:suspend")

        context.evaluateScript("window.__lwResume__();")

        #expect(context.exception?.toString() == nil)
        #expect(context.objectForKeyedSubscript("nativeSetCalls")?.toInt32() == 4)
        #expect(
            context.evaluateScript("workerMessages.join(',')")?.toString()
                == "livewallpaper:suspend,livewallpaper:resume"
        )
    }

    @Test("Native media and JavaScript lifecycle transitions serialize rapid flips")
    func nativeAndJavaScriptLifecycleTransitionsAreGenerationOrdered() {
        var state = HTMLMediaLifecycleState()

        let suspend = state.request(true)
        #expect(suspend.changed)
        #expect(suspend.start?.suspended == true)

        let resume = state.request(false)
        let suspendAgain = state.request(true)
        #expect(resume.changed)
        #expect(suspendAgain.changed)
        #expect(resume.start == nil)
        #expect(suspendAgain.start == nil)

        let firstCompletion = state.finish(suspend.start!)
        #expect(!firstCompletion.wasCurrent)
        #expect(firstCompletion.next?.suspended == true)
        #expect(firstCompletion.next?.generation == state.generation)

        let finalCompletion = state.finish(firstCompletion.next!)
        #expect(finalCompletion.wasCurrent)
        #expect(finalCompletion.next == nil)
        #expect(state.inFlight == nil)
        #expect(state.desiredSuspended)
    }

    @Test("Master audio script routes Web Audio destination connects through gain")
    func masterAudioScriptRoutesWebAudioDestinationConnectsThroughGain() {
        let script = HTMLWallpaperRuntimeScript.masterAudioController(initialVolume: 0.35, initialMuted: true)

        #expect(script.contains("Object.defineProperty(HTMLMediaElement.prototype, 'volume'"))
        #expect(script.contains("Object.defineProperty(HTMLMediaElement.prototype, 'muted'"))
        #expect(script.contains("requestedVolume * __lwVolume__"))
        #expect(script.contains("function ensureMasterGain"))
        #expect(script.contains("AudioNode.prototype.connect"))
        #expect(script.contains("AudioDestinationNode"))
        #expect(script.contains("args[0] = ensureMasterGain(this.context, destination);"))
        #expect(script.contains("__lwUpdateAudio__(0.350000, true)"))
    }

    @Test("Master audio updates anonymous new Audio elements outside the DOM")
    func masterAudioUpdatesAnonymousElements() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = this;
            function HTMLMediaElement() {}
            Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
                configurable: true,
                get: function () { return this._nativeVolume; },
                set: function (value) { this._nativeVolume = Number(value); }
            });
            Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
                configurable: true,
                get: function () { return !!this._nativeMuted; },
                set: function (value) { this._nativeMuted = !!value; }
            });
            HTMLMediaElement.prototype.play = function () {
                this.paused = false;
                return { catch: function () {} };
            };
            function NativeAudio() {
                this.tagName = 'AUDIO';
                this._nativeVolume = 1;
                this._nativeMuted = false;
                this.paused = true;
                this.ended = false;
                this.readyState = 4;
                this.networkState = 1;
                this.currentTime = 0;
                this.src = 'livewallpaper://folder/assets/background.flac';
            }
            NativeAudio.prototype = Object.create(HTMLMediaElement.prototype);
            NativeAudio.prototype.constructor = NativeAudio;
            window.Audio = NativeAudio;
            var document = {
                body: null,
                querySelectorAll: function () { return []; }
            };
            """
        )
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.masterAudioController(
                initialVolume: 0.4,
                initialMuted: true
            )
        )
        #expect(context.exception?.toString() == nil)

        context.evaluateScript(
            """
            var backgroundMusic = new window.Audio();
            backgroundMusic.volume = 0.5;
            var nativeBefore = backgroundMusic._nativeVolume;
            var mutedBefore = backgroundMusic._nativeMuted;
            window.__lwUpdateAudio__(0.8, false);
            var nativeAfter = backgroundMusic._nativeVolume;
            var mutedAfter = backgroundMusic._nativeMuted;
            var audioSnapshot = window.__lwAudioDebugSnapshot__();
            """
        )

        #expect(context.exception?.toString() == nil)
        #expect(abs((context.objectForKeyedSubscript("nativeBefore")?.toDouble() ?? -1) - 0.2) < 0.0001)
        #expect(context.objectForKeyedSubscript("mutedBefore")?.toBool() == true)
        #expect(abs((context.objectForKeyedSubscript("nativeAfter")?.toDouble() ?? -1) - 0.4) < 0.0001)
        #expect(context.objectForKeyedSubscript("mutedAfter")?.toBool() == false)
        #expect(context.evaluateScript("audioSnapshot.media.length")?.toInt32() == 1)
        #expect(context.evaluateScript("audioSnapshot.media[0].source")?.toString() == "background.flac")
    }
}

@Suite("HTML preview load ownership")
struct HTMLPreviewLoadStateTests {
    @Test("Switching cache identity immediately admits a replacement load")
    func switchingCacheIdentityAdmitsReplacement() {
        var state = HTMLPreviewLoadState()
        let original = state.begin(cacheKey: "first")

        state.invalidate()
        #expect(!state.isLoading)

        let replacement = state.begin(cacheKey: "second")
        #expect(state.isLoading)
        #expect(!state.isCurrent(original))
        #expect(state.isCurrent(replacement))
    }

    @Test(
        "A stale success or failure cannot finish the replacement load",
        arguments: [true, false]
    )
    func staleCompletionCannotPublish(_ oldLoadSucceeded: Bool) {
        var state = HTMLPreviewLoadState()
        let original = state.begin(cacheKey: "first")
        state.invalidate()
        let replacement = state.begin(cacheKey: "second")

        var publishedResult: Bool?
        if state.finish(original) {
            publishedResult = oldLoadSucceeded
        }

        #expect(publishedResult == nil)
        #expect(state.isLoading)
        #expect(state.isCurrent(replacement))
        let didFinishReplacement = state.finish(replacement)
        #expect(didFinishReplacement)
        #expect(!state.isLoading)
    }

    @Test("Disappearance invalidates a late completion")
    func disappearanceInvalidatesLateCompletion() {
        var state = HTMLPreviewLoadState()
        let load = state.begin(cacheKey: "visible")

        state.invalidate()

        #expect(!state.isLoading)
        #expect(!state.isCurrent(load))
        let didFinishInvalidatedLoad = state.finish(load)
        #expect(!didFinishInvalidatedLoad)
    }
}

@Suite("HTML live preview capture identity")
struct HTMLLivePreviewCaptureStateTests {
    private let source = HTMLSource.url(URL(string: "https://example.com/current")!)
    private let replacement = HTMLSource.url(URL(string: "https://example.com/replacement")!)

    @Test("Only the completed current source and config can back a live preview")
    func completedCurrentIdentityCanBeReused() {
        let config = HTMLConfig.default
        let state = HTMLLivePreviewCaptureState(
            source: source,
            config: config,
            navigationGeneration: 7,
            completedNavigationGeneration: 7,
            failedNavigationGeneration: nil,
            isCleaningUp: false
        )

        #expect(state.canReuse(requestedSource: source, requestedConfig: config))
        #expect(!state.canReuse(requestedSource: replacement, requestedConfig: config))

        var changedConfig = config
        changedConfig.customCSS = "body { opacity: 0.5; }"
        #expect(!state.canReuse(requestedSource: source, requestedConfig: changedConfig))
    }

    @Test("An in-flight, failed, or torn-down navigation cannot back a live preview")
    func nonCurrentNavigationCannotBeReused() {
        let config = HTMLConfig.default
        let loading = HTMLLivePreviewCaptureState(
            source: source,
            config: config,
            navigationGeneration: 8,
            completedNavigationGeneration: 7,
            failedNavigationGeneration: nil,
            isCleaningUp: false
        )
        let failed = HTMLLivePreviewCaptureState(
            source: source,
            config: config,
            navigationGeneration: 8,
            completedNavigationGeneration: 8,
            failedNavigationGeneration: 8,
            isCleaningUp: false
        )
        let cleaningUp = HTMLLivePreviewCaptureState(
            source: source,
            config: config,
            navigationGeneration: 8,
            completedNavigationGeneration: 8,
            failedNavigationGeneration: nil,
            isCleaningUp: true
        )

        #expect(!loading.canReuse(requestedSource: source, requestedConfig: config))
        #expect(!failed.canReuse(requestedSource: source, requestedConfig: config))
        #expect(!cleaningUp.canReuse(requestedSource: source, requestedConfig: config))
    }
}

@Suite("HTML navigation generation ownership")
struct HTMLNavigationGenerationStateTests {
    @Test("A retired navigation cannot complete its replacement generation")
    func retiredNavigationCannotPublish() {
        var state = HTMLNavigationGenerationState()
        let original = NSObject()
        let replacement = NSObject()

        state.registerHostNavigation(original, generation: 1)
        state.registerHostNavigation(replacement, generation: 2)

        let staleHostConsumed = state.consumeIfCurrent(original, currentGeneration: 2)
        let currentHostConsumed = state.consumeIfCurrent(replacement, currentGeneration: 2)
        #expect(!staleHostConsumed)
        #expect(currentHostConsumed)
    }

    @Test("A delayed start callback cannot reclaim ownership from a host replacement")
    func delayedStartCannotReclaimOwnership() {
        var state = HTMLNavigationGenerationState()
        let original = NSObject()
        let replacement = NSObject()

        state.registerHostNavigation(original, generation: 10)
        state.registerHostNavigation(replacement, generation: 11)
        state.registerWebKitNavigationIfNeeded(
            original,
            currentGeneration: 11
        )

        let delayedStartConsumed = state.consumeIfCurrent(original, currentGeneration: 11)
        let replacementConsumed = state.consumeIfCurrent(replacement, currentGeneration: 11)
        #expect(!delayedStartConsumed)
        #expect(replacementConsumed)
    }

    @Test("A rejected host load still retires the previous identity")
    func nilHostLoadRetiresPreviousIdentity() {
        var state = HTMLNavigationGenerationState()
        let original = NSObject()
        let pageNavigation = NSObject()

        state.registerHostNavigation(original, generation: 15)
        state.registerHostNavigation(nil, generation: 16)

        let retiredOriginalConsumed = state.consumeIfCurrent(original, currentGeneration: 16)
        #expect(!retiredOriginalConsumed)
        state.registerWebKitNavigationIfNeeded(
            pageNavigation,
            currentGeneration: 16
        )
        let pageConsumed = state.consumeIfCurrent(pageNavigation, currentGeneration: 16)
        #expect(pageConsumed)
    }

    @Test("A page navigation is admitted after the host navigation completes")
    func pageNavigationAfterHostCompletionIsAdmitted() {
        var state = HTMLNavigationGenerationState()
        let host = NSObject()
        let pageNavigation = NSObject()

        state.registerHostNavigation(host, generation: 20)
        let hostConsumed = state.consumeIfCurrent(host, currentGeneration: 20)
        #expect(hostConsumed)

        state.registerWebKitNavigationIfNeeded(
            pageNavigation,
            currentGeneration: 20
        )
        let pageAfterHostConsumed = state.consumeIfCurrent(pageNavigation, currentGeneration: 20)
        #expect(pageAfterHostConsumed)
    }

    @Test("WebKit progress retains the host navigation identity")
    func progressRetainsHostIdentity() {
        var state = HTMLNavigationGenerationState()
        let host = NSObject()

        state.registerHostNavigation(host, generation: 30)
        state.registerWebKitNavigationIfNeeded(
            host,
            currentGeneration: 30
        )

        let hostRetainedConsumed = state.consumeIfCurrent(host, currentGeneration: 30)
        #expect(hostRetainedConsumed)
    }
}

@Suite("HTML preparation retry generation")
@MainActor
struct HTMLPreparationRetryGenerationTests {
    @Test("Same-source automatic retry follows the new generation and becomes ready")
    func sameSourceRetryBecomesReady() async throws {
        let source = HTMLSource.url(
            try #require(URL(string: "https://example.com/wallpaper"))
        )
        var probeCount = 0
        var snapshotCount = 0

        let result = await HTMLPreparationReadiness.wait(
            timeout: .seconds(1),
            initialGeneration: 1,
            source: source,
            currentState: {
                probeCount += 1
                if probeCount == 1 {
                    return HTMLPreparationProbeState(
                        generation: 1,
                        source: source,
                        failedGeneration: nil,
                        completedGeneration: nil,
                        isCleaningUp: false
                    )
                }
                return HTMLPreparationProbeState(
                    generation: 2,
                    source: source,
                    failedGeneration: nil,
                    completedGeneration: 2,
                    isCleaningUp: false
                )
            },
            captureSnapshot: {
                snapshotCount += 1
                return true
            }
        )

        #expect(result == .ready)
        #expect(probeCount >= 2)
        #expect(snapshotCount == 1)
    }

    @Test("Source or navigation change cancels the original preparation")
    func sourceChangeCancelsPreparation() async throws {
        let source = HTMLSource.url(
            try #require(URL(string: "https://example.com/wallpaper"))
        )
        let replacement = HTMLSource.url(
            try #require(URL(string: "https://example.com/other"))
        )
        var probeCount = 0
        var snapshotCount = 0

        let result = await HTMLPreparationReadiness.wait(
            timeout: .seconds(1),
            initialGeneration: 10,
            source: source,
            currentState: {
                probeCount += 1
                if probeCount == 1 {
                    return HTMLPreparationProbeState(
                        generation: 10,
                        source: source,
                        failedGeneration: nil,
                        completedGeneration: nil,
                        isCleaningUp: false
                    )
                }
                return HTMLPreparationProbeState(
                    generation: 11,
                    source: replacement,
                    failedGeneration: nil,
                    completedGeneration: 11,
                    isCleaningUp: false
                )
            },
            captureSnapshot: {
                snapshotCount += 1
                return true
            }
        )

        #expect(result == .cancelled)
        #expect(probeCount >= 2)
        #expect(snapshotCount == 0)
    }
}

@Suite("Ambient HTML user retry")
@MainActor
struct AmbientHTMLUserRetryTests {
    @Test("A user retry resets the HTML automatic retry budget without network access")
    func userRetryResetsAutomaticRetryBudget() async {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        defer { view.cleanup() }
        view.lastSource = .url(URL(string: "about:blank")!)
        view.consecutiveFailureCount = 4

        _ = await view.retryCurrentSource(timeout: .milliseconds(1))

        #expect(view.consecutiveFailureCount == 0)
    }

    @Test("A suspended package retry prepares explicitly without resuming background work")
    func suspendedPackageRetryIsExplicitlyAdmitted() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWHTMLRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<html><body>ready</body></html>".utf8)
            .write(to: folder.appendingPathComponent("index.html"))
        try FolderURLSchemeHandlerIsolationTests.makePackageData(entries: [
            ("index.html", Data("<html><body>packaged</body></html>".utf8))
        ]).write(to: folder.appendingPathComponent("scene.pkg"))
        let bookmark = try #require(ResourceUtilities.createBookmark(for: folder))
        let source = HTMLSource.folder(
            bookmarkData: bookmark,
            indexFileName: "index.html"
        )
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 32, height: 32),
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

        session.pause()
        view.loadSource(source)
        #expect(view.mediaPlaybackSuspended)
        #expect(view.reloadScheduler.isSuspended)
        #expect(view.restartPackageBackingAfterResume)
        #expect(view.packageBackingTask == nil)
        let deferredGeneration = view.preparationGeneration

        session.recordRuntimeError(.networkOffline)
        await session.retry()

        #expect(view.preparationGeneration == deferredGeneration + 1)
        #expect(view.completedNavigationGeneration == view.preparationGeneration)
        #expect(view.webView.url?.scheme == FolderURLSchemeHandler.scheme)
        #expect(view.packageBackingTask == nil)
        #expect(session.runtimeError == nil)
        #expect(!view.restartPackageBackingAfterResume)
        #expect(view.mediaPlaybackSuspended)
        #expect(view.reloadScheduler.isSuspended)
        #expect(!session.isPlaying)
    }

    @Test("Ambient session clears its error only after retry readiness")
    func ambientSessionClearsErrorOnlyWhenReady() async {
        let target = RecordingHTMLRetryTarget(result: .failed)
        let session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target
        )
        defer { session.cleanup() }

        for result in [
            WallpaperPreparationResult.failed,
            .timedOut,
            .cancelled,
        ] {
            target.result = result
            session.recordRuntimeError(.networkOffline)

            await session.retry()

            #expect(session.runtimeError == .networkOffline)
        }

        target.result = .ready
        await session.retry()

        #expect(session.runtimeError == nil)
        #expect(target.requestedTimeout == .seconds(5))
    }
}

@MainActor
private final class RecordingHTMLRetryTarget:
    WallpaperPerformanceConfigurable,
    HTMLWallpaperRetrying
{
    var result: WallpaperPreparationResult
    private(set) var requestedTimeout: Duration?

    init(result: WallpaperPreparationResult) {
        self.result = result
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}

    func retryCurrentSource(timeout: Duration) async -> WallpaperPreparationResult {
        requestedTimeout = timeout
        return result
    }
}

@Suite("HTML wallpaper compatibility policy")
struct HTMLWallpaperCompatibilityPolicyTests {
    @Test("DPR-aware Wallpaper Engine folders stay in CSS-point layout")
    func dprAwareWallpaperEngineFolderStaysInCSSPointLayout() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWCompatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("""
        <html>
        <script>
        const renderer = new THREE.WebGLRenderer();
        renderer.setSize(window.innerWidth, window.innerHeight);
        renderer.setPixelRatio(window.devicePixelRatio);
        </script>
        </html>
        """.utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        let bookmark = try folder.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let result = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: .folder(bookmarkData: bookmark, indexFileName: "index.html"),
            config: .default,
            trustedOrigins: Set<TrustedHTMLOrigin>()
        )

        #expect(!result.config.physicalPixelLayout)
        #expect(!result.enabledPhysicalPixelLayout)
    }

    @Test("Wallpaper Engine folders keep physical-pixel layout during hot config updates")
    func wallpaperEngineFolderKeepsPhysicalPixelLayout() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWCompatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        let bookmark = try folder.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var updated = HTMLConfig.default
        updated.customCSS = "html { background: black; }"

        let result = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: .folder(bookmarkData: bookmark, indexFileName: "index.html"),
            config: updated,
            trustedOrigins: Set<TrustedHTMLOrigin>()
        )

        #expect(result.config.physicalPixelLayout)
        #expect(result.enabledPhysicalPixelLayout)
        #expect(result.config.customCSS == updated.customCSS)
    }
}

private final class FakeURLSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var _receivedResponse: URLResponse?
    private var _receivedData: [Data] = []
    private var _didFinishCalled = false
    private var _failedError: Error?

    init(request: URLRequest) {
        self.request = request
    }

    var receivedResponse: URLResponse? {
        lock.lock(); defer { lock.unlock() }
        return _receivedResponse
    }

    var totalReceivedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _receivedData.reduce(0) { $0 + $1.count }
    }

    var didFinishCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFinishCalled
    }

    var failedError: Error? {
        lock.lock(); defer { lock.unlock() }
        return _failedError
    }

    func didReceive(_ response: URLResponse) {
        lock.lock(); defer { lock.unlock() }
        _receivedResponse = response
    }

    func didReceive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        _receivedData.append(data)
    }

    func didFinish() {
        lock.lock(); defer { lock.unlock() }
        _didFinishCalled = true
    }

    func didFailWithError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _failedError = error
    }
}
