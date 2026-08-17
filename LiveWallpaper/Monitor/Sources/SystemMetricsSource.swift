import Darwin
import Foundation

/// Publishes host CPU, memory, GPU, thermal, network, disk, and power metrics.
final class SystemMetricsSource: MonitorDataSource, Sendable {
    let sourceID = "system"

    struct Options: Sendable, Equatable {
        var gpu: Bool = true
        var topProcesses: Bool = false
        var ane: Bool = false
        var accessories: Bool = true
        /// SMC temperature/fan reads (CPU/GPU widgets' optional sensor row).
        var sensors: Bool = false
        /// Per-app disk I/O attribution (rusage deltas inside the top-processes walk; needs the `process-info-rusage` sbpl exception).
        var processIO: Bool = false

        // Base metric groups, keyed by whether any placed widget reads them.
        // Default true: the legacy no-widget-info init must keep sampling
        // everything (fail open — a missing demand must never starve a widget).
        /// Host CPU ticks, per-core loads, CPU identity, and load averages (CPU widget).
        var cpu: Bool = true
        /// VM stats, breakdown, swap, and pressure (Memory widget).
        var memory: Bool = true
        /// Interface counters and the NWPathMonitor (Network widget).
        var network: Bool = true
        /// Block-storage read/write counters (Disk widget).
        var disk: Bool = true
        /// Battery/adapter state (Power widget).
        var power: Bool = true

        static let `default` = Options()
    }

    typealias TopProcessesSampler = @Sendable (
        _ previous: [Int32: SystemMetricsSamplers.ProcessCPUCounters],
        _ interval: TimeInterval,
        _ includeIO: Bool
    ) -> SystemMetricsSamplers.TopProcessesResult

    static let defaultTopProcessesSampler: TopProcessesSampler = { previous, interval, includeIO in
        SystemMetricsSamplers.sampleTopProcesses(
            previous: previous,
            interval: interval,
            limit: 12,
            includeIO: includeIO
        )
    }

    private let interval: TimeInterval
    private let gpuSampleCadence: Int
    private let topProcessSampleSeconds: TimeInterval
    private let options: Options
    private let loadAverageSampler: @Sendable () -> [Double]?
    private let topProcessesSampler: TopProcessesSampler
    private let pressure: any MemoryPressureReading
    private let state = MetricsState()
    private let netPath = NetworkPathObserver()

    init(
        includeTopProcesses: Bool = false,
        interval: TimeInterval = 2.0,
        gpuSampleCadence: Int = 3,
        loadAverageSampler: @escaping @Sendable () -> [Double]? = {
            SystemMetricsSamplers.sampleLoadAverages()
        },
        memoryPressureReader: any MemoryPressureReading = SystemMemoryPressureWatcher.shared
    ) {
        var options = Options.default
        options.topProcesses = includeTopProcesses
        self.options = options
        self.interval = interval
        self.gpuSampleCadence = gpuSampleCadence
        self.topProcessSampleSeconds = 5.0
        self.loadAverageSampler = loadAverageSampler
        self.topProcessesSampler = Self.defaultTopProcessesSampler
        pressure = memoryPressureReader
    }

    init(
        options: Options,
        interval: TimeInterval = 2.0,
        gpuSampleCadence: Int = 3,
        topProcessSampleSeconds: TimeInterval = 5.0,
        loadAverageSampler: @escaping @Sendable () -> [Double]? = {
            SystemMetricsSamplers.sampleLoadAverages()
        },
        topProcessesSampler: @escaping TopProcessesSampler = SystemMetricsSource.defaultTopProcessesSampler,
        memoryPressureReader: any MemoryPressureReading = SystemMemoryPressureWatcher.shared
    ) {
        self.options = options
        self.interval = interval
        self.gpuSampleCadence = gpuSampleCadence
        self.topProcessSampleSeconds = topProcessSampleSeconds
        self.loadAverageSampler = loadAverageSampler
        self.topProcessesSampler = topProcessesSampler
        pressure = memoryPressureReader
    }

