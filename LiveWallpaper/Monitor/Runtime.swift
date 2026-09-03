import Foundation
import LiveWallpaperCore
import os

let monitorSourcesLog = os.Logger(subsystem: "com.livewallpaper", category: "MonitorSources")

/// The expensive samplers, keyed by whether any visible widget still displays
/// their output. A widget's *kind* only says what it could ever need; these say
/// what it wants right now, after its own section toggles.
struct MonitorSampleDemand: Sendable, Equatable {
    /// SMC temperature/fan reads.
    var sensors = false
    /// Full process-table walk.
    var topProcesses = false
    /// Per-process disk I/O attribution (rusage deltas inside that walk).
    var processIO = false

    func union(_ other: Self) -> Self {
        Self(
            sensors: sensors || other.sensors,
            topProcesses: topProcesses || other.topProcesses,
            processIO: processIO || other.processIO
        )
    }

    /// Defaults are `true`: an absent option key means the section is showing.
    private static func shows(_ placement: MonitorWidgetPlacement, _ key: String) -> Bool {
        placement.options[key]?.boolValue ?? true
    }

    /// Single source of truth for "does this placement's rendered size ever
    /// draw the top-processes column", grepped against each view's own size
    /// dispatch so this can't drift silently:
    /// - CPUWidgetView.swift: `topCPUProcesses` (:191) is read only inside
    ///   `largeBody` (MARK: - L, :141) — S/M never call it.
    /// - MemoryWidgetView.swift: `showsTopProcesses` (:156) is read only
    ///   inside `large(cellHeight:)` (MARK: - L, :120) — S/M never call it.
    /// - DiskWidgetView.swift: `topIOProcesses` (:191-192) is read only
    ///   inside `large(cellHeight:)` (MARK: - Large, :196) — S/M never call it.
    private static func drawsAtLargeOnly(_ widget: MonitorWidgetPlacement) -> Bool {
        widget.size == .large
    }

    /// PowerWidgetView.swift: `.small` dispatches to `smallBody` (:21), which
    /// never references `socTempC`; `.medium` and `.large` both dispatch to
    /// `mediumBody` (:22-23), whose `temperatureChip` (:114-115) does.
    private static func drawsSensorsAtMediumOrLarge(_ widget: MonitorWidgetPlacement) -> Bool {
        widget.size != .small
    }

    static func of(_ widgets: [MonitorWidgetPlacement]) -> Self {
        var demand = Self()
        for widget in widgets {
            switch widget.kind {
            case .cpu:
                // CPU's "Top by CPU" column has no toggle — it draws whenever
                // the sampler hands it processes, but only at `.large`.
                demand.topProcesses = demand.topProcesses || drawsAtLargeOnly(widget)
                demand.sensors = demand.sensors || shows(widget, "showSensors")
            case .gpu:
                demand.sensors = demand.sensors || shows(widget, "showSensors")
            case .power:
                // No options popover, so its sensor row is always live at the
                // sizes that draw it.
                demand.sensors = demand.sensors || drawsSensorsAtMediumOrLarge(widget)
            case .processes:
                demand.topProcesses = true
            case .memory:
                demand.topProcesses = demand.topProcesses
                    || (drawsAtLargeOnly(widget) && shows(widget, "showTopProcesses"))
            case .disk:
                demand.processIO = demand.processIO
                    || (drawsAtLargeOnly(widget) && shows(widget, "showTopProcesses"))
            case .network, .fleet, .aiEngine:
                break
            }
        }
        return demand
    }
}

struct MonitorRuntimeOptions: Sendable, Equatable {
    var system = true
    var agents = false
    var topProcesses = false
    var claudeRoot: URL?
    var codexRoot: URL?
    /// Union of kinds across screens on this lease.
    var activeWidgetKinds: Set<MonitorWidgetKind>?
    /// A Now Playing layer is visible somewhere. It is not a widget, so it
    /// cannot be read off `activeWidgetKinds`.
    var music = false
    /// That layer draws the audio-reactive effects, which is the only reason to
    /// run the system-audio tap and its FFT.
    var musicAudioReactive = false
    var gpuSampleSeconds: Double?
    /// Board-configured seconds between system samples. Nil keeps
    /// `SystemMetricsSource`'s own default.
    var sampleIntervalSeconds: Double?
    /// What the visible widgets still want sampled after their own section
    /// toggles. Nil = no per-widget information available, so nothing is
    /// narrowed (fail open — a missing demand must never starve a widget).
    var sampleDemand: MonitorSampleDemand?

