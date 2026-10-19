#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import os
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct WPEUserShortcutBridgeTests {
    private final class LaunchLog: Sendable {
        private let values = OSAllocatedUnfairLock(initialState: [UInt64]())
        var revisions: [UInt64] {
            values.withLock { $0 }
        }

        func record(_ revision: UInt64) {
            values.withLock { $0.append(revision) }
        }
    }

    @Test("Binding changes are drained once and launches use the current revision")
    func hostBindingsAndLaunchRevision() {
        let bridge = WPEUserShortcutScriptBridge()
        let log = LaunchLog()
        bridge.setLauncher { _, revision in log.record(revision) }
        #expect(!bridge.requestLaunch("k"))
        bridge.setBindings(declared: ["k"], bound: ["k": .init(commandType: "web", displayName: "Example", revision: 7)])
        #expect(bridge.snapshot().declared == ["k"])
        #expect(bridge.takeChangedKeys() == ["k"])
        #expect(bridge.takeChangedKeys().isEmpty)
        #expect(bridge.requestLaunch("k"))
        bridge.setBindings(declared: ["k"], bound: ["k": .init(commandType: "web", displayName: "Example", revision: 8)])
        #expect(bridge.requestLaunch("k"))
        bridge.setBindings(declared: ["k"], bound: [:])
        #expect(bridge.takeChangedKeys() == ["k"])
        #expect(!bridge.requestLaunch("k"))
        #expect(log.revisions == [7, 8])
    }

    @Test("The bounded parity VM permits one shortcut per press, including an unbound shortcut",
          arguments: [false, true])
    func parityCursorQuota(bound: Bool) throws {
        let bridge = WPEUserShortcutScriptBridge()
        let log = LaunchLog()
        bridge.setBindings(declared: ["k"], bound: bound
            ? ["k": .init(commandType: "web", displayName: "Example", revision: 1)] : [:])
        bridge.setLauncher { _, revision in log.record(revision) }
        let script = """
        export function init(value) { shared.accepted = 0; shared.denied = 0; return value; }
        function attempt() {
            try { shared.accepted += engine.openUserShortcut('k') ? 1 : 0.5; }
            catch (error) {
                if (!(error instanceof SyntaxError)) throw error;
                shared.denied += 1;
            }
        }
        export function cursorDown() { attempt(); }
        export function cursorUp() { attempt(); }
        export function cursorClick() { attempt(); }
        export function update(value) { return new Vec3(shared.accepted, shared.denied, 0); }
        """
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [["id": 1, "solid": true, "origin": ["value": "0 0 0", "script": script]]],
        ]))
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js")
            .standardizedFileURL
        let bytes = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? bytes : nil
        }])
        let engine = try WPEParityScriptEngine.prepare(document: document, state: &state, configuration: .init(
            assets: assets, canvasSize: SIMD2(100, 100), screenResolution: SIMD2(100, 100),
            openUserShortcut: { bridge.requestLaunch($0) }
        ), volume: { _, _ in }, command: { _, _, _ in false })
        try engine.start(state: &state)
        var tracker = WPEParityCursorTracker()
        let targets = [WPEParityCursorTarget(id: "1", quad: (.zero, SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)))]
        for _ in 0 ..< 2 {
            for down in [true, false] {
                let events = tracker.update(targets: targets, cursor: SIMD2(5, 5), leftDown: down, moved: false)
                engine.cursor(events, input: .init(leftDown: down), state: &state)
            }
        }
        engine.tick(dt: 0, state: &state)
        #expect(state.object("1")?.origin == SIMD3(bound ? 2 : 1, 4, 0))
        #expect(log.revisions == (bound ? [1, 1] : []))
        #expect(engine.exceptionCount == 0)
    }

    @Test("The parity VM rejects shortcut calls without a press")
    func parityRejectsCallsOutsidePress() throws {
        // Exercise the same binding through update, where no cursor press has opened the permit.
        let script = """
        export function update(value) {
            try { engine.openUserShortcut('k'); return new Vec3(99, 0, 0); }
            catch (error) { return new Vec3(error instanceof SyntaxError ? 1 : 2, 0, 0); }
        }
        """
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [["id": 1, "solid": true, "origin": ["value": "0 0 0", "script": script]]],
        ]))
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js")
            .standardizedFileURL
        let bytes = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? bytes : nil
        }])
        let log = LaunchLog()
        let engine = try WPEParityScriptEngine.prepare(document: document, state: &state, configuration: .init(
            assets: assets, canvasSize: SIMD2(100, 100), screenResolution: SIMD2(100, 100),
            openUserShortcut: { _ in log.record(1); return true }
        ), volume: { _, _ in }, command: { _, _, _ in false })
        try engine.start(state: &state)
        engine.tick(dt: 0, state: &state)
        #expect(state.object("1")?.origin == SIMD3(1, 0, 0))
        #expect(log.revisions.isEmpty)
        #expect(engine.exceptionCount == 0)
    }
}
#endif
