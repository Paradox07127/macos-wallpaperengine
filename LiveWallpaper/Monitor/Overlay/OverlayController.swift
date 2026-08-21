import AppKit
import LiveWallpaperCore

/// The two independently switchable overlay modules. Each owns its own window
/// per display, so Music can float on top while the Monitor board stays on the
/// desktop — or run with the Monitor board switched off entirely.
enum MonitorOverlayModule: String, CaseIterable, Hashable, Sendable {
    case monitor
    case music

    /// Widget ownership is the split: one board, two renderers.
    func owns(_ kind: MonitorWidgetKind) -> Bool {
        switch self {
        case .monitor: kind != .nowPlaying
        case .music: kind == .nowPlaying
        }
    }

    /// What this module's board may hold — also what its add-widget catalog
    /// offers, since anything else would be dropped by `merging` on write-back.
    var ownedKinds: [MonitorWidgetKind] {
        MonitorWidgetKind.allCases.filter(owns)
    }

    func widgets(of board: MonitorBoardConfiguration) -> MonitorBoardConfiguration {
        var next = board
        next.widgets = board.widgets.filter { owns($0.kind) }
        return next
    }

    func isEnabled(in overlay: MonitorOverlayConfiguration) -> Bool {
        switch self {
        case .monitor: overlay.enabled
        case .music: overlay.musicEnabled
        }
    }

    func level(in overlay: MonitorOverlayConfiguration) -> MonitorOverlayLevel {
        switch self {
        case .monitor: overlay.level
        case .music: overlay.musicLevel
        }
    }
}

/// Identifies one overlay window: a display plus the module rendering into it.
struct MonitorOverlayHostKey: Hashable, Sendable {
    var screenID: CGDirectDisplayID
    var module: MonitorOverlayModule
}

struct MonitorOverlayVisibilityInput: Equatable, Sendable {
    var key: MonitorOverlayHostKey
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
    var visibleHostKeys: Set<MonitorOverlayHostKey>
    var suspendedHostKeys: Set<MonitorOverlayHostKey>

