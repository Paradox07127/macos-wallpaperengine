import AppKit
import LiveWallpaperCore

struct MonitorOverlayVisibilityInput: Equatable, Sendable {
    var screenID: CGDirectDisplayID
    var level: MonitorOverlayLevel
    var isDesktopOccluded: Bool
}

struct MonitorOverlayVisibilityDecision: Equatable, Sendable {
    enum RuntimeDisposition: Equatable, Sendable {
        case released
        case paused
        case active
    }

    var runtimeDisposition: RuntimeDisposition
    var visibleHostIDs: Set<CGDirectDisplayID>
    var suspendedHostIDs: Set<CGDirectDisplayID>

    var pumpShouldRun: Bool {
        !visibleHostIDs.isEmpty
    }
}

/// Pure visibility policy shared by the live controller and characterization tests.
enum MonitorOverlayVisibilityPolicy {
    static func resolve(
        hosts: [MonitorOverlayVisibilityInput],
        isUserAbsent: Bool
    ) -> MonitorOverlayVisibilityDecision {
        guard !hosts.isEmpty else {
            return MonitorOverlayVisibilityDecision(
                runtimeDisposition: .released,
                visibleHostIDs: [],
                suspendedHostIDs: []
            )
        }

        let allHostIDs = Set(hosts.map(\.screenID))
        guard !isUserAbsent else {
            return MonitorOverlayVisibilityDecision(
                runtimeDisposition: .paused,
                visibleHostIDs: [],
                suspendedHostIDs: allHostIDs
            )
        }

        let visibleHostIDs = Set(hosts.compactMap { host -> CGDirectDisplayID? in
            switch host.level {
            case .desktop:
                return host.isDesktopOccluded ? nil : host.screenID
            case .front:
                return host.screenID
            }
        })
        return MonitorOverlayVisibilityDecision(
            runtimeDisposition: visibleHostIDs.isEmpty ? .paused : .active,
            visibleHostIDs: visibleHostIDs,
            suspendedHostIDs: allHostIDs.subtracting(visibleHostIDs)
        )
    }
}

/// Owns one monitor-widget overlay panel per display.
@MainActor
final class OverlayController: NSObject {
    static let shared = OverlayController()

    /// ScreenManager stores into the screen's `monitorOverlay.board`.
    var onOverlayEdited: ((CGDirectDisplayID, MonitorBoardConfiguration) -> Void)?

    private final class Host {
        let window: OverlayWindow
        let board: HostView
        /// Drives the union sampling options across hosts.
        var config: MonitorBoardConfiguration
        var level: MonitorOverlayLevel
        var isVisible = false
        var isDeliveringSnapshots = false

        init(
            window: OverlayWindow,
            board: HostView,
            config: MonitorBoardConfiguration,
            level: MonitorOverlayLevel
        ) {
            self.window = window
            self.board = board
            self.config = config
            self.level = level
        }
    }

    private var hosts: [CGDirectDisplayID: Host] = [:]
    private var isUserAbsent = false
    private var occludedScreenIDs: Set<CGDirectDisplayID> = []
    private var visibilityDecision = MonitorOverlayVisibilityPolicy.resolve(
        hosts: [],
        isUserAbsent: false
    )

    private var pumpTask: Task<Void, Never>?
    private var lastGeneration: UInt64 = 0
    private let runtime: Runtime
    private let runtimeLeaseSlot: MonitorRuntimeLeaseSlot

    private struct AppliedRuntimeState {
        var lease: MonitorRuntimeLeaseHandle?
        var isPaused = false
        var options: MonitorRuntimeOptions?
    }

    private enum DesiredRuntimeState {
        case released
        case paused
        case active(MonitorRuntimeOptions)
    }

    private var appliedRuntimeState = AppliedRuntimeState()
    private var runtimeReconciliationRevision: UInt64 = 0
    private var runtimeReconciliationTask: Task<Void, Never>?

    override private convenience init() {
        self.init(runtime: .shared)
    }

    init(runtime: Runtime) {
        self.runtime = runtime
        self.runtimeLeaseSlot = runtime.makeLeaseSlot()
        super.init()
    }

    // MARK: - Per-screen reconcile

    func apply(
        overlay: MonitorOverlayConfiguration?,
        screenID: CGDirectDisplayID,
        screenFrame: NSRect
    ) {
        guard let overlay, overlay.enabled else {
            teardown(screenID: screenID)
            return
        }

        let topInsetFraction = HostView.menuBarTopInsetFraction(forFrame: screenFrame)

        if let host = hosts[screenID] {
            host.config = overlay.board
            host.level = overlay.level
            host.window.applyFrame(screenFrame)
            host.window.apply(level: overlay.level)
            host.board.apply(configuration: overlay.board, topInsetFraction: topInsetFraction)
            updateInteractive(host)
            reconcileVisibilityAndRuntime()
            return
        }

        SourceRegistration.registerDefaultFactories()

        let window = OverlayWindow(screenFrame: screenFrame, level: overlay.level)
        let board = HostView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            configuration: overlay.board,
            topInsetFraction: topInsetFraction
        )
        board.autoresizingMask = [.width, .height]
        board.resetHistory()
        board.setSuspended(true)
        window.contentView = board

