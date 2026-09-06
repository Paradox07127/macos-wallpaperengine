import Foundation
@testable import LiveWallpaper
import Testing

/// Charts break the path at a gap rather than interpolating across it, which is
/// right — but the gap test was sized from the wrong numbers, and a CPU trend in
/// ordinary use came apart into isolated dots. Two measurements, both taken by
/// driving the real sampler → hub → broker → pump → history path:
///
/// * The cadence used to come from the median step of the whole 240-sample
///   buffer. Move the refresh slider from 0.5 s to 2 s and the buffer median
///   stays 0.500 s (tolerance 0.875 s) while every step in the drawn window is
///   2.000 s: 30 of 30 adjacent pairs read as gaps, and stay that way for the
///   240 s the fast samples need to age out.
/// * A single dropped delivery leaves a 2× step. The board pulls the newest
///   snapshot from a one-slot broker at the same nominal rate the sampler fills
///   it, so a push that runs long loses the sample it stepped over: with a
///   120 ms push cost, 8 of 78 pairs broke and a 60 s window came apart into six
///   runs. At 1.75× cadence a 2× step is a gap.
///
/// `nil` was never the driver: 1 sample of 83 over 90 s, the first tick, where
/// a CPU rate genuinely has no previous counter to subtract.
@Suite("Monitor chart continuity")
struct MonitorChartContinuityTests {
    /// Steps as measured off the real sampler at a nominal 1 s cadence: the poll
    /// loop sleeps a fixed interval *after* its work, so every step runs long,
    /// by between 0.4% and 10.7%.
    private static let measuredSteps: [Double] = [
        1.052, 1.012, 1.068, 1.004, 1.052, 1.067, 1.068, 1.041, 1.022, 1.024,
        1.055, 1.064, 1.054, 1.027, 1.023, 1.014, 1.030, 1.026, 1.053, 1.063,
        1.056, 1.064, 1.063, 1.056, 1.004, 1.005, 1.032, 1.045, 1.017, 1.068,
        1.019, 1.041, 1.028, 1.063, 1.038, 1.024, 1.062, 1.045, 1.067, 1.022,
    ]

    private static func history(times: [Double], values: [Double?]? = nil) -> MonitorHistorySnapshot {
        var history = MonitorHistorySnapshot()
        history.sampleTimes = times
        history.cpuTotal = values ?? times.map { _ in 0.3 }
        return history
    }

    private static func times(steps: [Double], from start: Double = 0) -> [Double] {
        var times = [start]
        for step in steps {
            times.append(times[times.count - 1] + step)
        }
        return times
    }

    private static func runs(
        _ history: MonitorHistorySnapshot, seconds: Double
    ) -> (points: Int, runs: [Int]) {
        let reference = Date(timeIntervalSince1970: history.sampleTimes.last ?? 0)
        let window = history.chartWindow(reference: reference, seconds: seconds)
        let points = history.points(history.cpuTotal, in: window)
        return (points.count, ChartTimeAxis.runs(points, tolerance: window.tolerance).map(\.count))
    }

    @Test("An irregular but healthy stream draws one unbroken run")
    func healthyStreamIsOneRun() {
        let history = Self.history(times: Self.times(steps: Self.measuredSteps))
        let drawn = Self.runs(history, seconds: 60)
        #expect(drawn.points == Self.measuredSteps.count + 1)
        #expect(drawn.runs == [drawn.points])
    }

    /// The dominant measured cause. The refresh slider changes the machine's
    /// cadence without clearing the shared history, so the buffer keeps the old
    /// one; sizing the tolerance from it shreds a window that no longer has it.
    @Test("A cadence change does not turn the drawn window into isolated dots")
    func cadenceChangeDoesNotShredTheWindow() {
        var times = Self.times(steps: Array(repeating: 0.5, count: 179))
        for _ in 0 ..< 60 {
            times.append(times[times.count - 1] + 2.0)
        }
        let history = Self.history(times: times)
        let drawn = Self.runs(history, seconds: 60)
        #expect(drawn.points == 31)
        #expect(drawn.runs == [31])
    }

