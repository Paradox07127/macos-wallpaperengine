import Foundation
import Combine
import LiveWallpaperCore
import SwiftUI

// MARK: - Widget-facing contract (orchestrator-owned)

struct MonitorWidgetContext {
    var snapshot: MonitorSnapshot
    var history: MonitorHistorySnapshot
    var placement: MonitorWidgetPlacement
    var isEditing: Bool
    var reduceMotion: Bool
    var now: Date

    var readingsNotice: LocalizedStringKey? {
        // Agent, weather and clock tiles do not consume the system snapshot.
        // Metric provenance must not turn them into a waiting-for-readings card.
        guard placement.kind != .fleet, placement.kind != .weather, placement.kind != .nixieClock else { return nil }
        guard let system = snapshot.system else { return "Waiting for readings" }
        // The overview keeps healthy instruments visible when another source is
        // unavailable. Its individual readings use their own metric provenance.
        if placement.kind == .systemOverview {
            return nil
        }
        if let samples = system.metricSamples {
            guard let sample = samples[placement.kind.rawValue], sample.available else { return "Readings unavailable" }
            return sample.isStale(at: now) ? "Readings are out of date" : nil
        }
        // Older snapshots and previews have no provenance. Only concrete fields
        // demonstrate availability; default-initialized zeroes cannot do so.
        let available: Bool = switch placement.kind {
        case .cpu: system.perCore != nil || system.cpuTotal > 0
        case .memory: system.memTotalBytes > 0 && system.memBreakdown != nil
        case .gpu: system.gpuUsage != nil
        case .network: system.netInterfaces != nil
        case .disk: system.diskReadBytesPerSec > 0 || system.diskWriteBytesPerSec > 0
        case .power: system.batteryLevel != nil || system.powerSource != nil
        case .processes: system.topProcesses != nil
        case .aiEngine: system.aneFootprintPresent != nil
        case .systemOverview, .fleet, .weather, .nixieClock: true
        }
        return available ? nil : "Readings unavailable"
    }
}

#if DEBUG
extension MonitorWidgetContext {
    func at(_ date: Date) -> MonitorWidgetContext {
        var copy = self
        copy.now = date
        return copy
    }
}
#endif

/// One position on the shared time axis. `value == nil` is "no reading at that
/// instant"; a measured zero is `0`, and the two must never draw the same.
struct MonitorHistoryPoint: Sendable, Equatable {
    var time: Double
    var value: Double?
}

/// The stretch of wall clock a chart draws: `reference - length` … `reference`,
/// so X always means "when", never "which array index".
struct MonitorChartWindow: Sendable, Equatable {
    var reference: Double
    var length: Double
    /// Two consecutive samples further apart than this are a gap: the path
    /// breaks there instead of interpolating across it.
    var tolerance: Double

    /// How far a curve may reach across missing samples, as a multiple of the series'
    /// own cadence: one dropped delivery leaves a 2× step and two leave 3×, so 2.5
    /// bridges one missing reading and breaks on two.
    static let bridgeFactor = 2.5

    /// `interval` is the series' own cadence; with none to go on, a twentieth
    /// of the window is the fallback.
    init(reference: Double, seconds: Double, interval: Double?) {
        let span = max(seconds, .ulpOfOne)
        self.reference = reference
        length = span
        let cadence = interval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? span / 20
        tolerance = cadence * Self.bridgeFactor
    }

    var start: Double {
        reference - length
    }

    func contains(_ time: Double) -> Bool {
        time >= start && time <= reference
    }

    /// 0 at the window's start, 1 at its reference.
    func fraction(of time: Double) -> Double {
        (time - start) / length
    }
}

enum ChartTimeAxis {
    static func x(_ time: Double, in window: MonitorChartWindow, width: CGFloat) -> CGFloat {
        CGFloat(window.fraction(of: time)) * width
    }

