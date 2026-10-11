#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import os
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WPEUserShortcutBridgeTests {
    private static let outsideMessage = "Cannot execute user command outside of cursor callbacks."
    private static let perClickMessage = "Cannot execute more than one user command per cursor click."

    private let governor = WPESceneScriptExecutionGovernor(limit: 4)

    private final class LaunchLog: Sendable {
        private let keys = OSAllocatedUnfairLock(initialState: [String]())
        var launched: [String] {
            keys.withLock { $0 }
        }

        func record(_ key: String) {
            keys.withLock { $0.append(key) }
        }
    }

    private static let attemptScript = """
    export function init() { shared.log = ''; }
    function attempt(tag) {
        try { shared.log += tag + ':' + engine.openUserShortcut('k') + ';'; }
        catch (e) { shared.log += tag + ':' + e.name + ':' + e.message + ';'; }
    }
    export function cursorDown() { attempt('d'); }
    export function cursorUp() { attempt('u'); }
    export function cursorClick() { attempt('c'); }
    """

    private static func run(_ job: WPESceneScriptBatchDispatcher.Job?) -> Bool {
        guard let job else { return false }
        return WPESceneScriptBatchDispatcher.processShared
            .submit([job], trackingCompletion: true)?
            .wait(timeout: .now() + 5) == true
    }

    private func makeShared(bound: Bool) -> (WPESharedScriptState, LaunchLog) {
        let bridge = WPEUserShortcutScriptBridge()
        let log = LaunchLog()
        bridge.setBindings(
            declared: ["k"],
            bound: bound ? ["k": .init(commandType: "web", displayName: "Example")] : [:]
        )
        bridge.setLauncher { log.record($0) }
        return (WPESharedScriptState(userShortcuts: bridge), log)
    }

    private func frame(_ gesture: UInt64, down: Bool = false) -> WPEPointerFrame {
        var frame = WPEPointerFrame.neutral
        frame.isDown = down
        frame.gesture = gesture
        return frame
    }

    private func layer(_ script: String, shared: WPESharedScriptState) throws -> WPELayerScriptInstance {
        try WPELayerScriptInstance(script: script, shared: shared, setupBudget: 2, tickBudget: 0.5, governor: governor)
    }

    private func transform(_ script: String, shared: WPESharedScriptState) throws -> WPEDynamicTransformScriptInstance {
        try WPEDynamicTransformScriptInstance(
            script: script, seed: .zero, canvasSize: SIMD2(100, 100), shared: shared,
            setupBudget: 2, tickBudget: 0.5, governor: governor
        )
    }

    private func send(_ layer: WPELayerScriptInstance, _ event: WPELayerScriptCursorEvent, _ frame: WPEPointerFrame) {
        _ = layer.dispatchCursorEvent(event, pointerFrame: frame, runtimeSeconds: 1)
    }

    private func send(_ transform: WPEDynamicTransformScriptInstance,
                      _ event: WPELayerScriptCursorEvent, _ frame: WPEPointerFrame) -> Bool {
        Self.run(transform.enqueueCursorEvents([.init(event: event, pointerFrame: frame, runtimeSeconds: 1)]))
    }

    @Test("Calling outside a cursor callback throws the WPE SyntaxError")
    func outsideCursorCallbackThrows() throws {
        let (shared, log) = makeShared(bound: true)
        let instance = try layer("""
        export function update() {
            try { engine.openUserShortcut('k'); shared.outcome = 'returned'; }
            catch (e) { shared.outcome = e.name + ':' + e.message + ':' + (e instanceof SyntaxError); }
        }
        """, shared: shared)
        _ = instance.tick(runtimeSeconds: 1)
        #expect(shared.get("outcome") as? String == "SyntaxError:\(Self.outsideMessage):true")
        #expect(log.launched.isEmpty)
    }

    @Test("Unbound: the first call returns false and a second call in the same gesture throws")
    func unboundReturnsFalseThenQuotaThrows() throws {
        let (shared, log) = makeShared(bound: false)
        let instance = try layer(Self.attemptScript, shared: shared)
        send(instance, .click, frame(WPEPointerGesture.next()))
        #expect(shared.get("log") as? String == "c:false;")
        shared.set("log", "")
        let gesture = WPEPointerGesture.next()
        send(instance, .up, frame(gesture))
        send(instance, .click, frame(gesture))
        #expect(shared.get("log") as? String == "u:false;c:SyntaxError:\(Self.perClickMessage);")
        #expect(log.launched.isEmpty)
    }

    @Test("Bound: down, up and click of one gesture launch exactly once")
    func boundLaunchesOncePerGesture() throws {
        let (shared, log) = makeShared(bound: true)
        let instance = try layer(Self.attemptScript, shared: shared)
        let gesture = WPEPointerGesture.next()
        send(instance, .down, frame(gesture, down: true))
        send(instance, .up, frame(gesture))
        send(instance, .click, frame(gesture))
        let quota = "SyntaxError:\(Self.perClickMessage)"
        #expect(shared.get("log") as? String == "d:true;u:\(quota);c:\(quota);")
        #expect(log.launched == ["k"])
    }

    @Test("A layer script and a transform script share one quota per gesture")
    func quotaIsSharedAcrossContexts() throws {
        let (shared, log) = makeShared(bound: true)
        let layerInstance = try layer(Self.attemptScript, shared: shared)
        let transformInstance = try transform("""
        export function init(value) { shared.tlog = ''; return value; }
        export function cursorClick() {
            try { shared.tlog += engine.openUserShortcut('k'); }
            catch (e) { shared.tlog += e.message; }
        }
        """, shared: shared)
        defer { _ = transformInstance.destroy() }
        let gesture = WPEPointerGesture.next()
        send(layerInstance, .click, frame(gesture))
        #expect(send(transformInstance, .click, frame(gesture)))
        #expect(shared.get("log") as? String == "c:true;")
        #expect(shared.get("tlog") as? String == Self.perClickMessage)
        #expect(log.launched == ["k"])
    }

    @Test("Two gestures each get their own launch")
    func distinctGesturesLaunchSeparately() throws {
        let (shared, log) = makeShared(bound: true)
        let instance = try layer(Self.attemptScript, shared: shared)
        send(instance, .click, frame(WPEPointerGesture.next()))
        send(instance, .click, frame(WPEPointerGesture.next()))
        #expect(shared.get("log") as? String == "c:true;c:true;")
        #expect(log.launched == ["k", "k"])
    }

    @Test("A release without a gesture number (cancellation) cannot launch")
    func gestureZeroReleaseThrowsOutside() throws {
        let (shared, log) = makeShared(bound: true)
        let instance = try layer(Self.attemptScript, shared: shared)
        send(instance, .up, frame(0))
        #expect(shared.get("log") as? String == "u:SyntaxError:\(Self.outsideMessage);")
        #expect(log.launched.isEmpty)
    }

    @Test("The bridge's own quota error never backs a cursor handler off; a script's own error does",
          arguments: [false, true])
    func quotaErrorIsExemptFromBackoff(useTransform: Bool) throws {
        let (shared, _) = makeShared(bound: false)
        let script = """
        export function init(value) { shared.quota = 0; shared.own = 0; return value; }
        export function cursorClick() {
            if (shared.mode === 'quota') {
                shared.quota += 1;
                engine.openUserShortcut('k');
                engine.openUserShortcut('k');
            } else {
                shared.own += 1;
                engine.openUserShortcut('k');
                try { engine.openUserShortcut('k'); } catch (e) { throw new Error('x'); }
            }
        }
        """
        let rounds = 5
        func dispatchRounds(_ mode: String) throws {
            shared.set("mode", mode)
            if useTransform {
                let instance = try transform(script, shared: shared)
                defer { _ = instance.destroy() }
                for _ in 0 ..< rounds {
                    #expect(send(instance, .click, frame(WPEPointerGesture.next())))
                }
            } else {
                let instance = try layer(script, shared: shared)
                for _ in 0 ..< rounds {
                    send(instance, .click, frame(WPEPointerGesture.next()))
                }
            }
        }
        try dispatchRounds("quota")
        #expect(shared.get("quota") as? Double == Double(rounds))
        try dispatchRounds("own")
        let own = try #require(shared.get("own") as? Double)
        #expect(own < Double(rounds), "a script-raised Error after catching the quota error was not backed off")
    }

    @Test("engine.userProperties exposes declared shortcuts and follows binding changes live")
    func userPropertiesFollowBindings() throws {
        let bridge = WPEUserShortcutScriptBridge()
        bridge.setBindings(declared: ["k"], bound: [:])
        let shared = WPESharedScriptState(userProperties: ["k": .string("plain")], userShortcuts: bridge)
        let instance = try layer("""
        export function init() {
            const p = engine.userProperties.k;
            shared.initial = [typeof p, p.isbound, typeof p.commandtype, typeof p.file].join(',');
        }
        export function update() {
            const p = engine.userProperties.k;
            shared.live = [p.isbound, p.commandtype, p.file].join(',');
        }
        """, shared: shared)
        #expect(shared.get("initial") as? String == "object,false,undefined,undefined")
        bridge.setBindings(declared: ["k"], bound: ["k": .init(commandType: "web", displayName: "Example")])
        _ = instance.tick(runtimeSeconds: 1)
        #expect(shared.get("live") as? String == "true,web,Example")
    }

    @Test("A cancellation-synthesised release carries no gesture number")
    func cancelledReleaseHasNoGesture() throws {
        let inbox = WPELayerScriptCursorInbox()
        inbox.didDeliver(.init(event: .down, pointerFrame: frame(WPEPointerGesture.next(), down: true), runtimeSeconds: 1))
        inbox.cancel()
        let claim = try #require(inbox.claim())
        let events = try #require(inbox.take(claim))
        #expect(events.map(\.event) == [.up])
        #expect(events.first?.pointerFrame.gesture == 0)
    }
}
#endif