    /// Wire mapping only — never owns/mutates the app-wide watcher's lifecycle.
    static func memoryPressureWireValue(from reader: any MemoryPressureReading) -> String {
        reader.currentLevel().rawValue
    }

    #if DEBUG
    // Test-only introspection: proves the path monitor is demand-gated, not
    // merely its snapshot dropped.
    var debugNetPathStarted: Bool { netPath.debugIsStarted }
    #endif

    func start(sink: any MonitorSnapshotSink) async {
        if options.network { netPath.start() }
        await state.startLoop(
            interval: interval,
            gpuSampleCadence: gpuSampleCadence,
            topProcessSampleSeconds: topProcessSampleSeconds,
            options: options,
            loadAverageSampler: loadAverageSampler,
            topProcessesSampler: topProcessesSampler,
            pressure: pressure,
            netPath: netPath,
            sink: sink
        )
    }

    func stop() async {
        await state.stopLoop()
        netPath.stop()
    }

    // MARK: - Delta bookkeeping + poll loop

    /// Cross-poll state: counters, GPU cadence, HW identity, running Task.
    private actor MetricsState {
        private var task: Task<Void, Never>?
        private var updateCount = 0
        private var lastSampleTime: Date?
        private var prevCPU: SystemMetricsSamplers.CPURawCounters?
        private var prevNet: (rx: UInt64, tx: UInt64)?
        private var prevNetInterfaces: [String: SystemMetricsSamplers.InterfaceCounters] = [:]
        private var prevDisk: (read: UInt64, written: UInt64)?
        private var lastGPU: SystemMetricsSamplers.GPUSample?
        private var lastGPUSampledAt: Double?
        private var prevProcessCounters: [Int32: SystemMetricsSamplers.ProcessCPUCounters] = [:]
        private var lastTopProcesses: [MonitorProcessSample]?
        private var lastTopIOProcesses: [MonitorProcessSample]?
        private var lastTopProcessesSampledAt: Date?
        private var lastANE: SystemMetricsSamplers.ANESample?
        private var lastANESampledAt: Date?
        /// Lazily opened on the first sensors-enabled tick; caches its SMC connection.
        private var sensorSampler: SensorSampler?
        private var cpuInfo: MonitorCPUInfo?
        private var gpuDeviceName: String?

        func startLoop(
            interval: TimeInterval,
            gpuSampleCadence: Int,
            topProcessSampleSeconds: TimeInterval,
            options: Options,
            loadAverageSampler: @escaping @Sendable () -> [Double]?,
            topProcessesSampler: @escaping TopProcessesSampler,
            pressure: any MemoryPressureReading,
            netPath: NetworkPathObserver,
            sink: any MonitorSnapshotSink
        ) {
            task?.cancel()
            task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await tick(
                        interval: interval,
                        gpuSampleCadence: gpuSampleCadence,
                        topProcessSampleSeconds: topProcessSampleSeconds,
                        options: options,
                        loadAverageSampler: loadAverageSampler,
                        topProcessesSampler: topProcessesSampler,
                        pressure: pressure,
                        netPath: netPath,
                        sink: sink
                    )
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        return
                    }
                }
            }
        }

        func stopLoop() async {
            guard let task else { return }
            self.task = nil
            task.cancel()
            // Await the in-flight tick so a running poll can't publish into the
            // shared broker after Runtime.stopPipeline() has cleared it.
            await task.value
        }

        private func tick(
            interval: TimeInterval,
            gpuSampleCadence: Int,
            topProcessSampleSeconds: TimeInterval,
            options: Options,
            loadAverageSampler: @Sendable () -> [Double]?,
            topProcessesSampler: TopProcessesSampler,
            pressure: any MemoryPressureReading,
            netPath: NetworkPathObserver,
            sink: any MonitorSnapshotSink
        ) async {
            updateCount += 1
            let now = Date()
            let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? interval
            lastSampleTime = now

            // Base metric groups only run when a placed widget still reads
            // them: the probe is skipped, not just its result hidden.
            var cpuSample: SystemMetricsSamplers.CPUSample?
            if options.cpu {
                if cpuInfo == nil {
                    cpuInfo = SystemMetricsSamplers.sampleCPUInfo()
                }
                let cpu = SystemMetricsSamplers.sampleCPU(previous: prevCPU)
                prevCPU = cpu.counters
                cpuSample = cpu.sample
            }

            var memory: SystemMetricsSamplers.MemorySample?
            var swapUsedBytes: UInt64?
            if options.memory {
                memory = SystemMetricsSamplers.sampleMemory()
                swapUsedBytes = SystemMetricsSamplers.sampleSwapUsedBytes()
            }

            var netRx: Double = 0
            var netTx: Double = 0
            var netInterfaces: [MonitorNetworkInterface] = []
            var pathSnapshot: NetworkPathObserver.Snapshot?
            if options.network {
                let netRaw = SystemMetricsSamplers.sampleNetworkCounters()
                netRx = SystemMetricsSamplers.rate(current: netRaw.rx, previous: prevNet?.rx ?? netRaw.rx, interval: elapsed)
                netTx = SystemMetricsSamplers.rate(current: netRaw.tx, previous: prevNet?.tx ?? netRaw.tx, interval: elapsed)
                pathSnapshot = netPath.currentSnapshot()
                netInterfaces = SystemMetricsSamplers.networkInterfaces(
                    previous: prevNetInterfaces,
                    current: netRaw.interfaces,
                    interval: elapsed,
                    activeName: pathSnapshot?.activeInterfaceName
                )
                prevNet = (netRaw.rx, netRaw.tx)
                prevNetInterfaces = Dictionary(
                    netRaw.interfaces.map { ($0.name, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }

            var diskRead: Double = 0
            var diskWrite: Double = 0
            if options.disk {
                let diskRaw = SystemMetricsSamplers.sampleDiskCounters()
                diskRead = SystemMetricsSamplers.rate(current: diskRaw.read, previous: prevDisk?.read ?? diskRaw.read, interval: elapsed)
                diskWrite = SystemMetricsSamplers.rate(current: diskRaw.written, previous: prevDisk?.written ?? diskRaw.written, interval: elapsed)
                prevDisk = diskRaw
            }

            if options.gpu, MonitoringCadence.shouldSampleGPU(updateCount: updateCount, cadence: gpuSampleCadence) {
                lastGPU = SystemMetricsSamplers.sampleGPU()
                lastGPUSampledAt = now.timeIntervalSince1970
                if gpuDeviceName == nil {
                    gpuDeviceName = SystemMetricsSamplers.sampleGPUDeviceName()
                }
            }

            let power: SystemMetricsSamplers.PowerSample? =
                options.power ? SystemMetricsSamplers.samplePower() : nil

            var accessories: [MonitorAccessoryBattery]?
            if options.accessories {
                let read = SystemMetricsSamplers.sampleAccessoryBatteries()
                accessories = read.isEmpty ? nil : read
            }

            // The full process-table walk rivals ANE as the priciest probe, so it
            // shares ANE's wall-clock cadence pattern instead of running every base
            // tick. CPU%/IO deltas must divide by the span since the *last walk*,
            // not the base tick, or skipping would inflate them by the skip factor.
            var topProcesses: [MonitorProcessSample]?
            var topIOProcesses: [MonitorProcessSample]?
            if options.topProcesses || options.processIO {
                if shouldSampleTopProcesses(now: now, cadenceSeconds: topProcessSampleSeconds) {
                    let walkElapsed = lastTopProcessesSampledAt.map { now.timeIntervalSince($0) } ?? elapsed
                    let result = topProcessesSampler(
                        prevProcessCounters,
                        walkElapsed,
                        options.processIO
                    )
                    prevProcessCounters = result.counters
                    lastTopProcesses = result.samples.isEmpty ? nil : result.samples
                    lastTopIOProcesses = result.ioSamples.isEmpty ? nil : result.ioSamples
                    lastTopProcessesSampledAt = now
                }
                topProcesses = lastTopProcesses
                topIOProcesses = lastTopIOProcesses
            }

            // ANE's per-PID rusage walk is the priciest probe → ≥5s cadence, gated.
            if options.ane, shouldSampleANE(now: now) {
                lastANE = SystemMetricsSamplers.sampleANE()
                lastANESampledAt = now
            }

            // SMC temperature/fan speed. The reader caches its connection; a first-tick
            // sandbox denial makes every sample nil, so the sensor rows stay hidden.
            var sensors: MonitorSensorReadings?
            if options.sensors {
                if sensorSampler == nil {
                    sensorSampler = SensorSampler()
                }
                sensors = sensorSampler?.sample()
            }

            let loadAverages = options.cpu ? loadAverageSampler() : nil

            let snapshot = MonitorSystemSnapshot(
                cpuTotal: cpuSample?.total ?? 0,
                cpuUser: cpuSample?.user ?? 0,
                cpuSystem: cpuSample?.system ?? 0,
                perCore: (cpuSample?.perCore).flatMap { $0.isEmpty ? nil : $0 },
                memUsedBytes: memory?.usedBytes ?? 0,
                memTotalBytes: memory?.totalBytes ?? 0,
                memPressure: options.memory
                    ? SystemMetricsSource.memoryPressureWireValue(from: pressure)
                    : "normal",
                swapUsedBytes: swapUsedBytes,
                gpuUsage: lastGPU?.deviceUtil,
                thermalState: SystemMetricsSamplers.thermalString(ProcessInfo.processInfo.thermalState),
                netRxBytesPerSec: netRx,
                netTxBytesPerSec: netTx,
                diskReadBytesPerSec: diskRead,
                diskWriteBytesPerSec: diskWrite,
                batteryLevel: power?.battery?.level,
                batteryCharging: power?.battery?.charging,
                loadAverage1: loadAverages?.first,
                topProcesses: topProcesses,
                cpuInfo: cpuInfo,
                cpuLoadAvg: loadAverages,
                memBreakdown: memory?.breakdown,
                gpuDeviceName: gpuDeviceName,
                gpuCoreCount: lastGPU?.coreCount,
                gpuSampledAt: lastGPUSampledAt,
                gpuRendererUtil: lastGPU?.rendererUtil,
                gpuTilerUtil: lastGPU?.tilerUtil,
                netInterfaces: netInterfaces.isEmpty ? nil : netInterfaces,
                netPath: pathSnapshot?.path,
                batteryIsCharged: power?.battery?.isCharged,
                powerSource: power?.powerSource,
                batteryMinutesRemaining: power?.battery?.minutesRemaining,
                batteryMinutesToFull: power?.battery?.minutesToFull,
                lowPowerMode: power?.lowPowerMode,
                accessories: accessories,
                aneProcesses: lastANE.flatMap { $0.processes.isEmpty ? nil : $0.processes },
                aneFootprintPresent: lastANE?.hasFootprint,
                aneFootprintBytes: lastANE?.totalFootprintBytes,
                sensors: sensors,
                topIOProcesses: topIOProcesses,
                gpuMemUsedBytes: lastGPU?.memUsedBytes
            )

            // Bail before publishing if stop() cancelled us mid-tick, so a late
            // poll can't land in the broker after the pipeline was torn down.
            guard !Task.isCancelled else { return }
            await sink.updateSystem(snapshot)
            await sink.updateHealth(MonitorSourceHealth(
                sourceID: "system",
                state: "ok",
                detail: nil,
                lastUpdateAt: now.timeIntervalSince1970
            ))
        }

        private func shouldSampleTopProcesses(now: Date, cadenceSeconds: TimeInterval) -> Bool {
            guard let last = lastTopProcessesSampledAt else { return true }
            return now.timeIntervalSince(last) >= cadenceSeconds
        }

        private func shouldSampleANE(now: Date) -> Bool {
            guard let last = lastANESampledAt else { return true }
            return now.timeIntervalSince(last) >= 5.0
        }
    }
}

/// GPU sampling is 3× more expensive than the rest, so it runs every Nth poll — matching `SystemMonitor`'s cadence policy but kept local to avoid depending on the Pro package.
enum MonitoringCadence {
    static func shouldSampleGPU(updateCount: Int, cadence: Int) -> Bool {
        guard cadence > 1, updateCount > 1 else { return true }
        return updateCount % cadence == 0
    }
}
