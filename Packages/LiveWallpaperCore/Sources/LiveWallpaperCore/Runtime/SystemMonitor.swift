import Foundation
import Observation
import Darwin
import IOKit

public struct MonitoringReferenceCounter {
    public private(set) var count = 0

    public init() {}

    public mutating func start() -> Bool {
        count += 1
        return count == 1
    }

    public mutating func stop() -> Bool {
        guard count > 0 else { return false }
        count -= 1
        return count == 0
    }

    /// Drop all retains; returns whether any consumer had been holding.
    @discardableResult
    public mutating func reset() -> Bool {
        guard count > 0 else { return false }
        count = 0
        return true
    }
}

public enum MonitoringCadencePolicy {
    public static func shouldSampleGPU(updateCount: Int, cadence: Int) -> Bool {
        guard cadence > 1, updateCount > 1 else { return true }
        return updateCount % cadence == 0
    }
}

public enum MonitoringStartPolicy {
    /// Defer first sample so dashboard layout finishes before SwiftUI writes.
    public static let initialSampleDelay: Duration = .milliseconds(350)
}

/// Collapsed pill status-dot pressure (thermal vs utilisation, take max).
public enum SystemLoadLevel: Int, Sendable, Comparable {
    case calm = 0
    case elevated = 1
    case high = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor @Observable
public final class SystemMonitor {
    public static let shared = SystemMonitor()

    public private(set) var cpuUsage: Double = 0
    public private(set) var systemCpuUsage: Double = 0
    public private(set) var memoryUsage: UInt64 = 0
    public private(set) var totalMemory: UInt64 = 0
    public private(set) var systemMemoryUsage: Double = 0
    /// Percent utilization when the IOAccelerator counter is readable.
    /// `nil` means unavailable; it must not be rendered as a real 0% sample.
    public private(set) var gpuUsage: Double?
    // Thermal *pressure* (not °C). This lightweight strip does not poll SMC;
    // measured temperatures live only in the optional Monitor sensor widgets.
    public private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    // MARK: - Configuration

    @ObservationIgnored private var updateInterval: TimeInterval = 2.0
    @ObservationIgnored private let gpuSampleCadence = 3
    @ObservationIgnored private var resourceUpdateCount = 0
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var references = MonitoringReferenceCounter()
    @ObservationIgnored private var prevHostCpuLoad: host_cpu_load_info?
    @ObservationIgnored private var isShutdown = false

    private init() {
        totalMemory = ProcessInfo.processInfo.physicalMemory
    }

    // MARK: - Public Methods

