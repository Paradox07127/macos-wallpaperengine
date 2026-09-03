import AppKit
import LiveWallpaperCore

/// The two independently switchable overlay modules. Each owns its own window
/// per display, so Music can float on top while the Monitor board stays on the
/// desktop — or run with the Monitor board switched off entirely.
enum MonitorOverlayModule: String, CaseIterable, Hashable, Sendable {
    case monitor
    case music

    func isEnabled(in overlay: MonitorOverlayConfiguration) -> Bool {
        switch self {
        case .monitor: overlay.enabled
        case .music: overlay.music.enabled
        }
    }

    func level(in overlay: MonitorOverlayConfiguration) -> MonitorOverlayLevel {
        switch self {
        case .monitor: overlay.level
        case .music: overlay.music.level
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

    /// Global + local mouse monitors, live only while a host is `.widgetsOnly`.
    private var pointerMonitors: [Any] = []

    /// The two modules render different things from different configurations,
    /// so a host is one or the other — never a board filtered down to half its
    /// widgets.
    private enum HostContent {
        case monitor(HostView, MonitorBoardConfiguration)
        case music(MusicHostView, MusicOverlayConfiguration)
    }

    @MainActor
    private final class Host {
        let window: OverlayWindow
        var content: HostContent
        var level: MonitorOverlayLevel
        var isVisible = false
        var isDeliveringSnapshots = false

        init(window: OverlayWindow, content: HostContent, level: MonitorOverlayLevel) {
            self.window = window
            self.content = content
            self.level = level
        }

        var board: HostView? {
            if case .monitor(let view, _) = content { return view }
            return nil
        }

        var boardConfig: MonitorBoardConfiguration? {
            if case .monitor(_, let config) = content { return config }
            return nil
        }

        var musicConfig: MusicOverlayConfiguration? {
            if case .music(_, let config) = content { return config }
            return nil
        }

        var pointerScope: PointerScope {
            switch content {
            case .monitor(let view, _): view.pointerScope
            // The layer has no edit mode of its own: either its controls want
            // the pointer or the window is click-through.
            case .music(let view, _): view.wantsPointer ? .widgetsOnly : .none
            }
        }

        /// Delivery cadence contribution; the music layer draws on its own 1 Hz
        /// clock and has no sampler to pace.
        var refreshIntervalSeconds: Double? {
            boardConfig?.refreshIntervalSeconds
        }

        func push(_ snapshot: MonitorSnapshot) {
            switch content {
            case .monitor(let view, _): view.push(snapshot)
            case .music(let view, _): view.push(snapshot)
            }
        }

        func setSuspended(_ suspended: Bool) {
            switch content {
            case .monitor(let view, _): view.setSuspended(suspended)
            case .music(let view, _): view.setSuspended(suspended)
            }
        }

        func acceptsPointer(atLocalPoint point: NSPoint) -> Bool {
            switch content {
            case .monitor(let view, _): view.acceptsPointer(atLocalPoint: point)
            case .music(let view, _): view.acceptsPointer(atLocalPoint: point)
            }
        }

        var view: NSView {
            switch content {
            case .monitor(let view, _): view
            case .music(let view, _): view
            }
        }
    }

    private var hosts: [MonitorOverlayHostKey: Host] = [:]
    /// One series per metric for the whole machine, not one per display. Every
    /// board host is pushed the same snapshot from the same broker, so a store
    /// each meant N copies of one history — and they drifted, because a hidden
    /// display stops being pushed while the visible one keeps accumulating.
    private let sharedBoardHistory = MonitorHistoryStore()

    /// Pushes a changed capture policy onto overlays that already exist; new
    /// ones read it in `OverlayWindow.init`.
    func applyCapturePolicyToLiveOverlays() {
        let sharing = WallpaperCapturePolicy.windowSharingType
        for host in hosts.values {
            host.window.sharingType = sharing
        }
    }
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
        let topInsetFraction = HostView.menuBarTopInsetFraction(forFrame: screenFrame)

        if let host = hosts[key] {
            host.level = level
            host.window.applyFrame(screenFrame)
            host.window.apply(level: level)
            switch host.content {
            case .monitor(let view, _):
                host.content = .monitor(view, overlay.board)
                view.apply(configuration: overlay.board, topInsetFraction: topInsetFraction)
            case .music(let view, _):
                host.content = .music(view, overlay.music)
                view.apply(configuration: overlay.music, topInsetFraction: topInsetFraction)
            }
            updateInteractive(host)
            reconcileVisibilityAndRuntime()
            return
        }

        SourceRegistration.registerDefaultFactories()

        let window = OverlayWindow(screenFrame: screenFrame, level: level)
        let frame = NSRect(origin: .zero, size: screenFrame.size)
        let host: Host
        switch module {
        case .monitor:
            let board = HostView(
                frame: frame,
                configuration: overlay.board,
                topInsetFraction: topInsetFraction,
                historyStore: sharedBoardHistory
            )
            board.autoresizingMask = [.width, .height]
            // No reset here: a display joining mid-session adopts the machine's
            // existing series, which is the whole point of sharing one store.
            board.setSuspended(true)
            window.contentView = board
            host = Host(window: window, content: .monitor(board, overlay.board), level: level)
            board.onConfigurationEdited = { [weak self, weak host] edited in
                guard let self, let host else { return }
                if case .monitor(let view, _) = host.content {
                    host.content = .monitor(view, edited)
                }
                onOverlayEdited?(screenID, edited)
                reconcileVisibilityAndRuntime()
            }
            board.onEditingChanged = { [weak self, weak host] _ in
                guard let self, let host else { return }
                updateInteractive(host)
            }
        case .music:
            let music = MusicHostView(
                frame: frame,
                configuration: overlay.music,
                topInsetFraction: topInsetFraction
            )
            music.autoresizingMask = [.width, .height]
            music.setSuspended(true)
            window.contentView = music
            host = Host(window: window, content: .music(music, overlay.music), level: level)
        }
        hosts[key] = host

        updateInteractive(host)
        reconcileVisibilityAndRuntime()
        fadeIn(host)
        // `fadeIn` orders the new window front regardless, which would put a
        // freshly enabled Monitor board back on top of the Music layer.
        restackSameLevelHosts()
    }

    /// Drops every module host on this display.
    func teardown(screenID: CGDirectDisplayID) {
        for key in Array(hosts.keys) where key.screenID == screenID {
            teardown(key: key, animated: false)
        }
    }

    /// `animated: false` for displays that are going away — AppKit constrains a
    /// still-visible window onto a surviving screen, so a fade there parks the
    /// panel on the wrong display for its duration.
    private func teardown(key: MonitorOverlayHostKey, animated: Bool = true) {
        guard let host = hosts.removeValue(forKey: key) else { return }
        defer { refreshPointerTracking() }
        if let board = host.board {
            board.flushPendingEdits()
            board.onConfigurationEdited = nil
            board.onEditingChanged = nil
        }
        if animated {
            fadeOutAndOrderOut(host)
        } else {
            host.window.orderOut(nil)
        }
        reconcileVisibilityAndRuntime()
    }

    /// Config override wins over the system setting, matching `HostView`.
    private func reducesMotion(for host: Host) -> Bool {
        if let override = host.boardConfig?.reduceMotionOverride {
            return override
        }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func fadeIn(_ host: Host) {
        guard !reducesMotion(for: host) else {
            host.window.orderFrontRegardless()
            return
        }
        host.window.alphaValue = 0
        host.window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.enterDuration
            context.timingFunction = DesignTokens.Motion.enterTiming
            host.window.animator().alphaValue = 1
        }
    }

    private func fadeOutAndOrderOut(_ host: Host) {
        guard !reducesMotion(for: host) else {
            host.window.orderOut(nil)
            return
        }
        // Captured strongly: the host leaves `hosts` before this fade finishes.
        let window = host.window
        // `refreshPointerTracking` has already forgotten this host, so without
        // this the fading window would still swallow desktop clicks.
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.exitDuration
            context.timingFunction = DesignTokens.Motion.exitTiming
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    /// Drop overlays for displays no longer live (`ScreenManager` pairs with per-screen `apply`).
    func retainOnly(_ liveScreenIDs: Set<CGDirectDisplayID>) {
        // Snapshot keys — teardown mutates `hosts` (can't iterate live key view).
        for key in Array(hosts.keys) where !liveScreenIDs.contains(key.screenID) {
            teardown(key: key, animated: false)
        }
    }

    func teardownAll() {
        for key in Array(hosts.keys) {
            teardown(key: key, animated: false)
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

    var activeHostKeys: Set<MonitorOverlayHostKey> {
        Set(hosts.keys)
    }

    func board(screenID: CGDirectDisplayID, module: MonitorOverlayModule) -> MonitorBoardConfiguration? {
        hosts[MonitorOverlayHostKey(screenID: screenID, module: module)]?.boardConfig
    }

    func music(screenID: CGDirectDisplayID) -> MusicOverlayConfiguration? {
        hosts[MonitorOverlayHostKey(screenID: screenID, module: .music)]?.musicConfig
    }

    /// The very callback `apply` installed on that module's board view, so a
    /// test drives the real write-back path instead of restating it.
    func boardEditCallback(
        screenID: CGDirectDisplayID,
        module: MonitorOverlayModule
    ) -> ((MonitorBoardConfiguration) -> Void)? {
        hosts[MonitorOverlayHostKey(screenID: screenID, module: module)]?.board?.onConfigurationEdited
    }

    func waitUntilRuntimeSettled() async {
        let task = runtimeReconciliationTask
        await task?.value
    }
    #endif

    private func updateInteractive(_ host: Host) {
        // A widget can claim the pointer on its own (Now Playing's transport) without the whole board opting in.
        // That window flag is display-wide, and `HostView.hitTest` can't narrow it — nil doesn't hand the click to
        // the window below, it just leaves it unhandled, which once froze the whole desktop under an interactive
        // full-screen overlay. So the window stays click-through until the pointer is over a live control.
        if case .monitor(let view, let config) = host.content {
            view.setPointerScope(HostView.pointerScope(for: config, isEditing: view.isEditing))
        }
        applyWindowMouseEvents(to: host)
        refreshPointerTracking()
    }

    /// Sets one window's mouse-event flag from the pointer's current position.
    private func applyWindowMouseEvents(to host: Host, screenPoint: NSPoint? = nil) {
        guard !OverlayPointerGate.pointerIsCaptured else { return }
        let scope = host.pointerScope
        let point = screenPoint ?? NSEvent.mouseLocation
        host.window.setInteractive(OverlayPointerGate.windowTakesMouseEvents(
            scope: scope,
            pointerIsOverLiveArea: scope == .widgetsOnly && hostAcceptsPointer(host, atScreenPoint: point)
        ))
    }

    private func hostAcceptsPointer(_ host: Host, atScreenPoint screenPoint: NSPoint) -> Bool {
        guard host.window.frame.contains(screenPoint) else { return false }
        let inWindow = host.window.convertPoint(fromScreen: screenPoint)
        return host.acceptsPointer(atLocalPoint: host.view.convert(inWindow, from: nil))
    }

    /// One monitor per host: only `.widgetsOnly` needs the pointer followed, and only while such a host
    /// exists. The local monitor covers the window just made interactive — once the pointer is ours, the
    /// global monitor stops seeing it, and without the local one it could never leave.
    /// Pure predicate behind `refreshPointerTracking`: a hidden host has no
    /// window on screen to receive events, so it must not keep the pointer
    /// monitors (and their per-event hit-testing work) alive.
    nonisolated static func needsPointerTracking(_ hosts: [(scope: PointerScope, isVisible: Bool)]) -> Bool {
        hosts.contains { $0.scope == .widgetsOnly && $0.isVisible }
    }

    private func refreshPointerTracking() {
        let needsTracking = Self.needsPointerTracking(hosts.values.map { (scope: $0.pointerScope, isVisible: $0.isVisible) })
        guard needsTracking else {
            stopPointerTracking()
            return
        }
        guard pointerMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    private func stopPointerTracking() {
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors.removeAll()
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        for host in hosts.values where host.pointerScope == .widgetsOnly && host.isVisible {
            applyWindowMouseEvents(to: host, screenPoint: point)
        }
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
                host.setSuspended(true)
                // A hidden host must not keep swallowing clicks meant for
                // whatever is now on top of it.
                host.window.setInteractive(false)
            }
        }
        if !decision.pumpShouldRun {
            stopPump()
        }
        restackSameLevelHosts()

        scheduleRuntimeReconciliation()
    }

    /// Same-level, same-screen z-order used to be creation order — whichever
    /// module was enabled second landed on top and stayed there, so opening
    /// Monitor after Music let it steal Music's transport-control clicks with
    /// no way to recover short of disabling and re-enabling both.
    nonisolated static func stackingOrder(_ modules: [MonitorOverlayModule]) -> [MonitorOverlayModule] {
        modules.sorted { lhs, rhs in (lhs == .music ? 1 : 0) < (rhs == .music ? 1 : 0) }
    }

    private func restackSameLevelHosts() {
        for screenID in Set(hosts.keys.map(\.screenID)) {
            let keysHere = hosts.keys.filter { $0.screenID == screenID }
            for level in MonitorOverlayLevel.allCases {
                let group = keysHere.filter { hosts[$0]?.level == level }
                guard group.count > 1 else { continue }
                var previous: OverlayWindow?
                for module in Self.stackingOrder(group.map(\.module)) {
                    guard let key = group.first(where: { $0.module == module }),
                          let window = hosts[key]?.window else { continue }
                    if let previous {
                        window.order(.above, relativeTo: previous.windowNumber)
                    }
                    previous = window
                }
            }
        }
    }

    /// A metric group no placed widget reads isn't sampled at all — the source still emits a literal 0 for
    /// it (`"normal"` for pressure), indistinguishable from a real idle reading once in the series. A
    /// widget added later would draw a fabricated flat history, so the series restarts whenever the sampled
    /// set grows.
    nonisolated static func historyResetRequired(
        previous: Set<MonitorWidgetKind>,
        next: Set<MonitorWidgetKind>
    ) -> Bool {
        !next.subtracting(previous).isEmpty
    }

    private func makeOptions(visibleHostKeys: Set<MonitorOverlayHostKey>) -> MonitorRuntimeOptions {
        var kinds: Set<MonitorWidgetKind> = []
        var gpuSeconds: Double?
        var sampleSeconds: Double?
        var demand = MonitorSampleDemand()
        var music = false
        var musicWantsAudio = false
        for (key, host) in hosts where visibleHostKeys.contains(key) {
            switch host.content {
            case .monitor(_, let board):
                kinds.formUnion(board.widgets.map(\.kind))
                if let s = MonitorWidgetDraft.gpuSampleSeconds(in: board.widgets) {
                    gpuSeconds = min(gpuSeconds ?? s, s)
                }
                let interval = board.refreshIntervalSeconds
                sampleSeconds = min(sampleSeconds ?? interval, interval)
                demand = demand.union(MonitorSampleDemand.of(board.widgets))
            case .music(_, let configuration):
                music = true
                // The tap and its FFT only pay for themselves while a layer
                // actually draws the reactive effects.
                musicWantsAudio = musicWantsAudio || NowPlayingOptions(configuration.options).audioReactive
            }
        }
        return MonitorRuntimeOptions(
            system: MonitorRuntimeOptions.requiresSystemMetrics(for: kinds),
            agents: kinds.contains(.fleet),
            topProcesses: kinds.contains(.processes),
            activeWidgetKinds: kinds,
            music: music,
            musicAudioReactive: musicWantsAudio,
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
                // A new session, not a resume: the store outlives every host
                // now, so without this the first board opened after the last
                // one closed drew the previous session's curves as if they
                // were current, until the new samples pushed them off.
                sharedBoardHistory.reset()
                return
            }

            guard let lease = appliedRuntimeState.lease else { return }

            if appliedRuntimeState.options != options {
                // A metric group no placed widget reads isn't sampled — the source still emits a literal 0
                // (`"normal"` for pressure), indistinguishable from real idle data once in the series. A widget
                // added later would draw a fabricated flat history, so restart the series when the sampled set
                // grows. Both edit paths (overlay-side, Settings-side) funnel here.
                let resetsHistory = Self.historyResetRequired(
                    previous: appliedRuntimeState.options?.activeWidgetKinds ?? [],
                    next: options.activeWidgetKinds ?? []
                )
                await lease.updateOptions(options).value
                // After the await, not before: the pump can push a pre-rebuild
                // frame while it is suspended, and that frame still carries the
                // placeholder zeros this reset exists to remove — clearing
                // first just let them back in.
                if resetsHistory { sharedBoardHistory.reset() }
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
                host.setSuspended(false)
                newlyVisibleHosts.append(host)
            } else if !shouldDeliver {
                host.isDeliveringSnapshots = false
                host.setSuspended(true)
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
            .compactMap(\.refreshIntervalSeconds)
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
        pushTrackingPointerScope(update.snapshot, to: host)
    }

    /// Now Playing's `wantsPointer` is snapshot-driven (it needs a drawn track),
    /// so a push can flip a host's `pointerScope` without any config change.
    /// Skipping the refresh left two states behind: an overlay created mid-song
    /// drew transport controls on a still click-through window, and a pointer
    /// parked on the controls when the track ended kept the window interactive
    /// while `hitTest` returned nil — the frozen-desktop failure `updateInteractive`
    /// documents, resurrected through the data path.
    private func pushTrackingPointerScope(_ snapshot: MonitorSnapshot, to host: Host) {
        let scopeBefore = host.pointerScope
        host.push(snapshot)
        if host.pointerScope != scopeBefore { updateInteractive(host) }
    }

    private func pushLatest() {
        let broker = runtime.broker
        guard let update = broker.latest(after: lastGeneration) else { return }
        lastGeneration = update.generation
        for host in hosts.values where host.isVisible && host.isDeliveringSnapshots {
            pushTrackingPointerScope(update.snapshot, to: host)
        }
    }
}