    /// Exhaustive: new widget kinds must declare metrics demand (agent-only boards skip system pipeline).
    static func requiresSystemMetrics(for kinds: Set<MonitorWidgetKind>) -> Bool {
        kinds.contains { kind in
            switch kind {
            case .fleet:
                false
            case .cpu, .memory, .gpu, .network, .disk, .power, .processes, .aiEngine:
                true
            }
        }
    }
}

/// Security-scoped grant seam — suspend tests prove resume re-opens nothing.
struct MonitorGrantAccess: Sendable {
    var resolveRoots: @Sendable () async -> (claude: URL?, codex: URL?)
    var release: @Sendable () async -> Void

    static let live = MonitorGrantAccess(
        resolveRoots: {
            await MainActor.run {
                (SourceAuthorization.shared.resolveRoot(.claude),
                 SourceAuthorization.shared.resolveRoot(.codex))
            }
        },
        release: {
            await MainActor.run { SourceAuthorization.shared.release() }
        }
    )
}

/// Caller-owned command stream for one logical runtime lease slot.
final class MonitorRuntimeLeaseSlot: Sendable {
    private struct State: Sendable {
        var nextSequence: UInt64 = 0
        var currentGeneration: UInt64?
        var desiredState: MonitorRuntimeLeaseDesiredState?
        var pendingEvent: MonitorRuntimeLeaseEvent?
        var drainTask: Task<Void, Never>?
        var drainLaunchCount: UInt64 = 0
    }

    private static let generationCounter = OSAllocatedUnfairLock(initialState: UInt64(0))
    private static let completedTask = Task<Void, Never> {}

    private let runtime: Runtime
    fileprivate let leaseID = UUID()
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(runtime: Runtime) {
        self.runtime = runtime
    }

    /// New generation + queued acquire; returned handle is sole authority for later events.
    func acquire(options: MonitorRuntimeOptions) -> MonitorRuntimeLeaseHandle {
        let generation = Self.generationCounter.withLock { value -> UInt64 in
            value &+= 1
            precondition(value != 0, "Monitor runtime lease generation exhausted")
            return value
        }
        let handle = MonitorRuntimeLeaseHandle(slot: self, generation: generation)
        handle.enqueue(.acquire(options))
        return handle
    }

    fileprivate func enqueue(
        generation: UInt64,
        command: MonitorRuntimeLeaseCommand
    ) -> Task<Void, Never> {
        state.withLock { state in
            state.nextSequence &+= 1
            precondition(state.nextSequence != 0, "Monitor runtime lease sequence exhausted")
            let sequence = state.nextSequence

            switch command {
            case let .acquire(options):
                if let current = state.currentGeneration, generation <= current {
                    return state.drainTask ?? Self.completedTask
                }
                state.currentGeneration = generation
                state.desiredState = .active(options: options, isPaused: false)

            case let .updateOptions(options):
                guard state.currentGeneration == generation,
                      case let .active(_, isPaused) = state.desiredState else {
                    return state.drainTask ?? Self.completedTask
                }
                state.desiredState = .active(options: options, isPaused: isPaused)

            case let .setPaused(isPaused):
                guard state.currentGeneration == generation,
                      case let .active(options, _) = state.desiredState else {
                    return state.drainTask ?? Self.completedTask
                }
                state.desiredState = .active(options: options, isPaused: isPaused)

            case .release:
                guard state.currentGeneration == generation,
                      case .active = state.desiredState else {
                    return state.drainTask ?? Self.completedTask
                }
                state.desiredState = .released
            }

            guard let desiredState = state.desiredState else {
                return state.drainTask ?? Self.completedTask
            }

            state.pendingEvent = MonitorRuntimeLeaseEvent(
                leaseID: leaseID,
                generation: generation,
                sequence: sequence,
                desiredState: desiredState
            )
            if let task = state.drainTask { return task }

            state.drainLaunchCount &+= 1
            let task = Task.detached { [self] in
                await drain()
            }
            state.drainTask = task
            return task
        }
    }