    static func runs(_ points: [MonitorHistoryPoint], tolerance: Double) -> [Range<Int>] {
        runs(points, present: points.map { $0.value != nil }, tolerance: tolerance)
    }

    /// Index runs of consecutive drawable samples: a run ends at a missing reading or
    /// a step over `tolerance`. `present` is separate so a paired band breaks either way.
    static func runs(
        _ points: [MonitorHistoryPoint],
        present: [Bool],
        tolerance: Double
    ) -> [Range<Int>] {
        guard points.count == present.count else { return [] }
        var result: [Range<Int>] = []
        var open: Int?
        for index in points.indices {
            let gapBefore = index > 0 && points[index].time - points[index - 1].time > tolerance
            if !present[index] || gapBefore, let start = open {
                result.append(start ..< index)
                open = nil
            }
            if present[index], open == nil {
                open = index
            }
        }
        if let start = open {
            result.append(start ..< points.count)
        }
        return result
    }
}

/// Every series is `[Double?]` over the shared `sampleTimes` axis: `nil` is "no
/// reading at that instant", never a zero. The shared axis means a missing CPU
/// sample neither shifts nor drops the GPU sample taken at the same instant.
struct MonitorHistorySnapshot: Sendable, Equatable {
    var sampleTimes: [Double] = []
    var cpuTotal: [Double?] = []
    var cpuUser: [Double?] = []
    var cpuSystem: [Double?] = []
    var memUsedFraction: [Double?] = []
    /// Aligned with `memUsedFraction` — curve colors by discrete pressure, not used%.
    var memPressure: [String] = []
    /// App/wired/compressed fractions of total RAM, aligned with `memUsedFraction`.
    var memAppFraction: [Double?] = []
    var memWiredFraction: [Double?] = []
    var memCompressedFraction: [Double?] = []
    var gpuSampleTimes: [Double] = []
    /// Device/Renderer/Tiler are independently optional at the same time
    /// position: a poll that reports only one of them keeps that one.
    var gpuDevice: [Double?] = []
    var gpuRenderer: [Double?] = []
    var gpuTiler: [Double?] = []
    var netRx: [Double?] = []
    var netTx: [Double?] = []
    var diskRead: [Double?] = []
    var diskWrite: [Double?] = []

    var cpuPeak: Double = 0
    var gpuPeak: Double = 0
    var netRxPeak: Double = 0
    var netTxPeak: Double = 0
    var diskReadPeak: Double = 0
    var diskWritePeak: Double = 0

    var netRxSessionBytes: Double = 0
    var netTxSessionBytes: Double = 0
    var diskReadSessionBytes: Double = 0
    var diskWriteSessionBytes: Double = 0
}

extension MonitorHistorySnapshot {
    func chartWindow(reference: Date, seconds: Double) -> MonitorChartWindow {
        Self.window(reference: reference, seconds: seconds, times: sampleTimes)
    }

    func gpuChartWindow(reference: Date, seconds: Double) -> MonitorChartWindow {
        Self.window(reference: reference, seconds: seconds, times: gpuSampleTimes)
    }

    /// Cadence measured over the samples this window draws, not the whole buffer: the
    /// refresh slider changes cadence without clearing history, so an old buffer median
    /// reads every step in the window as a gap. Fallback only below two samples.
    private static func window(
        reference: Date, seconds: Double, times: [Double]
    ) -> MonitorChartWindow {
        let end = reference.timeIntervalSince1970
        let span = max(seconds, .ulpOfOne)
        let inside = times.filter { $0 >= end - span && $0 <= end }
        return MonitorChartWindow(
            reference: end,
            seconds: span,
            interval: medianStep(inside) ?? medianStep(times)
        )
    }

    func points(_ series: [Double?], in window: MonitorChartWindow) -> [MonitorHistoryPoint] {
        Self.points(series, times: sampleTimes, in: window)
    }

