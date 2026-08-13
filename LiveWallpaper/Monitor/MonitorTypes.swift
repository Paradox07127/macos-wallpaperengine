import Foundation

// MARK: - Monitor wallpaper data contract (schema v2)
// Single snapshot contract for the widget board. Key names are load-bearing; rename only with `schemaVersion` bump.

enum MonitorAgentProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

enum MonitorAgentStatus: String, Codable, Sendable {
    case running
    case needsInput
    case idle
    case ended
    case unknown

    var attentionPriority: Int {
        switch self {
        case .needsInput: return 4
        case .running: return 3
        case .idle: return 2
        case .unknown: return 1
        case .ended: return 0
        }
    }
}

struct MonitorTokenTotals: Codable, Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    static let zero = MonitorTokenTotals()

    static func + (lhs: Self, rhs: Self) -> Self {
        MonitorTokenTotals(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

/// Live/recent agent session, normalized + privacy-redacted.
struct MonitorAgentSessionState: Codable, Sendable, Equatable, Identifiable {
    var id: String                    // "<provider>:<sessionID>"
    var provider: MonitorAgentProvider
    var projectName: String           // display name only, no full path
    var status: MonitorAgentStatus
    var statusDetail: String?
    var model: String?
    var gitBranch: String?
    var startedAt: Double?            // epoch seconds
    var lastEventAt: Double           // epoch seconds
    var processAlive: Bool
    var turnCount: Int = 0
    var tokens: MonitorTokenTotals = .zero

    var recentEventTimes: [Double]?
    var waitSince: Double?
    /// "toolLoop" | "stale" — metadata-only derivation.
    var warning: String?
    var recentTools: [MonitorAgentToolEvent]?
    var worktreeName: String?
}

/// Tool name only (privacy: never arguments).
struct MonitorAgentToolEvent: Codable, Sendable, Equatable {
    var name: String
    var at: Double                    // epoch seconds
    var ok: Bool?                     // false when the result carried is_error
}

struct MonitorProcessSample: Codable, Sendable, Equatable {
    var name: String
    var cpuPercent: Double
    var memBytes: UInt64
    var pid: Int?
    var bundleID: String?
    var kind: String?                 // app | background | system
    var ioReadBytesPerSec: Double?
    var ioWriteBytesPerSec: Double?
}

// MARK: System hardware identity + per-component detail (v2)

struct MonitorCPUCoreGroup: Codable, Sendable, Equatable {
    /// Real `hw.perflevelN.name` — never a hardcoded P/E guess; "CPU" if unavailable.
    var name: String
    var physicalCount: Int
}

struct MonitorCPUInfo: Codable, Sendable, Equatable {
    var deviceName: String?           // machdep.cpu.brand_string
    var coreCount: Int?               // hw.physicalcpu
    var coreGroups: [MonitorCPUCoreGroup]?
}

struct MonitorMemoryBreakdown: Codable, Sendable, Equatable {
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedFilesBytes: UInt64 = 0
}

struct MonitorNetworkInterface: Codable, Sendable, Equatable {
    var name: String                  // "en0"
    var rxBytesPerSec: Double = 0
    var txBytesPerSec: Double = 0
    var rxPacketsPerSec: Double?
    var txPacketsPerSec: Double?
    var rxErrors: UInt64?
    var txErrors: UInt64?
    var rxDrops: UInt64?
    var addresses: [String]?          // private IPs only (AF_INET/AF_INET6)
    var isActive: Bool?               // NWPath-chosen or highest-traffic
}

struct MonitorNetworkPath: Codable, Sendable, Equatable {
    var status: String = "unknown"    // satisfied | unsatisfied | requiresConnection | unknown
    var interfaceType: String?        // wifi | wired | cellular | other
    var isConstrained: Bool?
    var isExpensive: Bool?
}

struct MonitorAccessoryBattery: Codable, Sendable, Equatable {
    var name: String
    var kind: String?                 // mouse | keyboard | trackpad | other
    var percent: Double
}

struct MonitorANEProcess: Codable, Sendable, Equatable {
    var name: String
    var footprintBytes: UInt64
}

/// Optional read-only Apple SMC values. Individual rows remain hidden when a
/// model or OS version does not expose the corresponding key.
struct MonitorSensorReadings: Codable, Sendable, Equatable {
    var cpuTempC: Double?
    var gpuTempC: Double?
    var socTempC: Double?
    var fanRPM: [Double]?
}

struct MonitorSystemSnapshot: Codable, Sendable, Equatable {
    var cpuTotal: Double = 0          // 0…1 system-wide
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var perCore: [Double]?
    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    var memPressure: String = "normal"   // normal | warn | critical
    var swapUsedBytes: UInt64?
    var gpuUsage: Double?
    var thermalState: String = "nominal" // nominal | fair | serious | critical
    var netRxBytesPerSec: Double = 0
    var netTxBytesPerSec: Double = 0
    var diskReadBytesPerSec: Double = 0
    var diskWriteBytesPerSec: Double = 0
    var batteryLevel: Double?
    var batteryCharging: Bool?
    var loadAverage1: Double?
    var topProcesses: [MonitorProcessSample]?

    var cpuInfo: MonitorCPUInfo?
    var cpuLoadAvg: [Double]?         // 1 / 5 / 15 min
    var memBreakdown: MonitorMemoryBreakdown?
    var gpuDeviceName: String?
    var gpuCoreCount: Int?
    var gpuSampledAt: Double?         // GPU sampled ~6s; renderers dim stale
    var gpuRendererUtil: Double?      // 0…1
    var gpuTilerUtil: Double?         // 0…1
    var netInterfaces: [MonitorNetworkInterface]?
    var netPath: MonitorNetworkPath?
    var batteryIsCharged: Bool?
    var powerSource: String?          // battery | ac | ups
    var batteryMinutesRemaining: Double?   // IOPS -1 (calculating) maps to nil
    var batteryMinutesToFull: Double?
    var lowPowerMode: Bool?
    var accessories: [MonitorAccessoryBattery]?
    var aneProcesses: [MonitorANEProcess]?
    /// Whether any process reports a non-zero `ri_neural_footprint`.
    /// This is memory attribution, not current ANE utilization or execution.
    var aneFootprintPresent: Bool?
    /// Sum of every readable process's `ri_neural_footprint`, before top-process truncation.
    var aneFootprintBytes: UInt64?
    var sensors: MonitorSensorReadings?
    /// Per-app disk I/O rank (demand-gated by Disk widget).
    var topIOProcesses: [MonitorProcessSample]?
    var gpuMemUsedBytes: UInt64?
}

/// Per-source health for settings + AI empty states (unauthorized / stale / ok).
struct MonitorSourceHealth: Codable, Sendable, Equatable {
    var sourceID: String
    var state: String                 // ok | stale | unauthorized | error | off
    var detail: String?
    var lastUpdateAt: Double?
}

/// Renderers' view of the world. `nil` module == disabled; `agents == nil` → unauthorized/empty.
struct MonitorSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 2
    var timestamp: Double = 0
    var system: MonitorSystemSnapshot?
    var agents: [MonitorAgentSessionState]?
    var health: [MonitorSourceHealth]?
}

// MARK: - Source plumbing

/// Sources push partial updates; hub recomposes at its own pace.
protocol MonitorSnapshotSink: Actor {
    func updateSystem(_ snapshot: MonitorSystemSnapshot) async
    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async
    func updateHealth(_ health: MonitorSourceHealth) async
}

protocol MonitorDataSource: Sendable {
    var sourceID: String { get }
    func start(sink: any MonitorSnapshotSink) async
    func stop() async
}