    public func startMonitoring() {
        guard !isShutdown else { return }
        guard references.start() else { return }
        let interval = updateInterval
        let initialSampleDelay = MonitoringStartPolicy.initialSampleDelay
        resourceUpdateCount = 0
        updateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: initialSampleDelay)
            } catch {
                return
            }
            await self?.sampleAndApply()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                await self?.sampleAndApply()
            }
        }
    }

    public func stopMonitoring() {
        guard !isShutdown else { return }
        guard references.stop() else { return }
        updateTask?.cancel()
        updateTask = nil
    }

    /// Termination barrier: reset retains so later onDisappear cannot restart sampling.
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        references.reset()
        updateTask?.cancel()
        updateTask = nil
        resourceUpdateCount = 0
        prevHostCpuLoad = nil
    }

    public func formattedMemoryUsage() -> String { FormatUtils.formatBytes(memoryUsage) }
    public func formattedTotalMemory() -> String { FormatUtils.formatBytes(totalMemory) }
    public func memoryPercentage() -> Double {
        guard totalMemory > 0 else { return 0 }
        return Double(memoryUsage) / Double(totalMemory) * 100.0
    }

    public var thermalStateDescription: String {
        switch thermalState {
        case .nominal:
            return String(localized: "Normal", defaultValue: "Normal", bundle: .appLanguage, comment: "Thermal state label.")
        case .fair:
            return String(localized: "Elevated", defaultValue: "Elevated", bundle: .appLanguage, comment: "Thermal state label.")
        case .serious:
            return String(localized: "High", defaultValue: "High", bundle: .appLanguage, comment: "Thermal state label.")
        case .critical:
            return String(localized: "Critical", defaultValue: "Critical", bundle: .appLanguage, comment: "Thermal state label.")
        @unknown default:
            return String(localized: "Unknown", defaultValue: "Unknown", bundle: .appLanguage, comment: "Thermal state label.")
        }
    }

    /// Peak thermal/utilisation; 50/80% cuts match dashboard gauge colors.
    public var loadLevel: SystemLoadLevel {
        let peak = max(systemCpuUsage, gpuUsage ?? 0, systemMemoryUsage * 100)
        let utilisation: SystemLoadLevel = peak >= 80 ? .high : (peak >= 50 ? .elevated : .calm)
        let thermal: SystemLoadLevel
        switch thermalState {
        case .nominal:           thermal = .calm
        case .fair:              thermal = .elevated
        case .serious, .critical: thermal = .high
        @unknown default:        thermal = .calm
        }
        return max(utilisation, thermal)
    }

    // MARK: - Update Loop

    private func sampleAndApply() async {
        resourceUpdateCount += 1
        let updateCount = resourceUpdateCount
        let prev = HostCpuLoadSnapshot(value: prevHostCpuLoad)
        let shouldSampleGPU = MonitoringCadencePolicy.shouldSampleGPU(
            updateCount: updateCount,
            cadence: gpuSampleCadence
        )

        let sample = await Task.detached(priority: .utility) { () -> SystemSample in
            let cpuResult = SystemMonitor.sampleSystemCPUUsage(prev: prev.value)
            return SystemSample(
                cpuUsage: SystemMonitor.sampleAppCPUUsage(),
                systemCpuUsage: cpuResult.usage,
                newHostCpuLoad: HostCpuLoadSnapshot(value: cpuResult.newPrev),
                memoryUsage: SystemMonitor.sampleAppMemoryUsage(),
                systemMemoryUsage: SystemMonitor.sampleSystemMemoryUsage(),
                gpuUsage: shouldSampleGPU ? SystemMonitor.sampleGPUUsage() : nil,
                didAttemptGPUSample: shouldSampleGPU,
                thermalState: ProcessInfo.processInfo.thermalState
            )
        }.value

        guard !Task.isCancelled else { return }
        applySample(sample)
    }

    private func applySample(_ sample: SystemSample) {
        if abs(cpuUsage - sample.cpuUsage) > Self.percentMaterialEpsilon {
            cpuUsage = sample.cpuUsage
        }
        if let systemCpu = sample.systemCpuUsage,
           abs(systemCpuUsage - systemCpu) > Self.percentMaterialEpsilon {
            systemCpuUsage = systemCpu
        }
        prevHostCpuLoad = sample.newHostCpuLoad.value
        if memoryUsage != sample.memoryUsage {
            memoryUsage = sample.memoryUsage
        }
        if abs(systemMemoryUsage - sample.systemMemoryUsage) > Self.ratioMaterialEpsilon {
            systemMemoryUsage = sample.systemMemoryUsage
        }
        if let gpu = sample.gpuUsage {
            if gpuUsage == nil || abs((gpuUsage ?? 0) - gpu) > Self.percentMaterialEpsilon {
                gpuUsage = gpu
            }
        } else if shouldApplyUnavailableGPU(for: sample) {
            gpuUsage = nil
        }
        if thermalState != sample.thermalState {
            thermalState = sample.thermalState
        }
    }

    /// A cadence skip also has `nil`; only clear a previous value on a real GPU poll.
    private func shouldApplyUnavailableGPU(for sample: SystemSample) -> Bool {
        sample.didAttemptGPUSample
    }

    // 2s sample cadence: sub-percent noise only churns SwiftUI.
    @ObservationIgnored private static let percentMaterialEpsilon: Double = 1.0
    @ObservationIgnored private static let ratioMaterialEpsilon: Double = 0.01

    private struct HostCpuLoadSnapshot: @unchecked Sendable {
        let value: host_cpu_load_info?
    }

    private struct SystemSample: @unchecked Sendable {
        let cpuUsage: Double
        let systemCpuUsage: Double?
        let newHostCpuLoad: HostCpuLoadSnapshot
        let memoryUsage: UInt64
        let systemMemoryUsage: Double
        let gpuUsage: Double?
        let didAttemptGPUSample: Bool
        let thermalState: ProcessInfo.ThermalState
    }

    // MARK: - CPU Usage

    nonisolated private static func sampleAppCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)

        let result = task_threads(mach_task_self_, &threadsList, &threadsCount)

        if result == KERN_SUCCESS, let threadsList = threadsList {
            for index in 0..<threadsCount {
                let thread = threadsList[Int(index)]
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

                let threadInfoResult = withUnsafeMutablePointer(to: &threadInfo) { ptr in
                    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) { intPtr in
                        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), intPtr, &threadInfoCount)
                    }
                }

                if threadInfoResult == KERN_SUCCESS {
                    if threadInfo.flags & TH_FLAGS_IDLE == 0 {
                        totalUsageOfCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)
                    }
                }
                mach_port_deallocate(mach_task_self_, thread)
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)),
                          vm_size_t(Int(threadsCount) * MemoryLayout<thread_act_t>.stride))
        }

        let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        return min(totalUsageOfCPU / coreCount * 100, 100.0)
    }

    // MARK: - System-wide CPU Usage

    nonisolated private static func sampleSystemCPUUsage(
        prev: host_cpu_load_info?
    ) -> (usage: Double?, newPrev: host_cpu_load_info?) {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, prev) }

        let newPrev: host_cpu_load_info? = info
        guard let prev else { return (0, newPrev) }

        let userDelta   = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let systemDelta = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idleDelta   = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let niceDelta   = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let busy = userDelta + systemDelta + niceDelta
        let total = busy + idleDelta
        guard total > 0 else { return (nil, newPrev) }
        return (min(100, max(0, busy / total * 100)), newPrev)
    }

    // MARK: - Memory Usage

    nonisolated private static func sampleAppMemoryUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    nonisolated private static func sampleSystemMemoryUsage() -> Double {
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64_data_t()

        host_page_size(hostPort, &pageSize)

        let status = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &hostSize)
            }
        }

        guard status == KERN_SUCCESS else { return 0.0 }

        let used = Double(vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count) * Double(pageSize)
        return used / Double(ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - GPU Usage (via IOKit)

    nonisolated private static func sampleGPUUsage() -> Double? {
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IOAccelerator")

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var gpuUtil: Double?
        var entry: io_registry_entry_t = IOIteratorNext(iterator)

        while entry != 0 {
            let current = entry
            defer { IOObjectRelease(current) }

            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(current, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {

                if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                    if let util = perfStats["GPU Activity(%)"] as? Double {
                        gpuUtil = util
                    } else if let util = perfStats["Device Utilization %"] as? Int {
                        gpuUtil = Double(util)
                    } else if let util = perfStats["gpuCoreUtilizationComponent"] as? Int {
                        gpuUtil = Double(util)
                    }
                }
            }

            entry = IOIteratorNext(iterator)
        }

        return gpuUtil.map { min($0, 100.0) }
    }
}
