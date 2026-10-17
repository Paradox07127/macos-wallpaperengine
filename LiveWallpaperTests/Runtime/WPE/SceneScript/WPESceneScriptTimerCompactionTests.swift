#if !LITE_BUILD
import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Scene script timer queue drops cancelled timers")
struct WPESceneScriptTimerCompactionTests {
    private static let churn = """
    function churn() {
        for (var i = 0; i < 5000; i++) {
            if (pending) { pending(); }
            pending = engine.setTimeout(function () { stale += 1; }, 1e9);
        }
    }
    """

    @Test("Re-arming a far timer and cancelling the previous one does not grow the queue")
    func rearmedFarTimerKeepsQueueBounded() throws {
        let fixture = try TimerFixture(script: "var pending = null; var stale = 0;\n\(Self.churn)\nchurn();")
        #expect(fixture.scheduler.queuedEntryCount <= 2 * 1 + 64)
        _ = fixture.advance(to: 1)
        #expect(fixture.scheduler.queuedEntryCount <= 2 * 1 + 64)
        #expect(fixture.number("stale") == 0)
    }

    @Test("Cancelling inside a callback does not grow the queue once the advance ends")
    func churnInsideCallbackKeepsQueueBounded() throws {
        let fixture = try TimerFixture(script: """
        var pending = null; var stale = 0;
        \(Self.churn)
        engine.setTimeout(churn, 0);
        """)
        _ = fixture.advance(to: 0)
        #expect(fixture.scheduler.queuedEntryCount <= 2 * 1 + 64)
    }

    @Test("A live timer among thousands of cancelled ones fires exactly once")
    func liveTimerFiresOnce() throws {
        let fixture = try TimerFixture(script: """
        var pending = null; var stale = 0; var fires = 0;
        \(Self.churn)
        engine.setTimeout(function () { fires += 1; }, 10);
        churn();
        """)
        for seconds in [0, 0.005, 0.02, 0.05, 2] {
            #expect(fixture.advance(to: seconds) == .completed)
        }
        #expect(fixture.number("fires") == 1)
        #expect(fixture.number("stale") == 0)
    }

    @Test("An interval that cancels itself and churns timers in its callback fires once")
    func selfCancelledIntervalFiresOnce() throws {
        let fixture = try TimerFixture(script: """
        var pending = null; var stale = 0; var fires = 0;
        \(Self.churn)
        var interval = engine.setInterval(function () { fires += 1; interval(); churn(); }, 10);
        """)
        for seconds in [0, 0.01, 0.02, 0.03, 0.04] {
            #expect(fixture.advance(to: seconds) == .completed)
        }
        #expect(fixture.number("fires") == 1)
    }

    @Test("An interval that churns timers in its callback fires once per advance")
    func churningIntervalFiresOncePerAdvance() throws {
        let fixture = try TimerFixture(script: """
        var pending = null; var stale = 0; var fires = 0;
        \(Self.churn)
        engine.setInterval(function () { fires += 1; churn(); }, 10);
        """)
        _ = fixture.advance(to: 0)
        for (index, seconds) in [0.01, 0.02, 0.03, 0.04].enumerated() {
            #expect(fixture.advance(to: seconds) == .completed)
            #expect(fixture.number("fires") == Double(index + 1))
        }
        #expect(fixture.scheduler.queuedEntryCount <= 2 * 2 + 64)
    }
}

@MainActor
private final class TimerFixture {
    let context: JSContext
    let scheduler = WPESceneScriptTimerScheduler()

    init(script: String) throws {
        context = try #require(JSContext())
        let engine = try #require(JSValue(newObjectIn: context))
        context.setObject(engine, forKeyedSubscript: "engine" as NSString)
        scheduler.install(in: context, engine: engine)
        context.evaluateScript(script)
        #expect(context.exception == nil)
    }

    func advance(to seconds: Double) -> WPESceneScriptTimerScheduler.AdvanceResult {
        scheduler.advance(to: seconds, beforeEachCallback: {}, callbackDidThrow: { [context] in
            context.exception != nil
        })
    }

    func number(_ name: String) -> Double? {
        context.objectForKeyedSubscript(name)?.toDouble()
    }
}
#endif
