import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class MonitorAgentSessionWidgetTests: XCTestCase {
    private static let now: Double = 1_000_000

    private func session(
        _ id: String,
        _ status: MonitorAgentStatus,
        provider: MonitorAgentProvider = .claude,
        name: String = "proj",
        lastEventAt: Double = now,
        startedAt: Double? = nil,
        waitSince: Double? = nil,
        warning: String? = nil,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        statusDetail: String? = nil
    ) -> MonitorAgentSessionState {
        var s = MonitorAgentSessionState(
            id: id, provider: provider, projectName: name,
            status: status, lastEventAt: lastEventAt, processAlive: status != .ended)
        s.startedAt = startedAt
        s.waitSince = waitSince
        s.warning = warning
        s.tokens = MonitorTokenTotals(input: tokensIn, output: tokensOut)
        s.statusDetail = statusDetail
        return s
    }

    func testSortOrdersByAttentionThenRecency() {
        let sessions = [
            session("a", .ended, lastEventAt: 500),
            session("b", .running, lastEventAt: 100),
            session("c", .needsInput, lastEventAt: 50),
            session("d", .idle, lastEventAt: 900),
            session("e", .running, lastEventAt: 400),
        ]
        let ids = MonitorAgentSessionWidgetView.sorted(sessions).map(\.id)
        XCTAssertEqual(ids, ["c", "e", "b", "d", "a"])
    }

    func testSortIsStableWithinEqualPriorityByRecency() {
        let sessions = [
            session("old", .running, lastEventAt: 10),
            session("new", .running, lastEventAt: 90),
            session("mid", .running, lastEventAt: 50),
        ]
        XCTAssertEqual(MonitorAgentSessionWidgetView.sorted(sessions).map(\.id), ["new", "mid", "old"])
    }

    func testUnknownSortsBelowIdleAboveEnded() {
        let sessions = [
            session("ended", .ended),
            session("unknown", .unknown),
            session("idle", .idle),
        ]
        XCTAssertEqual(MonitorAgentSessionWidgetView.sorted(sessions).map(\.id), ["idle", "unknown", "ended"])
    }

    func testMediumRowsDropIdleAndCapAtThree() {
        let sorted = MonitorAgentSessionWidgetView.sorted([
            session("need", .needsInput),
            session("run1", .running, lastEventAt: 90),
            session("run2", .running, lastEventAt: 80),
            session("run3", .running, lastEventAt: 70),
            session("idle", .idle),
            session("ended", .ended),
        ])
        let rows = MonitorAgentSessionWidgetView.mediumRows(sorted, cap: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.id), ["need", "run1", "run2"])
        XCTAssertFalse(rows.contains { $0.status == .idle })
    }

    func testMediumRowsKeepsEndedWhenRoom() {
        let sorted = MonitorAgentSessionWidgetView.sorted([
            session("need", .needsInput),
            session("ended", .ended),
            session("idle", .idle),
        ])
        XCTAssertEqual(MonitorAgentSessionWidgetView.mediumRows(sorted, cap: 3).map(\.id), ["need", "ended"])
    }

    func testCountsBucketByStatus() {
        let c = MonitorAgentSessionWidgetView.counts([
            session("1", .running), session("2", .running), session("3", .running),
            session("4", .needsInput),
            session("5", .idle), session("6", .idle),
            session("7", .ended),
            session("8", .unknown),
        ])
        XCTAssertEqual(c.running, 3)
        XCTAssertEqual(c.needsInput, 1)
        XCTAssertEqual(c.idle, 2)
        XCTAssertEqual(c.ended, 1)
        XCTAssertEqual(c.unknown, 1)
    }

    func testTotalsTrackLongestRunAndWarnFlag() {
        let sessions = [
            session("need", .needsInput, startedAt: Self.now - 410),
            session("burn", .running, startedAt: Self.now - 192, warning: "toolLoop"),
            session("prod", .running, startedAt: Self.now - 47),
            session("ended", .ended, startedAt: Self.now - 600),
        ]
        let t = MonitorAgentSessionWidgetView.totals(sessions, now: Self.now)
        XCTAssertEqual(t.longest, 192, accuracy: 0.5)
        XCTAssertTrue(t.anyWarn)
    }

    func testTotalsNoWarnWhenNoneCarryWarning() {
        let t = MonitorAgentSessionWidgetView.totals([
            session("r", .running, startedAt: Self.now - 10),
        ], now: Self.now)
        XCTAssertFalse(t.anyWarn)
    }

    func testRunningTimerSourcesFromStartedAt() {
        let s = session("r", .running, lastEventAt: Self.now - 3, startedAt: Self.now - 125)
        let timer = MonitorAgentSessionWidgetView.timerText(for: s, now: Self.now)
        XCTAssertEqual(timer?.source, .running)
        XCTAssertEqual(timer?.text, "02:05")
    }

    func testNeedsInputTimerSourcesFromWaitSince() {
        let s = session("n", .needsInput, waitSince: Self.now - 34)
        let timer = MonitorAgentSessionWidgetView.timerText(for: s, now: Self.now)
        XCTAssertEqual(timer?.source, .waiting)
        XCTAssertTrue(timer?.text.contains("00:34") ?? false, "waiting timer should read since waitSince")
    }

    func testEndedTimerIsFinishedAgoFromLastEvent() {
        let s = session("e", .ended, lastEventAt: Self.now - 130)
        let timer = MonitorAgentSessionWidgetView.timerText(for: s, now: Self.now)
        XCTAssertEqual(timer?.source, .finished)
        XCTAssertTrue(timer?.text.contains("2m") ?? false, "ended shows a compact 'finished 2m ago'")
    }

    func testIdleHasNoTimer() {
        XCTAssertNil(MonitorAgentSessionWidgetView.timerText(for: session("i", .idle), now: Self.now))
    }

    func testRunningWithoutStartedAtHasNoTimer() {
        XCTAssertNil(MonitorAgentSessionWidgetView.timerText(for: session("r", .running, startedAt: nil), now: Self.now))
    }

    func testWarningChipMapsKnownTokens() {
        let loop = MonitorAgentSessionWidgetView.warningLabel(for: session("a", .running, warning: "toolLoop"))
        XCTAssertEqual(loop?.text, "tool loop")
        XCTAssertFalse(loop?.isStale ?? true)

        let stale = MonitorAgentSessionWidgetView.warningLabel(for: session("b", .running, warning: "stale"))
        XCTAssertEqual(stale?.text, "stale")
        XCTAssertTrue(stale?.isStale ?? false)
    }

    func testWarningChipPassesThroughUnknownTokenAndNilWhenEmpty() {
        XCTAssertEqual(MonitorAgentSessionWidgetView.warningLabel(for: session("a", .running, warning: "testFailing"))?.text,
                       "testFailing")
        XCTAssertNil(MonitorAgentSessionWidgetView.warningLabel(for: session("b", .running, warning: nil)))
        XCTAssertNil(MonitorAgentSessionWidgetView.warningLabel(for: session("c", .running, warning: "")))
    }

    func testLargeRowsKeepIdleAndEndedAndCap() {
        let sorted = MonitorAgentSessionWidgetView.sorted([
            session("need", .needsInput),
            session("run1", .running, lastEventAt: 90),
            session("run2", .running, lastEventAt: 80),
            session("idle", .idle),
            session("ended", .ended),
        ])
        let rows = MonitorAgentSessionWidgetView.largeRows(sorted, cap: 6)
        XCTAssertEqual(rows.map(\.id), ["need", "run1", "run2", "idle", "ended"])
        XCTAssertEqual(MonitorAgentSessionWidgetView.largeRows(sorted, cap: 3).map(\.id), ["need", "run1", "run2"])
        XCTAssertEqual(MonitorAgentSessionWidgetView.largeRows(sorted, cap: 0).count, 0)
    }

    func testProviderFilterReadsOption() {
        XCTAssertEqual(MonitorAgentSessionWidgetView.providerFilter([:]), nil)
        XCTAssertEqual(MonitorAgentSessionWidgetView.providerFilter(["fleetProvider": .string("claude")]), .claude)
        XCTAssertEqual(MonitorAgentSessionWidgetView.providerFilter(["fleetProvider": .string("codex")]), .codex)
        XCTAssertEqual(MonitorAgentSessionWidgetView.providerFilter(["fleetProvider": .string("gemini")]), nil)
    }

    func testFilteredByProvider() {
        let all = [
            session("c1", .running, provider: .claude),
            session("x1", .running, provider: .codex),
            session("c2", .idle, provider: .claude),
        ]
        XCTAssertEqual(MonitorAgentSessionWidgetView.filtered(all, provider: nil).count, 3)
        XCTAssertEqual(MonitorAgentSessionWidgetView.filtered(all, provider: .claude).map(\.id), ["c1", "c2"])
        XCTAssertEqual(MonitorAgentSessionWidgetView.filtered(all, provider: .codex).map(\.id), ["x1"])
    }

    func testSortModeReadsOption() {
        XCTAssertEqual(MonitorAgentSessionWidgetView.sortMode([:]), .attention)
        XCTAssertEqual(MonitorAgentSessionWidgetView.sortMode(["fleetSort": .string("recent")]), .recent)
        XCTAssertEqual(MonitorAgentSessionWidgetView.sortMode(["fleetSort": .string("bogus")]), .attention)
    }

    func testSortByRecentIgnoresAttentionPriority() {
        let sessions = [
            session("oldNeed", .needsInput, lastEventAt: 10),
            session("newRun", .running, lastEventAt: 90),
            session("midIdle", .idle, lastEventAt: 50),
        ]
        XCTAssertEqual(MonitorAgentSessionWidgetView.sorted(sessions, mode: .recent).map(\.id),
                       ["newRun", "midIdle", "oldNeed"])
    }

    func testSortAttentionModeMatchesDefaultSort() {
        let sessions = [
            session("a", .ended, lastEventAt: 500),
            session("b", .running, lastEventAt: 100),
            session("c", .needsInput, lastEventAt: 50),
        ]
        XCTAssertEqual(MonitorAgentSessionWidgetView.sorted(sessions, mode: .attention).map(\.id),
                       MonitorAgentSessionWidgetView.sorted(sessions).map(\.id))
    }

    func testRowCapClampsToFallbackAndFloor() {
        XCTAssertEqual(MonitorAgentSessionWidgetView.rowCap([:], fallback: 6), 6)
        XCTAssertEqual(MonitorAgentSessionWidgetView.rowCap([:], fallback: 3), 3)
        XCTAssertEqual(MonitorAgentSessionWidgetView.rowCap(["fleetMaxRows": .number(4)], fallback: 6), 4)
        XCTAssertEqual(MonitorAgentSessionWidgetView.rowCap(["fleetMaxRows": .number(9)], fallback: 6), 6)
        XCTAssertEqual(MonitorAgentSessionWidgetView.rowCap(["fleetMaxRows": .number(4)], fallback: 3), 3)
        XCTAssertEqual(MonitorAgentSessionWidgetView.rowCap(["fleetMaxRows": .number(0)], fallback: 6), 1)
    }
}
