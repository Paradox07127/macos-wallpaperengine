import Foundation
import LiveWallpaperCore

/// The fixed reading the inspector's "Sample data" preview draws. Every metric
/// group is marked available and every optional detail is filled in, so all 24
/// card kind × size combinations show their full content — that is the whole
/// point of the mode: checking long names and crowded layouts without waiting
/// for the machine to happen to be busy.
@MainActor
enum MonitorBoardPreviewFixture {
    /// A stable instant, so two renders of the sample mode are byte-identical
    /// and a chart drawn from it never moves.
    static let referenceDate = Date(timeIntervalSince1970: 1_760_000_000)

    static func sample(
        at reference: Date = referenceDate
    ) -> (snapshot: MonitorSnapshot, history: MonitorHistorySnapshot, capturedAt: Date) {
        let snapshot = snapshot(at: reference)
        return (snapshot, history(from: snapshot, at: reference), reference)
    }

    static func snapshot(at reference: Date = referenceDate) -> MonitorSnapshot {
        let now = reference.timeIntervalSince1970
        var system = MonitorSystemSnapshot(
            cpuTotal: 0.42, cpuUser: 0.30, cpuSystem: 0.12,
            perCore: [0.21, 0.34, 0.47, 0.52, 0.71, 0.18, 0.83, 0.39],
            memUsedBytes: 21_000_000_000, memTotalBytes: 32_000_000_000,
            gpuUsage: 0.54,
            netRxBytesPerSec: 8_400_000, netTxBytesPerSec: 1_200_000,
            diskReadBytesPerSec: 12_000_000, diskWriteBytesPerSec: 3_000_000,
            batteryLevel: 0.72, batteryCharging: false
        )
        system.memPressure = "normal"
        system.memBreakdown = MonitorMemoryBreakdown(
            appBytes: 14_000_000_000, wiredBytes: 4_000_000_000,
            compressedBytes: 3_000_000_000, cachedFilesBytes: 2_000_000_000
        )
        system.cpuInfo = MonitorCPUInfo(
            deviceName: "Apple M4 Pro", coreCount: 8,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 4),
                MonitorCPUCoreGroup(name: "Efficiency", physicalCount: 4),
            ]
        )
        system.gpuDeviceName = "Apple M4 Pro"
        system.gpuRendererUtil = 0.37
        system.gpuTilerUtil = 0.18
        system.gpuSampledAt = now
        system.netInterfaces = [
            MonitorNetworkInterface(
                name: "en0", rxBytesPerSec: 8_400_000, txBytesPerSec: 1_200_000,
                addresses: ["192.168.1.101"], isActive: true
            ),
        ]
        system.netPath = MonitorNetworkPath(status: "satisfied", interfaceType: "wifi")
        system.powerSource = "battery"
        system.sensors = MonitorSensorReadings(cpuTempC: 53, gpuTempC: 49, fanRPM: [1200])
        system.aneFootprintPresent = true
        system.aneFootprintBytes = 240_000_000
        system.aneProcesses = [
            MonitorANEProcess(name: "Image Playground", footprintBytes: 240_000_000),
            MonitorANEProcess(name: "Photos", footprintBytes: 96_000_000),
        ]
        system.topProcesses = topProcesses()
        system.topIOProcesses = topProcesses()
        system.sampledAt = now
        system.metricSamples = Dictionary(
            uniqueKeysWithValues: MonitorWidgetKind.allCases.map {
                ($0.rawValue, MonitorMetricSample(available: true, sampledAt: now, interval: 1))
            }
        )
        return MonitorSnapshot(
            timestamp: now, system: system, agents: agentSessions(at: now)
        )
    }

    /// The series behind the sample charts: one minute at 1 Hz ending at the
    /// reference, so every window the board offers has something to draw.
    static func history(
        from snapshot: MonitorSnapshot, at reference: Date = referenceDate
    ) -> MonitorHistorySnapshot {
        let now = reference.timeIntervalSince1970
        let store = MonitorHistoryStore()
        for index in 0 ..< 120 {
            let age = Double(119 - index)
            var frame = snapshot
            frame.timestamp = now - age
            frame.system?.sampledAt = now - age
            frame.system?.gpuSampledAt = now - age
            // A visible, repeatable wave rather than a flat line, so the shape
            // of a chart is checkable at every size.
            let phase = Double(index) / 12
            frame.system?.cpuTotal = 0.32 + 0.22 * sin(phase)
            frame.system?.cpuUser = 0.22 + 0.14 * sin(phase)
            frame.system?.cpuSystem = 0.10 + 0.06 * sin(phase + 1)
            frame.system?.gpuUsage = 0.44 + 0.18 * sin(phase + 2)
            frame.system?.gpuRendererUtil = 0.30 + 0.12 * sin(phase + 2)
            frame.system?.gpuTilerUtil = 0.16 + 0.08 * sin(phase + 3)
            frame.system?.netRxBytesPerSec = 6_000_000 + 3_000_000 * (1 + sin(phase))
            frame.system?.netTxBytesPerSec = 900_000 + 600_000 * (1 + sin(phase + 1))
            frame.system?.diskReadBytesPerSec = 9_000_000 + 5_000_000 * (1 + sin(phase + 2))
            frame.system?.diskWriteBytesPerSec = 2_000_000 + 1_500_000 * (1 + sin(phase + 3))
            store.ingest(frame)
        }
        return store.current
    }

    private static func topProcesses() -> [MonitorProcessSample] {
        let names = [
            "A deliberately long application name",
            "Xcode", "Safari", "kernel_task", "WindowServer",
            "Music", "Terminal", "Photos", "Mail", "Finder",
        ]
        return names.enumerated().map { index, name in
            MonitorProcessSample(
                name: name,
                cpuPercent: index == 0 ? 327 : Double(48 - index * 4),
                memBytes: UInt64(1_400_000_000 - index * 90_000_000),
                pid: 400 + index,
                kind: index < 4 ? "app" : "background",
                ioReadBytesPerSec: Double(9_000_000 - index * 600_000),
                ioWriteBytesPerSec: Double(3_000_000 - index * 200_000)
            )
        }
    }

    private static func agentSessions(at now: Double) -> [MonitorAgentSessionState] {
        [
            MonitorAgentSessionState(
                id: "claude:preview-1", provider: .claude,
                projectName: "LiveWallpaper", status: .needsInput,
                statusDetail: nil, model: "opus", gitBranch: "main",
                startedAt: now - 1800, lastEventAt: now - 20, processAlive: true,
                turnCount: 34,
                tokens: MonitorTokenTotals(
                    input: 412_000, output: 38000, cacheRead: 1_900_000, cacheWrite: 120_000
                ),
                waitSince: now - 20
            ),
            MonitorAgentSessionState(
                id: "codex:preview-2", provider: .codex,
                projectName: "A deliberately long project name", status: .running,
                statusDetail: nil, model: "gpt-5", gitBranch: "review",
                startedAt: now - 600, lastEventAt: now - 3, processAlive: true,
                turnCount: 8,
                tokens: MonitorTokenTotals(input: 90000, output: 12000)
            ),
        ]
    }
}