    private func drain() async {
        while true {
            let event = state.withLock { state -> MonitorRuntimeLeaseEvent? in
                guard let event = state.pendingEvent else {
                    // Clear under same lock as enqueue — closes lost-wakeup race.
                    state.drainTask = nil
                    return nil
                }
                state.pendingEvent = nil
                return event
            }
            guard let event else { return }
            await runtime.apply(event)
        }
    }

    #if DEBUG
    // Test-only introspection: no production reader, so it stays out of Release.
    var debugPendingCommandCount: Int {
        state.withLock { $0.pendingEvent == nil ? 0 : 1 }
    }

    var debugDrainWorkerCount: Int {
        state.withLock { $0.drainTask == nil ? 0 : 1 }
    }

    var debugDrainLaunchCount: UInt64 {
        state.withLock { $0.drainLaunchCount }
    }
    #endif

    fileprivate var settledTask: Task<Void, Never> { Self.completedTask }
}

/// Generation-scoped authority from `MonitorRuntimeLeaseSlot.acquire`.
final class MonitorRuntimeLeaseHandle: Sendable {
    private struct State: Sendable {
        var isReleased = false
        var tail: Task<Void, Never>?
    }

    private let slot: MonitorRuntimeLeaseSlot
    let generation: UInt64
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(slot: MonitorRuntimeLeaseSlot, generation: UInt64) {
        self.slot = slot
        self.generation = generation
    }

    @discardableResult
    func updateOptions(_ options: MonitorRuntimeOptions) -> Task<Void, Never> {
        enqueue(.updateOptions(options))
    }

    @discardableResult
    func setPaused(_ paused: Bool) -> Task<Void, Never> {
        enqueue(.setPaused(paused))
    }

    @discardableResult
    func release() -> Task<Void, Never> {
        state.withLock { state in
            guard !state.isReleased else {
                return state.tail ?? slot.settledTask
            }
            state.isReleased = true
            let task = slot.enqueue(generation: generation, command: .release)
            state.tail = task
            return task
        }
    }

    func waitUntilSettled() async {
        let tail = state.withLock { $0.tail }
        await tail?.value
    }

    @discardableResult
    fileprivate func enqueue(_ command: MonitorRuntimeLeaseCommand) -> Task<Void, Never> {
        state.withLock { state in
            guard !state.isReleased else {
                return state.tail ?? slot.settledTask
            }
            let task = slot.enqueue(generation: generation, command: command)
            state.tail = task
            return task
        }
    }
}

private enum MonitorRuntimeLeaseCommand: Sendable {
    case acquire(MonitorRuntimeOptions)
    case updateOptions(MonitorRuntimeOptions)
    case setPaused(Bool)
    case release
}

private enum MonitorRuntimeLeaseDesiredState: Sendable {
    case active(options: MonitorRuntimeOptions, isPaused: Bool)
    case released
}

private struct MonitorRuntimeLeaseEvent: Sendable {
    let leaseID: UUID
    let generation: UInt64
    let sequence: UInt64
    let desiredState: MonitorRuntimeLeaseDesiredState
}

