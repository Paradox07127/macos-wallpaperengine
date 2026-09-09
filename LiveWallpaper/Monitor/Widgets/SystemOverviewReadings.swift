import Foundation
import LiveWallpaperCore

enum SystemOverviewOptions {
    static let defaultHistoryWindow = 60

    static func showsSensors(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.size == .large && (placement.options[MonitorWidgetDraft.showSensorsKey]?.boolValue ?? true)
    }

    static func showsHistory(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.size == .large && (placement.options[MonitorWidgetDraft.showTrendKey]?.boolValue ?? true)
    }

    static func historyWindow(_ placement: MonitorWidgetPlacement) -> Int {
        MonitorWidgetDraft.historyWindowTag(placement, clearValue: defaultHistoryWindow)
    }
}

/// Each instrument retains its own availability and freshness. In particular,
/// a missing GPU must not blank the CPU, or turn an unmeasured rate into zero.
struct SystemOverviewReadings {
    let cpu: Double?
    let memory: Double?
    let gpu: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64?
    let memoryPressure: String?
    let download: Double?
    let upload: Double?
    let diskRead: Double?
    let diskWrite: Double?
    let battery: Double?
    let charging: Bool
    let powerSource: String?
    let cpuTemperature: Double?
    let gpuTemperature: Double?
    let fanRPM: Double?

    init(context: MonitorWidgetContext) {
        func available(_ kind: MonitorWidgetKind) -> Bool {
            var instrument = context
            instrument.placement.kind = kind
            return instrument.readingsNotice == nil
        }
        func finite(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite ? $0 : nil }
        }
        func fraction(_ value: Double?) -> Double? {
            finite(value).map { min(1, max(0, $0)) }
        }
        func rate(_ value: Double?) -> Double? {
            finite(value).map { max(0, $0) }
        }

        let system = context.snapshot.system
        cpu = available(.cpu) ? fraction(system?.cpuTotal) : nil
        gpu = available(.gpu) ? fraction(system?.gpuUsage) : nil
        let hasMemory = available(.memory) && (system?.memTotalBytes ?? 0) > 0
        memoryUsed = hasMemory ? system?.memUsedBytes : nil
        memoryTotal = hasMemory ? system?.memTotalBytes : nil
        memoryPressure = hasMemory ? system?.memPressure : nil
        if let used = memoryUsed, let total = memoryTotal {
            memory = fraction(Double(used) / Double(total))
        } else {
            memory = nil
        }
        download = available(.network) ? rate(system?.netRxBytesPerSec) : nil
        upload = available(.network) ? rate(system?.netTxBytesPerSec) : nil
        diskRead = available(.disk) ? rate(system?.diskReadBytesPerSec) : nil
        diskWrite = available(.disk) ? rate(system?.diskWriteBytesPerSec) : nil
        battery = available(.power) ? fraction(system?.batteryLevel) : nil
        charging = available(.power) && system?.batteryCharging == true
        powerSource = available(.power) ? system?.powerSource : nil
        cpuTemperature = available(.cpu) ? finite(system?.sensors?.cpuTempC ?? system?.sensors?.socTempC) : nil
        gpuTemperature = available(.gpu) ? finite(system?.sensors?.gpuTempC) : nil
        fanRPM = available(.cpu) ? system?.sensors?.fanRPM?.filter { $0.isFinite && $0 >= 0 }.max() : nil
    }
}