        let host = Host(
            window: window,
            board: board,
            config: overlay.board,
            level: overlay.level
        )
        hosts[screenID] = host

        board.onConfigurationEdited = { [weak self, weak host] edited in
            guard let self, let host else { return }
            host.config = edited
            onOverlayEdited?(screenID, edited)
            reconcileVisibilityAndRuntime()
        }
        board.onEditingChanged = { [weak self, weak host] _ in
            guard let self, let host else { return }
            updateInteractive(host)
        }

        updateInteractive(host)
        reconcileVisibilityAndRuntime()
        window.orderFrontRegardless()
    }

    func teardown(screenID: CGDirectDisplayID) {
        guard let host = hosts.removeValue(forKey: screenID) else { return }
        host.board.flushPendingEdits()
        host.board.onConfigurationEdited = nil
        host.board.onEditingChanged = nil
        host.window.orderOut(nil)
        reconcileVisibilityAndRuntime()
    }

    /// Drop overlays for displays no longer live (`ScreenManager` pairs with per-screen `apply`).
    func retainOnly(_ liveScreenIDs: Set<CGDirectDisplayID>) {
        // Snapshot keys — teardown mutates `hosts` (can't iterate live key view).
        for id in Array(hosts.keys) where !liveScreenIDs.contains(id) {
            teardown(screenID: id)
        }
    }

    func teardownAll() {
        for id in Array(hosts.keys) {
            teardown(screenID: id)
        }
    }

    func updateVisibility(
        isUserAbsent: Bool,
        occludedScreenIDs: Set<CGDirectDisplayID>
    ) {
        guard self.isUserAbsent != isUserAbsent
            || self.occludedScreenIDs != occludedScreenIDs else { return }
        self.isUserAbsent = isUserAbsent
        self.occludedScreenIDs = occludedScreenIDs
        reconcileVisibilityAndRuntime()
    }

    #if DEBUG
    // Test-only introspection; no production reader.
    var hasActiveOverlay: Bool {
        !hosts.isEmpty
    }
    #endif

    func waitUntilRuntimeSettled() async {
        let task = runtimeReconciliationTask
        await task?.value
    }

    private func updateInteractive(_ host: Host) {
        let interactive = host.board.isEditing || host.config.mouseInteractionEnabled
        host.window.setInteractive(interactive)
        host.board.setMouseInteractionEnabled(interactive)
    }

    // MARK: - Runtime lease + pump

    private func reconcileVisibilityAndRuntime() {
        let inputs = hosts.map { screenID, host in
            MonitorOverlayVisibilityInput(
                screenID: screenID,
                level: host.level,
                isDesktopOccluded: occludedScreenIDs.contains(screenID)
            )
        }
        let decision = MonitorOverlayVisibilityPolicy.resolve(
            hosts: inputs,
            isUserAbsent: isUserAbsent
        )
        visibilityDecision = decision

        // Suspend on MainActor immediately so an occluded board can't animate while lease transition awaits.
        for (screenID, host) in hosts {
            host.isVisible = decision.visibleHostIDs.contains(screenID)
            if !host.isVisible {
                host.isDeliveringSnapshots = false
                host.board.setSuspended(true)
            }
        }
        if !decision.pumpShouldRun {
            stopPump()
        }

        scheduleRuntimeReconciliation()
    }

    private func makeOptions(visibleHostIDs: Set<CGDirectDisplayID>) -> MonitorRuntimeOptions {
        var kinds: Set<MonitorWidgetKind> = []
        var gpuSeconds: Double?
        var sampleSeconds: Double?
        var demand = MonitorSampleDemand()
        for (screenID, host) in hosts where visibleHostIDs.contains(screenID) {
            kinds.formUnion(host.config.widgets.map(\.kind))
            if let s = MonitorWidgetDraft.gpuSampleSeconds(in: host.config.widgets) {
                gpuSeconds = min(gpuSeconds ?? s, s)
            }
            let interval = host.config.refreshIntervalSeconds
            sampleSeconds = min(sampleSeconds ?? interval, interval)
            demand = demand.union(MonitorSampleDemand.of(host.config.widgets))
        }
        return MonitorRuntimeOptions(
            system: MonitorRuntimeOptions.requiresSystemMetrics(for: kinds),
            agents: kinds.contains(.fleet),
            topProcesses: kinds.contains(.processes),
            activeWidgetKinds: kinds,
            gpuSampleSeconds: gpuSeconds,
            sampleIntervalSeconds: sampleSeconds,
            sampleDemand: demand
        )
    }

    private func scheduleRuntimeReconciliation() {
        runtimeReconciliationRevision &+= 1
        guard runtimeReconciliationTask == nil else { return }
        runtimeReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runRuntimeReconciliationLoop()
        }
    }

    /// Sole mutator of this controller's Runtime lease.
    private func runRuntimeReconciliationLoop() async {
        while true {
            let revision = runtimeReconciliationRevision
            let desiredState = desiredRuntimeState()
            await applyRuntimeState(desiredState)

            guard revision == runtimeReconciliationRevision else { continue }
            applyDeliveryState()
            runtimeReconciliationTask = nil
            return
        }
    }

    private func desiredRuntimeState() -> DesiredRuntimeState {
        switch visibilityDecision.runtimeDisposition {
        case .released:
            .released
        case .paused:
            .paused
        case .active:
            .active(makeOptions(visibleHostIDs: visibilityDecision.visibleHostIDs))
        }
    }

    private func applyRuntimeState(_ desiredState: DesiredRuntimeState) async {
        switch desiredState {
        case .released:
            guard let lease = appliedRuntimeState.lease else { return }
            await lease.release().value
            appliedRuntimeState = AppliedRuntimeState()

        case .paused:
            guard let lease = appliedRuntimeState.lease,
                  !appliedRuntimeState.isPaused else { return }
            await lease.setPaused(true).value
            appliedRuntimeState.isPaused = true

        case let .active(options):
            if appliedRuntimeState.lease == nil {
                let lease = runtimeLeaseSlot.acquire(options: options)
                await lease.waitUntilSettled()
                appliedRuntimeState.lease = lease
                appliedRuntimeState.isPaused = false
                appliedRuntimeState.options = options
                return
            }

            guard let lease = appliedRuntimeState.lease else { return }

            if appliedRuntimeState.options != options {
                // A metric group no placed widget read was not sampled at all —
                // the source still emits a literal 0 for it (`"normal"` for
                // pressure), and those placeholders are indistinguishable from
                // a real idle reading once they are in the series. A widget
                // added later would therefore draw a fabricated flat history,
                // so restart the series whenever the sampled set grows. Both
                // edit paths (overlay-side and Settings-side) funnel here.
                let previousKinds = appliedRuntimeState.options?.activeWidgetKinds ?? []
                let gainedKinds = (options.activeWidgetKinds ?? []).subtracting(previousKinds)
                if !gainedKinds.isEmpty {
                    for host in hosts.values { host.board.resetHistory() }
                }
                await lease.updateOptions(options).value
                appliedRuntimeState.options = options
            }
            if appliedRuntimeState.isPaused {
                await lease.setPaused(false).value
                appliedRuntimeState.isPaused = false
            }
        }
    }

    /// Enable delivery only after matching runtime state applied (hidden boards already suspended sync).
    private func applyDeliveryState() {
        var newlyVisibleHosts: [Host] = []
        for host in hosts.values {
            let shouldDeliver = host.isVisible
            if shouldDeliver, !host.isDeliveringSnapshots {
                host.isDeliveringSnapshots = true
                host.board.setSuspended(false)
                newlyVisibleHosts.append(host)
            } else if !shouldDeliver {
                host.isDeliveringSnapshots = false
                host.board.setSuspended(true)
            }
        }

        if hosts.values.contains(where: \.isDeliveringSnapshots) {
            startPump()
        } else {
            stopPump()
        }
        for host in newlyVisibleHosts {
            primeHost(host)
        }
    }

    /// Delivery cadence, matching how `makeOptions` merges sampling: the
    /// fastest visible board wins, because one pump feeds all of them.
    private var pumpIntervalSeconds: Double {
        hosts.values
            .filter(\.isDeliveringSnapshots)
            .map(\.config.refreshIntervalSeconds)
            .min() ?? 1
    }

    private func startPump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Re-read every turn rather than capturing once: the board's
                // refresh slider moves without the visibility change that is the
                // only thing which restarts this task. A fixed 1s here is what
                // made the sub-second steps sample power and deliver nothing.
                let interval = self?.pumpIntervalSeconds ?? 1
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      hosts.values.contains(where: \.isDeliveringSnapshots) else { return }
                pushLatest(force: false)
            }
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// Paint immediately on a newly visible host (don't wait for next generation).
    private func primeHost(_ host: Host) {
        guard host.isVisible, host.isDeliveringSnapshots else { return }
        guard let update = runtime.broker.latest(after: 0) else { return }
        host.board.push(update.snapshot)
    }

    private func pushLatest(force: Bool) {
        let broker = runtime.broker
        let after = force ? 0 : lastGeneration
        guard let update = broker.latest(after: after) else { return }
        lastGeneration = update.generation
        for host in hosts.values where host.isVisible && host.isDeliveringSnapshots {
            host.board.push(update.snapshot)
        }
    }
}
