import AppKit
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@Suite("Pointer press is matched against this frame's hover state")
struct PointerEventOrderTests {
    /// Slice to renderCurrentFrame's own body: a whole-file search finds both calls
    /// and passes even when the button call executes earlier from inside a helper.
    private func renderCurrentFrameBody() throws -> Substring {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let start = try #require(source.range(of: "func renderCurrentFrame("))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ")
        return end.map { rest[..<$0.lowerBound] } ?? rest
    }

    @Test("Button edges are dispatched after hover hit-testing, not before")
    func buttonEdgesFollowHoverHitTesting() throws {
        let body = try renderCurrentFrameBody()
        let hover = try #require(
            body.range(of: "dispatchLayerHoverEvents("),
            "renderCurrentFrame no longer hit-tests hover; this contract is meaningless"
        )
        let buttons = try #require(
            body.range(of: "dispatchPointerButtonEdges("),
            "renderCurrentFrame does not dispatch button edges, so they run from somewhere earlier"
        )
        #expect(
            hover.upperBound < buttons.lowerBound,
            "button edges are dispatched before hover state is refreshed, so a press in the same frame as a move is attributed to the previous frame's layer"
        )
    }

    @Test("The button dispatch does not live inside the layer-script tick helper")
    func buttonDispatchIsNotNestedInTheTickHelper() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let helper = try #require(source.range(of: "private func tickLayerPresentationScripts("))
        let buttons = try #require(source.range(of: "dispatchPointerButtonEdges("))
        #expect(
            buttons.lowerBound < helper.lowerBound,
            "dispatchPointerButtonEdges is nested in tickLayerPresentationScripts again; that helper runs before hover hit-testing"
        )
    }
}

#if !LITE_BUILD
@MainActor
@Suite("Pointer button edge delivery")
struct WPEPointerEdgeDeliveryTests {
    private static let buttonEdgeScript = """
    export function init() { shared.events = ''; }
    export function update(value) { return value; }
    export function cursorDown() { shared.events += 'd'; }
    export function cursorUp() { shared.events += 'u'; }
    // Workshop 3809609151 ignores non-left clicks via `event.button !== 0`;
    // a missing field reads as undefined and fails this check.
    export function cursorClick(event) {
        if (event.button !== 0) { shared.events += '?'; return; }
        shared.events += 'c';
    }
    export function cursorRightDown() { shared.events += 'r'; }
    export function cursorRightUp() { shared.events += 'R'; }
    """

    private func fixture(
        script: String = Self.buttonEdgeScript,
        property: String = "visible",
        value: Any = true
    ) throws -> MetalSceneFixture {
        let fixture = try MetalSceneFixture.solidColorScene()
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["origin"] = "32 32 0"
        objects[0]["size"] = "32 32"
        objects[0][property] = ["value": value, "script": script]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        return fixture
    }