/// App-wide pipeline owner: N Monitor displays share one hub + one source set.
actor Runtime {
    static let shared = Runtime()

    private let grants: MonitorGrantAccess
    /// Test seam without mutating process-global MainActor registry.
    private let sourceFactoriesOverride: [SourceFactory]?

    init(
        grants: MonitorGrantAccess = .live,
        sourceFactories: [SourceFactory]? = nil
    ) {
        self.grants = grants
        self.sourceFactoriesOverride = sourceFactories
    }

    typealias SourceFactory = @Sendable (MonitorRuntimeOptions) -> [any MonitorDataSource]

    @MainActor static var extraSourceFactories: [SourceFactory] = []

    nonisolated let broker = SnapshotBroker()

    private struct Lease {
        var generation: UInt64
        var lastSequence: UInt64
        var options: MonitorRuntimeOptions
        var isPaused = false
    }

    private var hub: DataHub?
    private var sources: [any MonitorDataSource] = []
    private var leases: [UUID: Lease] = [:]
    /// Union options requested for the live pipeline (pre-resolution).
    private var activeOptions: MonitorRuntimeOptions?
    private var resolvedRoots: (claude: URL?, codex: URL?)?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildRevision: UInt64 = 0
    private var forceRebuildRequested = false
    private var rebuildWorkerLaunchCount: UInt64 = 0
    private enum Lifecycle: Equatable {
        case running
        case shuttingDown
        case terminated
    }
    private var lifecycle: Lifecycle = .running
    private var shutdownTask: Task<Void, Never>?

    #if DEBUG
    // Test-only introspection: no production reader, so it stays out of Release.
    var debugActiveLeaseCount: Int { leases.count }
    var debugPausedLeaseCount: Int { leases.values.filter(\.isPaused).count }
    /// Options the live pipeline is actually running with. `nil` ⇒ no pipeline
    /// exists (no lease, or every lease paused) ⇒ nothing is being sampled.
    var debugActiveOptions: MonitorRuntimeOptions? { activeOptions }
    var debugActiveSourceCount: Int { sources.count }
    var debugActiveSourceIDs: [String] { sources.map(\.sourceID) }
    var debugIsTerminated: Bool { lifecycle == .terminated }
    /// Total actor-side lease bookkeeping. It is intentionally identical to the
    /// live lease count: completed generations leave no retired-ID state behind.
    var debugLeaseBookkeepingCount: Int { leases.count }
    var debugRebuildWorkerCount: Int { rebuildTask == nil ? 0 : 1 }
    var debugRebuildWorkerLaunchCount: UInt64 { rebuildWorkerLaunchCount }
    var debugRebuildRevision: UInt64 { rebuildRevision }
    #endif

    nonisolated func makeLeaseSlot() -> MonitorRuntimeLeaseSlot {
        MonitorRuntimeLeaseSlot(runtime: self)
    }

    fileprivate func apply(_ event: MonitorRuntimeLeaseEvent) async {
        guard lifecycle == .running else { return }

        switch event.desiredState {
        case let .active(options, isPaused):
            if let current = leases[event.leaseID] {
                guard event.generation > current.generation
                    || (event.generation == current.generation && event.sequence > current.lastSequence)
                else { return }
            }
            leases[event.leaseID] = Lease(
                generation: event.generation,
                lastSequence: event.sequence,
                options: options,
                isPaused: isPaused
            )

        case .released:
            guard let current = leases[event.leaseID] else { return }
            // A release for a newer generation also retires an actor-side older generation when acquire+release coalesced before the drain reached the actor.
            guard event.generation > current.generation
                || (event.generation == current.generation && event.sequence > current.lastSequence)
            else { return }
            leases.removeValue(forKey: event.leaseID)
        }
        await rebuild()
    }

    /// Re-resolves grants and rebuilds under the current leases — call after the
    /// user authorizes a data root so live sources pick it up immediately.
    func refreshSources() async {
        guard lifecycle == .running else { return }
        await rebuild(force: true)
    }

    /// Stops the complete producer graph and closes every lease/grant before returning.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        lifecycle = .shuttingDown
        leases.removeAll()

        let admittedRebuilds = rebuildTask
        let task = Task { [weak self] in
            await admittedRebuilds?.value
            await self?.finishShutdown()
        }
        shutdownTask = task
        await task.value
    }

    /// Union across leases: any lease wanting a module turns it on.
    static func merged(_ options: [MonitorRuntimeOptions]) -> MonitorRuntimeOptions? {
        guard !options.isEmpty else { return nil }
        var merged = MonitorRuntimeOptions(system: false)
        var sawNilDemand = false
        for entry in options {
            merged.system = merged.system || entry.system
            merged.agents = merged.agents || entry.agents
            merged.topProcesses = merged.topProcesses || entry.topProcesses
            if merged.claudeRoot == nil { merged.claudeRoot = entry.claudeRoot }
            if merged.codexRoot == nil { merged.codexRoot = entry.codexRoot }
            if let kinds = entry.activeWidgetKinds {
                merged.activeWidgetKinds = (merged.activeWidgetKinds ?? []).union(kinds)
            }
            merged.music = merged.music || entry.music
            merged.musicAudioReactive = merged.musicAudioReactive || entry.musicAudioReactive
            if let seconds = entry.gpuSampleSeconds {
                merged.gpuSampleSeconds = min(merged.gpuSampleSeconds ?? seconds, seconds)
            }
            // One shared sampler feeds every board, so the fastest board wins.
            if let seconds = entry.sampleIntervalSeconds {
                merged.sampleIntervalSeconds = min(merged.sampleIntervalSeconds ?? seconds, seconds)
            }
            // Union, and a single nil disables narrowing for the whole lease.
            if let demand = entry.sampleDemand, !sawNilDemand {
                merged.sampleDemand = merged.sampleDemand.map { $0.union(demand) } ?? demand
            } else if entry.sampleDemand == nil {
                sawNilDemand = true
                merged.sampleDemand = nil
            }
        }
        return merged
    }

    /// How many base samples to skip between GPU reads. Must divide by the interval actually handed to
    /// `SystemMetricsSource`, not a constant — the base tick used to be a fixed 2s, a board can now pick
    /// anything in 0.5…5s. Rounds up, not to nearest, because sampling the GPU *more* often than asked is
    /// the expensive direction.
    static func gpuCadence(forSeconds seconds: Double?, baseInterval: Double) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0,
              baseInterval.isFinite, baseInterval > 0 else { return nil }
        return max(1, Int((seconds / baseInterval).rounded(.up)))
    }

    /// Maps placed widget kinds to the system source's per-concern demand gates: an expensive walk runs only when
    /// its widget is on the board. Kind says what a widget *could* need; per-widget toggles say what it still
    /// wants — sampling honours the narrower one, so switching a section off stops the SMC reads / process walk,
    /// not just hides the result. `nil` demand leaves the kind baseline untouched.
    static func narrowed(
        _ options: SystemMetricsSource.Options,
        to demand: MonitorSampleDemand?
    ) -> SystemMetricsSource.Options {
        guard let demand else { return options }
        var narrowed = options
        narrowed.sensors = options.sensors && demand.sensors
        narrowed.topProcesses = options.topProcesses && demand.topProcesses
        narrowed.processIO = options.processIO && demand.processIO
        return narrowed
    }

    static func systemOptions(for kinds: Set<MonitorWidgetKind>) -> SystemMetricsSource.Options {
        SystemMetricsSource.Options(
            gpu: kinds.contains(.gpu),
            topProcesses: kinds.contains(.processes) || kinds.contains(.cpu) || kinds.contains(.memory),
            ane: kinds.contains(.aiEngine),
            accessories: kinds.contains(.power),
            sensors: kinds.contains(.cpu) || kinds.contains(.gpu) || kinds.contains(.power),
            processIO: kinds.contains(.disk),
            cpu: kinds.contains(.cpu),
            memory: kinds.contains(.memory),
            network: kinds.contains(.network),
            disk: kinds.contains(.disk),
            power: kinds.contains(.power)
        )
    }

    private func rebuild(force: Bool = false) async {
        guard lifecycle == .running else { return }
        rebuildRevision &+= 1
        precondition(rebuildRevision != 0, "Monitor runtime rebuild revision exhausted")
        forceRebuildRequested = forceRebuildRequested || force

        if let rebuildTask {
            await rebuildTask.value
            return
        }

        rebuildWorkerLaunchCount &+= 1
        let task = Task { [weak self] in
            guard let self else { return }
            await runRebuildLoop()
        }
        rebuildTask = task
        await task.value
    }

    /// One actor-owned rebuild worker folds every mutation that arrives while a source start/stop is suspended.
    private func runRebuildLoop() async {
        while lifecycle == .running {
            let revision = rebuildRevision
            let force = forceRebuildRequested
            forceRebuildRequested = false
            await performRebuild(force: force)

            guard lifecycle == .running else { break }
            if revision == rebuildRevision {
                rebuildTask = nil
                return
            }
        }
        rebuildTask = nil
    }

    private func performRebuild(force: Bool) async {
        guard lifecycle == .running else { return }
        let target = Self.merged(leases.values.filter { !$0.isPaused }.map(\.options))
        let rebuilding = force || target != activeOptions
        if rebuilding {
            await stopPipeline()
            // `stopPipeline()` is an actor-reentrancy point.
            guard lifecycle == .running else { return }
        }
        let stillWanted = leases.values.contains { $0.options.agents }
        if force || !stillWanted {
            await releaseGrants()
            guard lifecycle == .running else { return }
        }
        guard rebuilding else { return }
        broker.clear()
        activeOptions = target
        guard let target else { return }

        let hub = DataHub(broker: broker)
        await hub.setModuleEnabled(agents: target.agents)
        guard lifecycle == .running else { return }
        self.hub = hub

        var resolved = target
        if target.agents {
            let roots: (claude: URL?, codex: URL?)
            if let cached = resolvedRoots {
                roots = cached
            } else {
                roots = await grants.resolveRoots()
                guard lifecycle == .running else { return }
                if roots.claude != nil || roots.codex != nil { resolvedRoots = roots }
            }
            resolved.claudeRoot = resolved.claudeRoot ?? roots.claude
            resolved.codexRoot = resolved.codexRoot ?? roots.codex
            // Why-no-data: when an AI module is wanted but a root can't resolve (no grant / stale bookmark), say so — both in the log and as a synthesized health record the widgets' empty states can read.
            if resolved.claudeRoot == nil {
                monitorSourcesLog.warning("🛰️ claude root unresolved (no grant?) — agent sources disabled")
                await hub.updateHealth(MonitorSourceHealth(
                    sourceID: "claude", state: "unauthorized",
                    detail: "folder not granted", lastUpdateAt: Date().timeIntervalSince1970
                ))
            }
            if resolved.codexRoot == nil {
                monitorSourcesLog.warning("🛰️ codex root unresolved (no grant?) — agent sources disabled")
                await hub.updateHealth(MonitorSourceHealth(
                    sourceID: "codex", state: "unauthorized",
                    detail: "folder not granted", lastUpdateAt: Date().timeIntervalSince1970
                ))
            }
            guard lifecycle == .running else { return }
        }

        var built: [any MonitorDataSource] = []
        if resolved.system {
            if let kinds = resolved.activeWidgetKinds {
                let baseInterval = resolved.sampleIntervalSeconds ?? 2.0
                built.append(SystemMetricsSource(
                    options: Self.narrowed(
                        Self.systemOptions(for: kinds),
                        to: resolved.sampleDemand
                    ),
                    interval: baseInterval,
                    gpuSampleCadence: Self.gpuCadence(
                        forSeconds: resolved.gpuSampleSeconds,
                        baseInterval: baseInterval
                    ) ?? Self.gpuCadence(
                        forSeconds: MonitorWidgetDraft.gpuDefaultSeconds,
                        baseInterval: baseInterval
                    ) ?? 3
                ))
            } else {
                built.append(SystemMetricsSource(
                    includeTopProcesses: resolved.topProcesses,
                    interval: resolved.sampleIntervalSeconds ?? 2.0
                ))
            }
        }
        let factories: [SourceFactory]
        if let sourceFactoriesOverride {
            factories = sourceFactoriesOverride
        } else {
            factories = await MainActor.run { Self.extraSourceFactories }
            guard lifecycle == .running else { return }
        }
        for factory in factories {
            built.append(contentsOf: factory(resolved))
        }

        sources = built
        for source in built {
            await source.start(sink: hub)
            // A source start is also reentrant.
            guard lifecycle == .running else { return }
        }
        monitorSourcesLog.info("🛰️ pipeline: agents=\(resolved.agents) claudeRoot=\(resolved.claudeRoot != nil) codexRoot=\(resolved.codexRoot != nil) sources=\(built.map(\.sourceID).joined(separator: ","), privacy: .public)")

    }

    private func stopPipeline() async {
        // Detach ownership before awaiting so a re-entrant lifecycle call sees the truthful target state.
        let stoppingSources = sources
        sources.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for source in stoppingSources {
                group.addTask { await source.stop() }
            }
        }
        hub = nil
    }

    private func finishShutdown() async {
        await stopPipeline()
        activeOptions = nil
        broker.clear()
        await releaseGrants()
        rebuildTask = nil
        lifecycle = .terminated
    }

    /// Closes the security scopes and drops the cached roots together — the cache
    /// is only valid while the scopes it was resolved under are still open.
    private func releaseGrants() async {
        resolvedRoots = nil
        await grants.release()
    }
}
