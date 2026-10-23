import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptCursorPassTests: XCTestCase {
    func testEmptyCursorPassStillOpensAndClosesTheUserShortcutGateOnButtonEdges() throws {
        var launches: [String] = []
        let (engine, original) = try engine("""
        let frames = 0;
        export function update(v) {
          frames += 1;
          if (frames >= 2) {
            try { engine.openUserShortcut('k'); } catch (e) {}
          }
          return v;
        }
        """, openUserShortcut: { launches.append($0); return true })
        var state = original
        try engine.start(state: &state)

        engine.cursor([], input: .init(leftDown: true), state: &state)
        XCTAssertEqual(engine.globals[13], 1, "a press with no cursor events left the openUserShortcut gate closed")
        engine.tick(dt: 1 / 60, state: &state)

        engine.cursor([], input: .init(leftDown: false), state: &state)
        XCTAssertEqual(engine.globals[13], 0, "a release with no cursor events left the openUserShortcut gate open")
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(launches, [], "update launched a shortcut after the button was released")

        engine.cursor([], input: .init(leftDown: true), state: &state)
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(launches, ["k"], "update could not launch a shortcut in the frame of a new press")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testCursorPassDeliversItsEventsWithTheCursorPayloadAndAnOpenGate() throws {
        var launches: [String] = []
        let (engine, original) = try engine("""
        export function cursorDown(e) {
          thisLayer.brightness = e.worldPosition.x;
          engine.openUserShortcut('down');
        }
        """, openUserShortcut: { launches.append($0); return true })
        var state = original
        try engine.start(state: &state)

        engine.cursor([.init(event: .cursorDown, id: "1")], input: .init(cursorWorld: SIMD3(0.375, 0, 0), leftDown: true),
                      state: &state)
        XCTAssertEqual(state.object("1")?.brightness, 0.375, "cursorDown did not reach the layer with the cursor's world position")
        XCTAssertEqual(launches, ["down"], "cursorDown on the press saw a closed openUserShortcut gate")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testTickAfterAnEmptyCursorPassReadsNativeWritesFromBeforeAndAfterThePass() throws {
        let (engine, original) = try engine("""
        export function update(v) { return thisLayer.brightness + thisLayer.origin.x; }
        """)
        var state = original
        try engine.start(state: &state)
        engine.tick(dt: 1 / 60, state: &state)

        _ = state.set(.brightness, of: "1", to: SIMD4(0.25, 0, 0, 0))
        engine.cursor([], input: .init(), state: &state)
        _ = state.set(.origin, of: "1", to: SIMD4(0.5, 0, 0, 0))
        engine.tick(dt: 1 / 60, state: &state)

        XCTAssertEqual(try XCTUnwrap(state.object("1")?.alpha), 0.75, accuracy: 0.0001,
                       "update read a stale brightness or origin after a cursor pass without events")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    private func engine(_ script: String, openUserShortcut: @escaping (String) -> Bool = { _ in false })
        throws -> (WPEParityScriptEngine, WPEParitySceneState) {
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "image": "models/a.json", "size": "16 16",
                         "alpha": ["value": 1, "script": script]]],
        ]), userValues: [:])
        let state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            openUserShortcut: openUserShortcut
        ))
        return (engine, state)
    }
}