    func gpuPoints(_ series: [Double?], in window: MonitorChartWindow) -> [MonitorHistoryPoint] {
        Self.points(series, times: gpuSampleTimes, in: window)
    }

    /// The readings actually taken inside the window — what a peak readout may
    /// summarize. Absent positions contribute nothing rather than a zero.
    func values(_ series: [Double?], in window: MonitorChartWindow) -> [Double] {
        points(series, in: window).compactMap(\.value)
    }

    func gpuValues(_ series: [Double?], in window: MonitorChartWindow) -> [Double] {
        gpuPoints(series, in: window).compactMap(\.value)
    }

    static func points(
        _ series: [Double?], times: [Double], in window: MonitorChartWindow
    ) -> [MonitorHistoryPoint] {
        guard times.count == series.count else { return [] }
        return zip(times, series)
            .filter { window.contains($0.0) }
            .map { MonitorHistoryPoint(time: $0.0, value: $0.1) }
    }

    /// The last `seconds` of a series aligned with `sampleTimes`, absent samples
    /// dropped. Not `suffix(seconds)`: that equals N seconds only at exactly 1 Hz and
    /// the refresh slider spans 0.2…2 Hz. Falls back to a count when times are missing.
    func windowed(_ series: [Double?], seconds: Int, minimumPoints: Int = 2) -> [Double] {
        guard sampleTimes.count == series.count, let last = sampleTimes.last else {
            return series.suffix(max(seconds, minimumPoints)).compactMap(\.self)
        }
        let cutoff = last - Double(seconds)
        return zip(sampleTimes, series).filter { $0.0 >= cutoff }.compactMap(\.1)
    }

    static func historyWindowSeconds(optionSeconds: Double?, fallbackSeconds: Int) -> Int {
        guard let optionSeconds, optionSeconds.isFinite, optionSeconds > 0 else {
            return fallbackSeconds
        }
        // isFinite alone does not bound the conversion: 1e300 is finite and
        // Int(_:) traps on it. Clamp in Double space before converting.
        return Int(min(max(optionSeconds.rounded(), 2), 86400))
    }

    private static func medianStep(_ times: [Double]) -> Double? {
        guard times.count >= 2 else { return nil }
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !steps.isEmpty else { return nil }
        return steps[steps.count / 2]
    }
}

@MainActor
final class MonitorHistoryStore: ObservableObject {
    @Published private(set) var current = MonitorHistorySnapshot()

    private let capacity: Int
    private var lastSampleAt: Double?
    private var lastGPUSampleAt: Double?
    /// Only consulted for snapshots that carry no measurement time — see `ingest`.
    private var lastSystem: MonitorSystemSnapshot?

    /// 240, not 120: the longest window is 120 s and the slider goes to 0.5 s per
    /// sample, so 120 samples would only ever cover 60 s of a 120 s chart.
    init(capacity: Int = 240) {
        self.capacity = max(capacity, 2)
    }

    func reset() {
        current = MonitorHistorySnapshot()
        lastSampleAt = nil
        lastGPUSampleAt = nil
        lastSystem = nil
    }

