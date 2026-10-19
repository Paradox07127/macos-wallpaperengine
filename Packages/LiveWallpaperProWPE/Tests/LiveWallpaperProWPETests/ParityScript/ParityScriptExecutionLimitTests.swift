import Foundation
import JavaScriptCore
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptExecutionLimitTests: XCTestCase {
    private let limits = WPEParityScriptEngine.ExecutionLimits(setupSeconds: 0.1, callbackSeconds: 0.02)

    func testInfiniteModuleBodyAndImportedModuleAreTerminatedDuringBothConstructionPaths() throws {
        for script in ["while (true) {}", "import './stuck.js'; export function update(v) { return v; }"] {
            let (document, state, config) = try fixture(script, files: ["scripts/stuck.js": Data("while(true) {}".utf8)])
            let start = Date()
            XCTAssertThrowsError(try WPEParityScriptEngine(document: document, state: state, configuration: config)) {
                XCTAssertEqual($0 as? WPEParityScriptEngine.Failure, .executionTimedOut(operation: .setup, seconds: 0.1))
            }
            var canonical = state
            XCTAssertThrowsError(try WPEParityScriptEngine.prepare(document: document, state: &canonical,
                                                                   configuration: config, volume: { _, _ in }, command: { _, _, _ in false })) {
                XCTAssertEqual($0 as? WPEParityScriptEngine.Failure, .executionTimedOut(operation: .setup, seconds: 0.1))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    func testBaseClassesAreGuardedBeforeTheFirstJavaScriptRuns() throws {
        let (document, state, config) = try fixture("", files: ["scripts/jsclasses/baseclasses.js": Data("while(true) {}".utf8)])
        XCTAssertThrowsError(try WPEParityScriptEngine(document: document, state: state, configuration: config)) {
            XCTAssertEqual($0 as? WPEParityScriptEngine.Failure, .executionTimedOut(operation: .setup, seconds: 0.1))
        }
    }

    func testInitTimesOutAndCannotBeCaughtOrRestarted() throws {
        let (document, original, config) = try fixture("""
        export function init(v) { try { while(true) {} } catch(e) { thisLayer.alpha = 0.9; } return v; }
        export function update(v) { return 0.7; }
        """)
        var state = original
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: config)
        XCTAssertThrowsError(try engine.start(state: &state)) {
            XCTAssertEqual($0 as? WPEParityScriptEngine.Failure, .executionTimedOut(operation: .initialize, seconds: 0.1))
        }
        XCTAssertTrue(engine.isExecutionDisabled)
        engine.tick(dt: 1, state: &state)
        XCTAssertEqual(state.object("1")?.alpha, 1)
        XCTAssertEqual(engine.dispatchCount(.update), 0)
        XCTAssertThrowsError(try engine.start(state: &state))
        XCTAssertEqual(engine.exceptionCount, 1)
    }

    func testUpdateTimeoutRejectsPendingWritesAndEveryLaterEntryIncludingDestroy() throws {
        let (document, original, config) = try fixture("""
        export function update(v) { thisLayer.alpha = 0.2; while(true) {} return 0.3; }
        export function applyGeneralSettings(s) { thisLayer.alpha = 0.4; }
        export function destroy() { while(true) {} }
        """)
        var state = original
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: config)
        try engine.start(state: &state)
        engine.tick(dt: 1, state: &state)
        XCTAssertEqual(engine.executionFailure, .executionTimedOut(operation: .update, seconds: 0.02))
        XCTAssertEqual(state.object("1")?.alpha, 1)
        engine.dispatch(.applyGeneralSettings, payloadJSON: "{}", state: &state)
        engine.applyUserProperties(changedJSON: "{}", mergedJSON: "{}", state: &state)
        engine.resize(canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32), state: &state)
        engine.destroy(state: &state)
        engine.tick(dt: 1, state: &state)
        XCTAssertEqual(engine.dispatchCount(.update), 1)
        XCTAssertEqual(engine.dispatchCount(.destroy), 0)
        XCTAssertEqual(engine.dispatchCount(.applyGeneralSettings), 0)
        XCTAssertEqual(engine.exceptionCount, 1)
        XCTAssertEqual(state.object("1")?.alpha, 1)
    }

    func testEventAndTimerAndDestroyLoopsAreTerminated() throws {
        for (script, call, operation) in [
            ("export function applyGeneralSettings(e) { while(true) {} }", "event", WPEParityScriptEngine.ExecutionOperation.event),
            ("export function init(v) { engine.setTimeout(() => { while(true) {} }, 1); return v; }", "timer", .update),
            ("export function destroy() { while(true) {} }", "destroy", .destroy),
        ] {
            let (document, original, config) = try fixture(script)
            var state = original
            let engine = try WPEParityScriptEngine(document: document, state: state, configuration: config)
            try engine.start(state: &state)
            switch call {
            case "event": engine.dispatch(.applyGeneralSettings, payloadJSON: "{}", state: &state)
            case "timer": engine.tick(dt: 1, state: &state)
            default: engine.destroy(state: &state)
            }
            XCTAssertEqual(engine.executionFailure, .executionTimedOut(operation: operation, seconds: 0.02), call)
            XCTAssertEqual(engine.exceptionCount, 1, call)
            engine.destroy(state: &state)
        }
    }

    func testNestedHostCallsCannotRefreshTheOuterDeadline() throws {
        let limiter = try WPEParityScriptExecutionLimiter()
        let context = try XCTUnwrap(JSContext())
        let start = Date()
        let completed = limiter.perform(in: context, seconds: 0.02) {
            _ = limiter.perform(in: context, seconds: 10) { context.evaluateScript("while(true) {}") }
        }
        XCTAssertFalse(completed)
        XCTAssertTrue(limiter.didTimeOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testSequentialVMEntriesShareOneBatchAllowance() throws {
        let limiter = try WPEParityScriptExecutionLimiter()
        let context = try XCTUnwrap(JSContext())
        let start = Date()
        var calls = 0
        let completed = limiter.perform(in: context, seconds: 0.03) {
            for _ in 0 ..< 1000 {
                guard limiter.prepareInvocation(in: context) else { break }
                context.evaluateScript("(function(){let total=0; for(let i=0;i<100000;i++) total+=i; return total;})()")
                if !limiter.didTimeOut {
                    XCTAssertNil(context.exception)
                }
                calls += 1
            }
        }
        XCTAssertFalse(completed)
        XCTAssertTrue(limiter.didTimeOut)
        XCTAssertLessThan(calls, 1000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testExceptionStringConversionAndRealCursorEntryAreBounded() throws {
        for script in [
            "export function update(v) { throw {toString() { while(true) {} }}; }",
            "export function cursorClick(e) { while(true) {} }",
        ] {
            let (document, original, config) = try fixture(script)
            var state = original
            let engine = try WPEParityScriptEngine(document: document, state: state, configuration: config)
            try engine.start(state: &state)
            if script.contains("cursorClick") {
                engine.cursor([.init(event: .cursorClick, id: "1")], input: .init(), state: &state)
            } else {
                engine.tick(dt: 1, state: &state)
            }
            XCTAssertTrue(engine.isExecutionDisabled)
            XCTAssertNotNil(engine.executionFailure)
            engine.destroy(state: &state)
        }
    }

    func testNormalFixtureRunsAndDestroysUnderProductionDefaultsAndFreshEngineSurvivesAnotherTimeout() throws {
        let (document, original, quick) = try fixture("export function update(v) { while(true) {} }")
        var previous = original
        let poisoned = try WPEParityScriptEngine(document: document, state: previous, configuration: quick)
        try poisoned.start(state: &previous)
        poisoned.tick(dt: 1, state: &previous)
        XCTAssertTrue(poisoned.isExecutionDisabled)

        let (normalDocument, normalState, config) = try fixture("""
        export function init(v) { return 0.5; }
        export function update(v) { let sum = 0; for(let i=0;i<10000;i++) sum += i; return v + 0.001; }
        export function destroy() { thisLayer.brightness = 0.25; }
        """, limits: .init())
        var state = normalState
        let engine = try WPEParityScriptEngine(document: normalDocument, state: state, configuration: config)
        try engine.start(state: &state)
        for _ in 0 ..< 120 {
            engine.tick(dt: 1 / 60, state: &state)
        }
        XCTAssertEqual(try XCTUnwrap(state.object("1")?.alpha), 0.62, accuracy: 0.0001)
        engine.destroy(state: &state)
        XCTAssertEqual(state.object("1")?.brightness, 0.25)
        XCTAssertNil(engine.executionFailure)
        XCTAssertEqual(engine.exceptionCount, 0)
    }

    private func fixture(_ script: String, files: [String: Data] = [:],
                         limits: WPEParityScriptEngine.ExecutionLimits? = nil)
        throws -> (WPESceneDocument, WPEParitySceneState, WPEParityScriptEngine.Configuration) {
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "name": "one", "image": "models/one.json", "size": "16 16",
                         "alpha": ["value": 1, "script": script]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        let state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        var resources = files
        if resources["scripts/jsclasses/baseclasses.js"] == nil {
            resources["scripts/jsclasses/baseclasses.js"] = try Data(contentsOf: fixture)
        }
        let snapshot = resources
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { snapshot[$0] }])
        return (document, state, .init(assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
                                       executionLimits: limits ?? self.limits))
    }
}