    /// The rule, asserted rather than described: one missing reading is bridged,
    /// two in a row are not. At a steady cadence a lost delivery costs a single
    /// sample and the two readings on either side are two intervals apart —
    /// close enough that a line between them says nothing the metric's own
    /// resolution does not already allow. Two in a row is three intervals of no
    /// information, and stays a break.
    @Test("One missing sample is bridged, two in a row break")
    func bridgeSpansExactlyOneMissingSample() {
        #expect(MonitorChartWindow.bridgeFactor > 2)
        #expect(MonitorChartWindow.bridgeFactor < 3)

        let oneMissing = Self.history(times: [0, 1, 2, 3, 5, 6, 7, 8])
        #expect(Self.runs(oneMissing, seconds: 60).runs == [8])

        let twoMissing = Self.history(times: [0, 1, 2, 3, 6, 7, 8, 9])
        #expect(Self.runs(twoMissing, seconds: 60).runs == [4, 4])
    }

    @Test("A real outage still breaks the path")
    func outageStillBreaks() {
        let paused = Self.history(times: [0, 1, 2, 3, 4, 64, 65, 66])
        let drawn = Self.runs(paused, seconds: 120)
        #expect(drawn.points == 8)
        #expect(drawn.runs == [5, 3])
    }

    /// The distinction the optional series exists for: a measured 0 is a
    /// reading and draws, an absent one is not and breaks — the widened bridge
    /// must not reach across a `nil`.
    @Test("A measured zero draws; an absent reading breaks even inside the bridge")
    func measuredZeroIsNotAbsence() {
        let zero = Self.history(times: [0, 1, 2, 3], values: [0.4, 0, 0, 0.2])
        #expect(Self.runs(zero, seconds: 60).runs == [4])

        let absent = Self.history(times: [0, 1, 2, 3], values: [0.4, nil, 0, 0.2])
        #expect(Self.runs(absent, seconds: 60).runs == [1, 2])
    }
}

/// A sample is a measurement, so it needs the time the measurement was taken.
/// The hub republishes the same unchanged system reading whenever any other
/// source updates; taking the publish clock at face value turned each of those
/// into a fresh point milliseconds after the last, and `Date()` invented a time
/// for snapshots that carried none at all.
@Suite("Monitor history sample admission")
@MainActor
struct MonitorHistoryAdmissionTests {
    private static func snapshot(
        publishedAt: Double, sampledAt: Double? = nil, cpuTotal: Double = 0.3
    ) -> MonitorSnapshot {
        var system = MonitorSystemSnapshot()
        system.cpuTotal = cpuTotal
        system.sampledAt = sampledAt
        var snapshot = MonitorSnapshot()
        snapshot.timestamp = publishedAt
        snapshot.system = system
        return snapshot
    }

    @Test("Republishing an unchanged reading with no measurement time adds no sample")
    func republishedReadingIsNotANewSample() {
        let store = MonitorHistoryStore()
        for tick in 0 ..< 8 {
            store.ingest(Self.snapshot(publishedAt: 100 + Double(tick) * 0.5))
        }
        #expect(store.current.sampleTimes == [100])

        // A changed reading with no measurement time is still a measurement.
        store.ingest(Self.snapshot(publishedAt: 104, cpuTotal: 0.9))
        #expect(store.current.sampleTimes == [100, 104])
    }

    @Test("A snapshot carrying no time at all is not a sample")
    func timelessSnapshotIsNotASample() {
        let store = MonitorHistoryStore()
        store.ingest(Self.snapshot(publishedAt: 0))
        #expect(store.current.sampleTimes.isEmpty)
        #expect(store.current.cpuTotal.isEmpty)
    }

    @Test("A measurement time is what the axis records when both clocks are present")
    func measurementTimeWinsOverPublishTime() {
        let store = MonitorHistoryStore()
        store.ingest(Self.snapshot(publishedAt: 500, sampledAt: 100))
        store.ingest(Self.snapshot(publishedAt: 501, sampledAt: 101, cpuTotal: 0.4))
        #expect(store.current.sampleTimes == [100, 101])
    }
}