    var pumpShouldRun: Bool {
        !visibleHostKeys.isEmpty
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
                visibleHostKeys: [],
                suspendedHostKeys: []
            )
        }

        let allHostKeys = Set(hosts.map(\.key))
        guard !isUserAbsent else {
            return MonitorOverlayVisibilityDecision(
                runtimeDisposition: .paused,
                visibleHostKeys: [],
                suspendedHostKeys: allHostKeys
            )
        }

        let visibleHostKeys = Set(hosts.compactMap { host -> MonitorOverlayHostKey? in
            switch host.level {
            case .desktop:
                return host.isDesktopOccluded ? nil : host.key
            case .front:
                return host.key
            }
        })
        return MonitorOverlayVisibilityDecision(
            runtimeDisposition: visibleHostKeys.isEmpty ? .paused : .active,
            visibleHostKeys: visibleHostKeys,
            suspendedHostKeys: allHostKeys.subtracting(visibleHostKeys)
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

    private var hosts: [MonitorOverlayHostKey: Host] = [:]
    /// Last full board applied per display. A module host only ever sees its own
    /// widgets, so this is what its edits are merged back into.
    private var boards: [CGDirectDisplayID: MonitorBoardConfiguration] = [:]
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
        guard let overlay else {
            teardown(screenID: screenID)
            return
        }
        boards[screenID] = overlay.board
        for module in MonitorOverlayModule.allCases {
            apply(module: module, overlay: overlay, screenID: screenID, screenFrame: screenFrame)
        }
    }

    private func apply(
        module: MonitorOverlayModule,
        overlay: MonitorOverlayConfiguration,
        screenID: CGDirectDisplayID,
        screenFrame: NSRect
    ) {
        let key = MonitorOverlayHostKey(screenID: screenID, module: module)
        guard module.isEnabled(in: overlay) else {
            teardown(key: key)
            return
        }

        let level = module.level(in: overlay)
        let moduleBoard = module.widgets(of: overlay.board)
        let topInsetFraction = HostView.menuBarTopInsetFraction(forFrame: screenFrame)

        if let host = hosts[key] {
            host.config = moduleBoard
            host.level = level
            host.window.applyFrame(screenFrame)
            host.window.apply(level: level)
            host.board.apply(configuration: moduleBoard, topInsetFraction: topInsetFraction)
            updateInteractive(host)
            reconcileVisibilityAndRuntime()
            return
        }

        SourceRegistration.registerDefaultFactories()

        let window = OverlayWindow(screenFrame: screenFrame, level: level)
        let board = HostView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            configuration: moduleBoard,
            topInsetFraction: topInsetFraction,
            allowedKinds: module.ownedKinds
        )
        board.autoresizingMask = [.width, .height]
        board.resetHistory()
        board.setSuspended(true)
        window.contentView = board

        let host = Host(
            window: window,
            board: board,
            config: moduleBoard,
            level: level
        )
        hosts[key] = host

        board.onConfigurationEdited = { [weak self, weak host] edited in
            guard let self, let host else { return }
            host.config = edited
            onOverlayEdited?(screenID, merging(edited, from: key))
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

    /// A host renders only its own module's widgets, so reporting its edit
    /// verbatim would persist a board with the other module's widgets deleted —
    /// silently, and for a module that may not even have a window open. Fold the
    /// edit back into the last full board instead.
    private func merging(
        _ edited: MonitorBoardConfiguration,
        from key: MonitorOverlayHostKey
    ) -> MonitorBoardConfiguration {
        let full = boards[key.screenID] ?? edited
        var merged = edited
        merged.widgets = edited.widgets.filter { key.module.owns($0.kind) }
            + full.widgets.filter { !key.module.owns($0.kind) }
        // The persist path skips the reconcile, so this is the only place the
        // retained board learns about the edit.
        boards[key.screenID] = merged
        return merged
    }

    /// Drops every module host on this display.
    func teardown(screenID: CGDirectDisplayID) {
        for key in Array(hosts.keys) where key.screenID == screenID {
            teardown(key: key)
        }
        boards[screenID] = nil
    }

    private func teardown(key: MonitorOverlayHostKey) {
        guard let host = hosts.removeValue(forKey: key) else { return }
        host.board.flushPendingEdits()
        host.board.onConfigurationEdited = nil
        host.board.onEditingChanged = nil
        host.window.orderOut(nil)
        reconcileVisibilityAndRuntime()
    }

    /// Drop overlays for displays no longer live (`ScreenManager` pairs with per-screen `apply`).
    func retainOnly(_ liveScreenIDs: Set<CGDirectDisplayID>) {
        // Snapshot keys — teardown mutates `hosts` (can't iterate live key view).
        for key in Array(hosts.keys) where !liveScreenIDs.contains(key.screenID) {
            teardown(key: key)
        }
        for screenID in Array(boards.keys) where !liveScreenIDs.contains(screenID) {
            boards[screenID] = nil
        }
    }

    func teardownAll() {
        for key in Array(hosts.keys) {
            teardown(key: key)
        }
        boards.removeAll()
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

    var activeHostKeys: Set<MonitorOverlayHostKey> {
        Set(hosts.keys)
    }

    func board(screenID: CGDirectDisplayID, module: MonitorOverlayModule) -> MonitorBoardConfiguration? {
        hosts[MonitorOverlayHostKey(screenID: screenID, module: module)]?.config
    }

    /// The very callback `apply` installed on that module's board view, so a
    /// test drives the real write-back path instead of restating it.
    func boardEditCallback(
        screenID: CGDirectDisplayID,
        module: MonitorOverlayModule
    ) -> ((MonitorBoardConfiguration) -> Void)? {
        hosts[MonitorOverlayHostKey(screenID: screenID, module: module)]?.board.onConfigurationEdited
    }

    func waitUntilRuntimeSettled() async {
        let task = runtimeReconciliationTask
        await task?.value
    }
    #endif

    private func updateInteractive(_ host: Host) {
        // A widget can claim the pointer on its own (Now Playing's transport
        // controls) without the user opting the whole board in. The window has
        // to stop ignoring mouse events for that, which is display-wide — so
        // `HostView.hitTest` narrows it back down to that widget's rect, and
        // everything else still falls through to the desktop.
        let scope = HostView.pointerScope(for: host.config, isEditing: host.board.isEditing)
        host.window.setInteractive(scope != .none)
        host.board.setPointerScope(scope)
    }

    // MARK: - Runtime lease + pump

    private func reconcileVisibilityAndRuntime() {
        let inputs = hosts.map { key, host in
            MonitorOverlayVisibilityInput(
                key: key,
                level: host.level,
                isDesktopOccluded: occludedScreenIDs.contains(key.screenID)
            )
        }
        let decision = MonitorOverlayVisibilityPolicy.resolve(
            hosts: inputs,
            isUserAbsent: isUserAbsent
        )
        visibilityDecision = decision

        // Suspend on MainActor immediately so an occluded board can't animate while lease transition awaits.
        for (key, host) in hosts {
            host.isVisible = decision.visibleHostKeys.contains(key)
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

    /// Kinds that read nothing out of the sampled series, so their arrival adds
    /// no fabricated-zero window to any history — and must not cost every other
    /// tile its accumulated sparkline. Now Playing is pushed by notification,
    /// not sampled.
    nonisolated static let historylessWidgetKinds: Set<MonitorWidgetKind> = [.nowPlaying]

    /// A metric group no placed widget read was not sampled at all — the source
    /// still emits a literal 0 for it (`"normal"` for pressure), and those
    /// placeholders are indistinguishable from a real idle reading once they are
    /// in the series. A widget added later would therefore draw a fabricated
    /// flat history, so the series restarts whenever the *sampled* set grows.
    nonisolated static func historyResetRequired(
        previous: Set<MonitorWidgetKind>,
        next: Set<MonitorWidgetKind>
    ) -> Bool {
        !next.subtracting(previous).subtracting(historylessWidgetKinds).isEmpty
    }

    private func makeOptions(visibleHostKeys: Set<MonitorOverlayHostKey>) -> MonitorRuntimeOptions {
        var kinds: Set<MonitorWidgetKind> = []
        var gpuSeconds: Double?
        var sampleSeconds: Double?
        var demand = MonitorSampleDemand()
        for (key, host) in hosts where visibleHostKeys.contains(key) {
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
            .active(makeOptions(visibleHostKeys: visibilityDecision.visibleHostKeys))
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
                if Self.historyResetRequired(
                    previous: appliedRuntimeState.options?.activeWidgetKinds ?? [],
                    next: options.activeWidgetKinds ?? []
                ) {
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
                pushLatest()
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

    private func pushLatest() {
        let broker = runtime.broker
        guard let update = broker.latest(after: lastGeneration) else { return }
        lastGeneration = update.generation
        for host in hosts.values where host.isVisible && host.isDeliveringSnapshots {
            host.board.push(update.snapshot)
        }
    }
}
