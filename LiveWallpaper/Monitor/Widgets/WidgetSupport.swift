import Foundation
import Combine
import LiveWallpaperCore

// MARK: - Widget-facing contract (orchestrator-owned)

struct MonitorWidgetContext {
    var snapshot: MonitorSnapshot
    var history: MonitorHistorySnapshot
    var placement: MonitorWidgetPlacement
    var isEditing: Bool
    var reduceMotion: Bool
    var now: Date
}

#if DEBUG
extension MonitorWidgetContext {
    /// Preview helper: replace `now` while keeping the production context channel.
    func at(_ date: Date) -> MonitorWidgetContext {
        var copy = self
        copy.now = date
        return copy
    }
}
#endif

struct MonitorHistorySnapshot: Sendable, Equatable {
    var sampleTimes: [Double] = []
    var cpuTotal: [Double] = []
    var cpuUser: [Double] = []
    var cpuSystem: [Double] = []
    var memUsedFraction: [Double] = []
    /// Aligned with `memUsedFraction` — curve colors by discrete pressure, not used%.
    var memPressure: [String] = []
    /// App/wired/compressed fractions of total RAM, aligned with `memUsedFraction`.
    var memAppFraction: [Double] = []
    var memWiredFraction: [Double] = []
    var memCompressedFraction: [Double] = []
    var gpuSampleTimes: [Double] = []
    var gpuDevice: [Double] = []
    /// Aligned with `gpuSampleTimes`; nil where that sample lacked the key.
    var gpuRenderer: [Double?] = []
    var gpuTiler: [Double?] = []
    var netRx: [Double] = []
    var netTx: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []

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
    /// The last `seconds` of a series aligned with `sampleTimes`. Not `suffix(seconds)`: that only equals N seconds
    /// while the board samples at exactly 1 Hz, and the refresh slider spans 0.2…2 Hz — at the slow end a "60s" chart
    /// was drawing five minutes of history, at the fast end thirty seconds. CPU and GPU were moved onto their sample
    /// times when the slider landed; Memory, Disk, and Network were not. Falls back to a sample count when the times
    /// are missing or out of step with the series — the only case where nothing better is known.
    func windowed(_ series: [Double], seconds: Int, minimumPoints: Int = 2) -> [Double] {
        guard sampleTimes.count == series.count, let last = sampleTimes.last else {
            return Array(series.suffix(max(seconds, minimumPoints)))
        }
        let cutoff = last - Double(seconds)
        let inWindow = zip(sampleTimes, series).filter { $0.0 >= cutoff }.map(\.1)
        // A chart needs two points to draw a segment.
        return inWindow.count >= minimumPoints ? inWindow : Array(series.suffix(minimumPoints))
    }

    static func historyWindowSeconds(optionSeconds: Double?, fallbackSeconds: Int) -> Int {
        guard let optionSeconds, optionSeconds.isFinite, optionSeconds > 0 else {
            return fallbackSeconds
        }
        // isFinite alone does not bound the conversion: 1e300 is finite and
        // Int(_:) traps on it. Clamp in Double space before converting.
        return Int(min(max(optionSeconds.rounded(), 2), 86400))
    }
}

@MainActor
final class MonitorHistoryStore: ObservableObject {
    @Published private(set) var current = MonitorHistorySnapshot()

    private let capacity: Int
    private var lastSampleAt: Double?
    private var lastGPUSampleAt: Double?

    /// 240, not 120: the longest offered window is 120 s and the refresh
    /// slider goes down to 0.5 s per sample, so a 120-sample buffer could only
    /// ever hand back 60 s of history for a chart labelled 120 s.
    init(capacity: Int = 240) {
        self.capacity = max(capacity, 2)
    }

    func reset() {
        current = MonitorHistorySnapshot()
        lastSampleAt = nil
        lastGPUSampleAt = nil
    }

    func ingest(_ snapshot: MonitorSnapshot) {
        let t = snapshot.timestamp > 0 ? snapshot.timestamp : Date().timeIntervalSince1970
        var next = current
        guard let sys = snapshot.system else { return }
        if let last = lastSampleAt, t <= last { return }
        let dt = lastSampleAt.map { min(max(t - $0, 0), 10) } ?? 0
        lastSampleAt = t
        next.sampleTimes.append(t)
        next.cpuTotal.append(sys.cpuTotal)
        next.cpuUser.append(sys.cpuUser)
        next.cpuSystem.append(sys.cpuSystem)
        let memFraction = sys.memTotalBytes > 0
            ? Double(sys.memUsedBytes) / Double(sys.memTotalBytes) : 0
        next.memUsedFraction.append(memFraction)
        next.memPressure.append(sys.memPressure)
        let total = Double(sys.memTotalBytes)
        let breakdown = sys.memBreakdown
        next.memAppFraction.append(total > 0 ? Double(breakdown?.appBytes ?? 0) / total : 0)
        next.memWiredFraction.append(total > 0 ? Double(breakdown?.wiredBytes ?? 0) / total : 0)
        next.memCompressedFraction.append(total > 0 ? Double(breakdown?.compressedBytes ?? 0) / total : 0)
        next.netRx.append(sys.netRxBytesPerSec)
        next.netTx.append(sys.netTxBytesPerSec)
        next.diskRead.append(sys.diskReadBytesPerSec)
        next.diskWrite.append(sys.diskWriteBytesPerSec)

        if let gpu = sys.gpuUsage {
            let gpuAt = sys.gpuSampledAt ?? t
            if lastGPUSampleAt != gpuAt {
                lastGPUSampleAt = gpuAt
                next.gpuSampleTimes.append(gpuAt)
                next.gpuDevice.append(gpu)
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

        next.cpuPeak = next.cpuTotal.max() ?? 0
        next.gpuPeak = next.gpuDevice.max() ?? 0
        next.netRxPeak = next.netRx.max() ?? 0
        next.netTxPeak = next.netTx.max() ?? 0
        next.diskReadPeak = next.diskRead.max() ?? 0
        next.diskWritePeak = next.diskWrite.max() ?? 0

        next.netRxSessionBytes += sys.netRxBytesPerSec * dt
        next.netTxSessionBytes += sys.netTxBytesPerSec * dt
        next.diskReadSessionBytes += sys.diskReadBytesPerSec * dt
        next.diskWriteSessionBytes += sys.diskWriteBytesPerSec * dt

        current = next
    }

    private func trim<T>(_ array: inout [T]) {
        if array.count > capacity {
            array.removeFirst(array.count - capacity)
        }
    }
}