    private func event(_ type: NSEvent.EventType, point: CGPoint = CGPoint(x: 32, y: 32)) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    private func waitForEvents(_ expected: String, renderer: WPEMetalSceneRenderer) async throws {
        for _ in 0 ..< 100 {
            if renderer.sharedScriptValueForTesting("events") as? String == expected {
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
            // Keep the normal render loop advancing while the asynchronous event batch drains, without resending edges.
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        }
        #expect(renderer.sharedScriptValueForTesting("events") as? String == expected)
    }

    @Test("A full down/up between frame samples reaches authored SceneScript in order")
    func rapidClickBetweenFramesReachesScript() async throws {
        let scene = try fixture()
        defer { scene.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        #expect(view.clickCaptureEnabled)
        try view.mouseDown(with: event(.leftMouseDown))
        #expect(view.pointerIsInsideView)
        #expect(renderer.makeFrameInputs().pointerFrame.isDown)
        try view.mouseUp(with: event(.leftMouseUp))
        #expect(renderer.makeFrameInputs().pointerFrame.isDown == false)
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("duc", renderer: renderer)
    }

    @Test("cursorClick on a transform-property script reaches the authored handler", arguments: ["angles", "parallaxDepth"])
    func transformPropertyScriptReceivesCursorEvents(property: String) async throws {
        // Workshop 3809609151 attaches click-to-switch handlers to `angles`
        // scripts; routing once skipped every transform-property script family.
        let scene = try fixture(
            script: Self.buttonEdgeScript,
            property: property,
            value: "0 0 0"
        )
        defer { scene.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        try view.mouseDown(with: event(.leftMouseDown))
        try view.mouseUp(with: event(.leftMouseUp))
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("duc", renderer: renderer)
        #expect(renderer.frameDemand.contains(.scripts))
    }

    @Test("A media event refused while the VM is busy reaches the script on the next frame without a new player notification")
    func refusedMediaEventRetriesOnNextFrame() async throws {
        let scene = try fixture(script: """
        export function init() { shared.events = ''; shared.go = false; }
        export function update(value) { return value; }
        export function cursorDown() { shared.events += 'd'; for (let i = 0; i < 5000000 && !shared.go; i++) {} }
        export function cursorUp() { shared.events += 'u'; }
        export function cursorClick() { shared.events += 'c'; }
        export function mediaPlaybackChanged() { shared.events += 'p'; }
        """)
        defer { scene.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        let mailbox = WPESceneMediaEventMailbox()
        renderer.mediaEventMailbox = mailbox
        // load() already delivers the player's current playback state once; start the log after it.
        renderer.sceneScriptSharedState?.set("events", "")
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        try view.mouseDown(with: event(.leftMouseDown))
        try view.mouseUp(with: event(.leftMouseUp))
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        for _ in 0 ..< 1000 where renderer.sharedScriptValueForTesting("events") as? String != "d" {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        mailbox.post([.playbackChanged(.playing)])
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        renderer.sceneScriptSharedState?.set("go", true)
        for _ in 0 ..< 1000 where renderer.sharedScriptValueForTesting("events") as? String != "duc" {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        for _ in 0 ..< 500 where renderer.sharedScriptValueForTesting("events") as? String != "ducp" {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(renderer.sharedScriptValueForTesting("events") as? String == "ducp",
                "the playback event refused while cursorDown held the VM was dropped instead of retried on the next frame")
    }

    private func pointer(_ down: Bool, x: Double = 0.5) -> WPEPointerFrame {
        WPEPointerFrame(position: SIMD2(x, 0.5), clickPosition: SIMD2(x, 0.5),
                        isDown: down, isRightDown: false)
    }

    @Test("Hidden childless compose hit regions receive clicks with Follow Cursor on or off", arguments: [true, false])
    func hiddenComposeRegionReceivesClick(followCursor: Bool) async throws {
        let scene = try MetalSceneFixture.solidColorScene()
        defer { scene.cleanup() }
        for directory in ["models/util", "materials/util"] {
            try FileManager.default.createDirectory(at: scene.root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data(#"{"material":"materials/util/composelayer.json"}"#.utf8)
            .write(to: scene.root.appendingPathComponent("models/util/composelayer.json"))
        try Data(#"{"passes":[{"shader":"compose","textures":["_rt_FullFrameBuffer"]}]}"#.utf8)
            .write(to: scene.root.appendingPathComponent("materials/util/composelayer.json"))
        let path = scene.root.appendingPathComponent("scene.json")
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(payload["objects"] as? [[String: Any]])
        objects.append([
            "id": "hit", "name": "Hidden Click Zone", "image": "models/util/composelayer.json",
            "origin": "32 32 0", "size": "32 32",
            "visible": ["value": false, "script": Self.buttonEdgeScript],
        ])
        payload["objects"] = objects
        try JSONSerialization.data(withJSONObject: payload).write(to: path)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        renderer.setMouseInteractionEnabled(followCursor)
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        let region = try #require(renderer.renderPipeline?.layers.first { $0.id == "hit" })
        #expect(!region.graphLayer.visible)
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        try view.mouseDown(with: event(.leftMouseDown))
        try view.mouseUp(with: event(.leftMouseUp))
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("duc", renderer: renderer)
        #expect(renderer.liveLayerVisibility["hit"] == false)
    }

    @Test("Dragging outside the pressed layer still delivers cursorMove without Follow Cursor", arguments: [true, false])
    func dragRetainsMovesOutsideLayer(followCursor: Bool) async throws {
        let scene = try fixture(script: """
        export function init() { shared.dragX = 0; shared.released = false; }
        export function cursorMove(event) { if (event.leftDown) shared.dragX = event.worldPosition.x; }
        export function cursorUp() { shared.released = true; }
        """)
        defer { scene.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        renderer.setMouseInteractionEnabled(followCursor)
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        func render(_ down: Bool, x: Double) throws {
            _ = try renderer.renderCurrentFrame(inputs: WPEFrameInputs(
                clickCaptureEnabled: true, pointerSample: .inside(SIMD2(x, 0.5)),
                pointerFrame: pointer(down, x: x), preferredFramesPerSecond: 30
            ))
        }
        try render(true, x: 0.5)
        try await Task.sleep(for: .milliseconds(20))
        // x=0.9 is beyond the 32-pixel layer's right edge (UV 0.75).
        try render(true, x: 0.9)
        for _ in 0 ..< 100 where renderer.sharedScriptValueForTesting("dragX") as? Double != 57.6 {
            try await Task.sleep(for: .milliseconds(2))
            try render(true, x: 0.9)
        }
        #expect(renderer.sharedScriptValueForTesting("dragX") as? Double == 57.6)
        try render(false, x: 0.9)
        for _ in 0 ..< 100 where renderer.sharedScriptValueForTesting("released") as? Bool != true {
            try await Task.sleep(for: .milliseconds(2))
            try render(false, x: 0.9)
        }
        #expect(renderer.sharedScriptValueForTesting("released") as? Bool == true)
    }

    @Test("Every property script on a layer receives its hover transition")
    func hoverTransitionReachesEveryPropertyScript() async throws {
        let scene = try fixture()
        defer { scene.cleanup() }
        let path = scene.root.appendingPathComponent("scene.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(json["objects"] as? [[String: Any]])
        objects[0]["angles"] = ["value": "0 0 0", "script": "export function update(value) { return value; }"]
        json["objects"] = objects
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        let pipeline = try #require(renderer.renderPipeline)
        renderer.layerHoverStates = [:]
        var entering = 0
        renderer.dispatchLayerHoverEvents(pointer: SIMD2(0.5, 0.5), pipeline: pipeline,
                                          pointerFrame: pointer(false)) { _, events, _ in
            if events.contains(.enter) {
                entering += 1
            }
        }
        #expect(entering == 2)
        var leaving = 0
        renderer.dispatchLayerHoverEvents(pointer: nil, pipeline: pipeline,
                                          pointerFrame: pointer(false)) { _, events, _ in
            if events.contains(.leave) {
                leaving += 1
            }
        }
        #expect(leaving == 2)
    }

    private func invocation(_ event: WPELayerScriptCursorEvent, down: Bool,
                            x: Double = 0.5) -> WPELayerScriptCursorInvocation {
        .init(event: event, pointerFrame: pointer(down, x: x), runtimeSeconds: 2)
    }

    @Test("Peeking/high-water snapshots cannot consume future button edges")
    func mailboxHighWaterIsNonconsuming() {
        let mailbox = WPEPointerMailbox()
        mailbox.setClickCaptureEnabled(true)
        mailbox.publishPointerFrame(pointer(true, x: 0.2))
        let first = mailbox.read()
        #expect(mailbox.read().buttonCursor == first.buttonCursor)
        mailbox.publishPointerFrame(pointer(false, x: 0.7))
        let second = mailbox.read()
        let down = mailbox.takeButtonEvents(through: first.buttonCursor)
        #expect(down.edges.map(\.frame) == [pointer(true, x: 0.2)])
        #expect(mailbox.takeButtonEvents(through: first.buttonCursor).edges.isEmpty)
        #expect(mailbox.takeButtonEvents(through: second.buttonCursor).edges.map(\.frame)
            == [pointer(false, x: 0.7)])
    }

    @Test("A paused/stalled overflow cancels the whole press until both buttons release")
    func mailboxOverflowAndReloadResynchronize() {
        let mailbox = WPEPointerMailbox()
        mailbox.setClickCaptureEnabled(true)
        for _ in 0 ..< 128 {
            mailbox.publishPointerFrame(pointer(true))
            mailbox.publishPointerFrame(pointer(false))
        }
        let old = mailbox.read()
        mailbox.publishPointerFrame(pointer(true)) // 257th edge overflows: discard, never a half-press.
        #expect(mailbox.read().buttonsSuppressed)
        #expect(mailbox.takeButtonEvents(through: old.buttonCursor).edges.isEmpty)
        #expect(mailbox.takeButtonEvents(through: mailbox.read().buttonCursor).cancelled)
        mailbox.publishPointerFrame(pointer(false))
        #expect(!mailbox.read().buttonsSuppressed)
        mailbox.publishPointerFrame(pointer(true))
        mailbox.publishPointerFrame(pointer(false))
        let beforeReload = mailbox.read()
        mailbox.resetButtonEvents()
        mailbox.publishPointerFrame(pointer(true, x: 0.3))
        #expect(mailbox.takeButtonEvents(through: beforeReload.buttonCursor).edges.isEmpty)
        #expect(mailbox.takeButtonEvents(through: mailbox.read().buttonCursor).edges.count == 1)
        mailbox.setClickCaptureEnabled(false)
        mailbox.setClickCaptureEnabled(true)
        #expect(mailbox.read().buttonsSuppressed)
        mailbox.publishPointerFrame(pointer(false))
        #expect(mailbox.takeButtonEvents(through: mailbox.read().buttonCursor).edges.isEmpty)
    }

    @Test("Inbox admission retains whole bursts and cancellation fences old queued claims")
    func inboxClaimCancellationAndOverflow() throws {
        let inbox = WPELayerScriptCursorInbox(capacity: 3)
        inbox.append([invocation(.down, down: true)])
        let old = try #require(inbox.claim())
        inbox.append([invocation(.up, down: false), invocation(.click, down: false)])
        #expect(inbox.claim() == nil)
        inbox.cancel()
        #expect(inbox.take(old) == nil)
        inbox.complete(old)
        let cancelled = try #require(inbox.claim())
        #expect(try #require(inbox.take(cancelled)).isEmpty)
        inbox.complete(cancelled)
        let delivered = invocation(.down, down: true)
        inbox.didDeliver(delivered)
        inbox.append([delivered, invocation(.move, down: true), invocation(.move, down: true)])
        inbox.append([invocation(.up, down: false)]) // Overflow invalidates all pending input.
        let overflow = try #require(inbox.claim())
        #expect(try #require(inbox.take(overflow)).map(\.event) == [.up])
        inbox.complete(overflow)
        inbox.append([invocation(.up, down: false), invocation(.click, down: false)])
        #expect(inbox.claim() == nil)
        inbox.append([delivered, invocation(.up, down: false), invocation(.click, down: false)])
        let fresh = try #require(inbox.claim())
        #expect(try #require(inbox.take(fresh)).map(\.event) == [.down, .up, .click])
        inbox.close()
        #expect(!inbox.isCurrent(fresh))
        #expect(inbox.claim() == nil)
    }

    @Test("A blocked VM worker retains bursts and callbacks keep their own pointer coordinates")
    func stalledWorkerReceivesPerEventFrames() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let shared = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
                                                  export function init() { shared.events = ''; }
                                                  export function cursorDown(e) { shared.events += 'd' + input.cursorScreenPosition.x + ':' + e.leftDown + ';'; }
                                                  export function cursorUp(e) { shared.events += 'u' + input.cursorScreenPosition.x + ':' + e.leftDown + ';'; }
                                                  export function cursorClick() { shared.events += 'c;'; }
                                                  """, shared: shared, canvasSize: SIMD2(100, 100),
                                                  governor: WPESceneScriptExecutionGovernor(limit: 1), batchDispatcher: dispatcher)
        defer { _ = instance.destroy() }
        let held = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        defer { held.signal() }
        let lane = dispatcher.reserveLane()
        lane.queue.async { started.signal(); _ = held.wait(timeout: .now() + 2) }
        #expect(started.wait(timeout: .now() + 1) == .success)
        let first = try #require(instance.batchCursorEvents([invocation(.down, down: true, x: 0.2)]))
        let completion = try #require(dispatcher.submit([first], trackingCompletion: true))
        #expect(instance.batchCursorEvents([
            invocation(.up, down: false, x: 0.7), invocation(.click, down: false, x: 0.7),
        ]) == nil)
        #expect(shared.get("events") as? String == "")
        held.signal()
        #expect(completion.wait(timeout: .now() + 1))
        #expect(shared.get("events") as? String == "d20:true;u70:false;c;")
        #expect(instance.batchCursorEvents([]) == nil)
    }

    @Test("A burst queued while the previous VM batch is still running is delivered without another frame")
    func burstQueuedDuringRunningBatchIsDelivered() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let shared = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
        export function init() { shared.events = ''; shared.go = false; }
        export function cursorDown() { shared.events += 'd'; for (let i = 0; i < 5000000 && !shared.go; i++) {} }
        export function cursorUp() { shared.events += 'u'; }
        export function cursorClick() { shared.events += 'c'; }
        """, shared: shared, governor: WPESceneScriptExecutionGovernor(limit: 1), batchDispatcher: dispatcher)
        defer { _ = instance.destroy() }
        let lane = dispatcher.reserveLane()
        let first = try #require(instance.batchCursorEvents([invocation(.down, down: true)]))
        let completion = try #require(dispatcher.submit([first], trackingCompletion: true))
        // `shared` reads go through the host store, so 'd' means the batch has taken its burst and is inside cursorDown.
        let deadline = Date().addingTimeInterval(2)
        while shared.get("events") as? String != "d", Date() < deadline {
            usleep(1000)
        }
        #expect(shared.get("events") as? String == "d")
        #expect(instance.batchCursorEvents([invocation(.up, down: false), invocation(.click, down: false)]) == nil)
        shared.set("go", true)
        #expect(completion.wait(timeout: .now() + 2))
        lane.queue.sync {}
        #expect(shared.get("events") as? String == "duc")
    }

    @Test("A cancel that lands while a press is being delivered releases it without another frame")
    func cancelDuringRunningPressReleasesIt() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let shared = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
        export function init() { shared.events = ''; shared.go = false; }
        export function cursorDown() { shared.events += 'd'; for (let i = 0; i < 5000000 && !shared.go; i++) {} }
        export function cursorUp() { shared.events += 'u'; }
        export function cursorClick() { shared.events += 'c'; }
        """, shared: shared, governor: WPESceneScriptExecutionGovernor(limit: 1), batchDispatcher: dispatcher)
        defer { _ = instance.destroy() }
        let first = try #require(instance.batchCursorEvents([invocation(.down, down: true)]))
        let completion = try #require(dispatcher.submit([first], trackingCompletion: true))
        let pressDeadline = Date().addingTimeInterval(2)
        while shared.get("events") as? String != "d", Date() < pressDeadline {
            usleep(1000)
        }
        instance.cancelPendingCursorEvents()
        #expect(instance.batchCursorEvents([]) == nil)
        shared.set("go", true)
        #expect(completion.wait(timeout: .now() + 2))
        let deadline = Date().addingTimeInterval(1)
        while shared.get("events") as? String != "du", Date() < deadline {
            usleep(1000)
        }
        #expect(shared.get("events") as? String == "du")
    }

    @Test("Safety admission failure retries the whole burst on the VM queue without another frame")
    func busySafetyRetriesWholeBurst() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let shared = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
        export function init() { shared.events = ''; }
        export function cursorDown() { shared.events += 'd'; }
        export function cursorUp() { shared.events += 'u'; }
        export function cursorClick() { shared.events += 'c'; }
        export function mediaPlaybackChanged() {}
        """, shared: shared, governor: WPESceneScriptExecutionGovernor(limit: 1), batchDispatcher: dispatcher)
        defer { _ = instance.destroy() }
        let held = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        defer { held.signal() }
        let lane = dispatcher.reserveLane()
        lane.queue.async { started.signal(); _ = held.wait(timeout: .now() + 2) }
        #expect(started.wait(timeout: .now() + 1) == .success)
        let job = try #require(instance.batchCursorEvents([
            invocation(.down, down: true), invocation(.up, down: false), invocation(.click, down: false),
        ]))
        let completion = try #require(dispatcher.submit([job], trackingCompletion: true))
        // The media entry point reserves safety before the worker; its event
        // runs AFTER our queued batch and deliberately makes that admission busy.
        instance.liveDispatchMediaEvents([.playbackChanged(.playing)])
        held.signal()
        #expect(completion.wait(timeout: .now() + 1))
        let deadline = Date().addingTimeInterval(1)
        while shared.get("events") as? String != "duc", Date() < deadline {
            usleep(1000)
        }
        #expect(shared.get("events") as? String == "duc")
        #expect(instance.batchCursorEvents([]) == nil)
    }

    @Test("Release outside the view ends the press without synthesizing click")
    func releaseOutsideDoesNotClick() async throws {
        let scene = try fixture()
        defer { scene.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        try view.mouseDown(with: event(.leftMouseDown))
        try view.mouseUp(with: event(.leftMouseUp, point: CGPoint(x: -10, y: 32)))
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("du", renderer: renderer)
    }

    @Test("Disable/reload drops old clicks and a fresh click reaches the replacement scene")
    func disableAndReloadDiscardOldClicks() async throws {
        let scene = try fixture()
        defer { scene.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        try view.mouseDown(with: event(.leftMouseDown))
        let stale = renderer.makeFrameInputs()
        #expect(stale.pointerFrame.isDown)
        try view.mouseUp(with: event(.leftMouseUp))
        renderer.setClickCaptureEnabled(false)
        renderer.setClickCaptureEnabled(true)
        #expect(!renderer.sampleFrameContext(inputs: stale).layerScriptPointerFrame.isDown)
        _ = try renderer.renderCurrentFrame(inputs: stale)
        try await waitForEvents("", renderer: renderer)
        try view.mouseDown(with: event(.leftMouseDown))
        try view.mouseUp(with: event(.leftMouseUp))
        try await renderer.reload()
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("", renderer: renderer)
        try view.mouseDown(with: event(.leftMouseDown))
        try view.mouseUp(with: event(.leftMouseUp))
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("duc", renderer: renderer)
    }

    @Test("Cancelling an already queued VM burst prevents old-generation callbacks")
    func cancelledWorkerBurstCannotPublish() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let shared = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
        export function init() { shared.events = ''; }
        export function cursorDown() { shared.events += 'd'; }
        export function cursorUp() { shared.events += 'u'; }
        export function cursorClick() { shared.events += 'c'; }
        """, shared: shared, governor: WPESceneScriptExecutionGovernor(limit: 1), batchDispatcher: dispatcher)
        defer { _ = instance.destroy() }
        let held = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        defer { held.signal() }
        let lane = dispatcher.reserveLane()
        lane.queue.async { started.signal(); _ = held.wait(timeout: .now() + 2) }
        #expect(started.wait(timeout: .now() + 1) == .success)
        let job = try #require(instance.batchCursorEvents([
            invocation(.down, down: true), invocation(.up, down: false), invocation(.click, down: false),
        ]))
        let completion = try #require(dispatcher.submit([job], trackingCompletion: true))
        instance.cancelPendingCursorEvents()
        held.signal()
        #expect(completion.wait(timeout: .now() + 1))
        lane.queue.sync {}
        #expect(shared.get("events") as? String == "")
        let fresh = try #require(instance.batchCursorEvents([
            invocation(.down, down: true), invocation(.up, down: false), invocation(.click, down: false),
        ]))
        let freshCompletion = try #require(dispatcher.submit([fresh], trackingCompletion: true))
        #expect(freshCompletion.wait(timeout: .now() + 1))
        #expect(shared.get("events") as? String == "duc")
    }

    @Test("Overflow ending with all buttons released accepts the first new press")
    func overflowNeutralTailAcceptsFreshPress() throws {
        let inbox = WPELayerScriptCursorInbox(capacity: 3)
        inbox.append([invocation(.down, down: true), invocation(.move, down: true), invocation(.move, down: true)])
        // This whole discarded burst ends neutral; no separate update() or
        // extra release callback is needed to observe the released state.
        inbox.append([invocation(.up, down: false), invocation(.click, down: false)])
        let cancel = try #require(inbox.claim())
        #expect(try #require(inbox.take(cancel)).isEmpty)
        inbox.complete(cancel)
        inbox.append([invocation(.down, down: true), invocation(.up, down: false), invocation(.click, down: false)])
        let fresh = try #require(inbox.claim())
        #expect(try #require(inbox.take(fresh)).map(\.event) == [.down, .up, .click])
    }

    @Test("Right down/up between samples reaches authored callbacks exactly once")
    func rapidRightClickBetweenFrames() async throws {
        let scene = try fixture()
        defer { scene.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: scene.descriptor, cacheRootURL: scene.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        defer { renderer.cleanup() }
        renderer.setClickCaptureEnabled(true)
        try await renderer.load()
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        try view.rightMouseDown(with: event(.rightMouseDown))
        try view.rightMouseUp(with: event(.rightMouseUp))
        #expect(!renderer.makeFrameInputs().pointerFrame.isRightDown)
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("rR", renderer: renderer)
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        try await waitForEvents("rR", renderer: renderer)
    }

    @Test("Queued button edges preserve span interaction masks at their own event location")
    func queuedEdgesKeepInteractionMask() {
        let mailbox = WPEPointerMailbox()
        mailbox.publishGeometry(.init(viewFrameInScreen: CGRect(x: 100, y: 200, width: 100, height: 100),
                                      interactiveFrames: [CGRect(x: 100, y: 200, width: 40, height: 100)]))
        mailbox.setClickCaptureEnabled(true)
        // Latest global follow sample is deliberately opposite to the event.
        mailbox.publishMouseLocation(CGPoint(x: 110, y: 250), timestampNanos: 1)
        mailbox.publishPointerFrame(pointer(true, x: 0.75))
        mailbox.publishPointerFrame(pointer(false, x: 0.2))
        let edges = mailbox.takeButtonEvents(through: mailbox.read().buttonCursor).edges
        #expect(edges.map(\.isInsideView) == [false, true])
    }

    @Test("Background click-control publication is immediate and main view receives latest flag")
    func surfaceClickControlUsesLatestMailboxFlag() async throws {
        let surface = try WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 16, height: 16),
                                           device: #require(MTLCreateSystemDefaultDevice()))
        surface.mtkView.clickCaptureEnabled = true
        // A bounded synchronous fixture holds main delivery while the writer
        // publishes both values; the following async wait then admits delivery.
        #expect(publishClickFlagsWhileMainIsHeld(surface))
        #expect(!surface.mailbox.read().clickCaptureEnabled)
        for _ in 0 ..< 100 {
            if !surface.mtkView.clickCaptureEnabled {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(!surface.mtkView.clickCaptureEnabled)
        #expect(!surface.mailbox.read().clickCaptureEnabled)
    }

    private func publishClickFlagsWhileMainIsHeld(_ surface: WPERenderSurface) -> Bool {
        let published = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            surface.setClickCaptureEnabled(true)
            surface.setClickCaptureEnabled(false)
            published.signal()
        }
        return published.wait(timeout: .now() + 1) == .success
    }
}
#endif