    func ingest(_ snapshot: MonitorSnapshot) {
        guard let sys = snapshot.system else { return }
        // The hub republishes the same unchanged reading whenever any other source
        // updates, so an unchanged reading with no measurement time is not a sample:
        // taking the publish clock at face value manufactures a cadence nothing sampled at.
        if sys.sampledAt == nil, sys == lastSystem {
            return
        }
        guard let t = sys.sampledAt ?? (snapshot.timestamp > 0 ? snapshot.timestamp : nil) else {
            return
        }
        if let last = lastSampleAt, t <= last {
            return
        }
        var next = current
        let dt = lastSampleAt.map { min(max(t - $0, 0), 10) } ?? 0
        lastSampleAt = t
        lastSystem = sys
        next.sampleTimes.append(t)

        let cpu = Self.sampled(sys, "cpu")
        next.cpuTotal.append(cpu ? sys.cpuTotal : nil)
        next.cpuUser.append(cpu ? sys.cpuUser : nil)
        next.cpuSystem.append(cpu ? sys.cpuSystem : nil)

        // One gate for all four memory series so the stacked bands stay index-aligned:
        // a position with no breakdown cannot be stacked at all.
        let total = Double(sys.memTotalBytes)
        let breakdown = Self.sampled(sys, "memory") && total > 0 ? sys.memBreakdown : nil
        next.memUsedFraction.append(breakdown.map { _ in Double(sys.memUsedBytes) / total })
        next.memPressure.append(sys.memPressure)
        next.memAppFraction.append(breakdown.map { Double($0.appBytes) / total })
        next.memWiredFraction.append(breakdown.map { Double($0.wiredBytes) / total })
        next.memCompressedFraction.append(breakdown.map { Double($0.compressedBytes) / total })

        let network = Self.sampled(sys, "network")
        next.netRx.append(network ? sys.netRxBytesPerSec : nil)
        next.netTx.append(network ? sys.netTxBytesPerSec : nil)
        let disk = Self.sampled(sys, "disk")
        next.diskRead.append(disk ? sys.diskReadBytesPerSec : nil)
        next.diskWrite.append(disk ? sys.diskWriteBytesPerSec : nil)

        // Gated on the sub-readings, not the GPU group's provenance: a poll that
        // returned only the renderer must keep it rather than discard the row.
        if sys.gpuUsage != nil || sys.gpuRendererUtil != nil || sys.gpuTilerUtil != nil {
            let gpuAt = sys.gpuSampledAt ?? t
            if lastGPUSampleAt != gpuAt {
                lastGPUSampleAt = gpuAt
                next.gpuSampleTimes.append(gpuAt)
                next.gpuDevice.append(sys.gpuUsage)
                next.gpuRenderer.append(sys.gpuRendererUtil)
                next.gpuTiler.append(sys.gpuTilerUtil)
                trim(&next.gpuSampleTimes)
                trim(&next.gpuDevice)
                trim(&next.gpuRenderer)
                trim(&next.gpuTiler)
            }
        }

        trim(&next.sampleTimes)
        trim(&next.cpuTotal)
        trim(&next.cpuUser)
        trim(&next.cpuSystem)
        trim(&next.memUsedFraction)
        trim(&next.memPressure)
        trim(&next.memAppFraction)
        trim(&next.memWiredFraction)
        trim(&next.memCompressedFraction)
        trim(&next.netRx)
        trim(&next.netTx)
        trim(&next.diskRead)
        trim(&next.diskWrite)

        next.cpuPeak = Self.peak(next.cpuTotal)
        next.gpuPeak = Self.peak(next.gpuDevice)
        next.netRxPeak = Self.peak(next.netRx)
        next.netTxPeak = Self.peak(next.netTx)
        next.diskReadPeak = Self.peak(next.diskRead)
        next.diskWritePeak = Self.peak(next.diskWrite)

        next.netRxSessionBytes += sys.netRxBytesPerSec * dt
        next.netTxSessionBytes += sys.netTxBytesPerSec * dt
        next.diskReadSessionBytes += sys.diskReadBytesPerSec * dt
        next.diskWriteSessionBytes += sys.diskWriteBytesPerSec * dt

        current = next
    }

    /// The snapshot's own statement about whether that group produced a reading; frames
    /// without provenance are taken at face value, so this cannot drift from `readingsNotice`.
    private static func sampled(_ sys: MonitorSystemSnapshot, _ key: String) -> Bool {
        guard let samples = sys.metricSamples else { return true }
        return samples[key]?.available ?? false
    }

    private static func peak(_ series: [Double?]) -> Double {
        series.compactMap(\.self).max() ?? 0
    }

    private func trim<T>(_ array: inout [T]) {
        if array.count > capacity {
            array.removeFirst(array.count - capacity)
        }
    }
}
