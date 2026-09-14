#if !LITE_BUILD
import AppKit

/// Global + local monitors are both required: global sees other processes (incl. the desktop) but never this app's windows; local sees only this app. Parallax needs their union.
@MainActor
final class WPEPointerPublisher {
    private let mailbox: WPEPointerMailbox
    private weak var view: NSView?
    private let now: () -> TimeInterval
    private let throttleInterval: TimeInterval

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var geometryObservers: [NSObjectProtocol] = []
    private var lastMousePublishAt: TimeInterval = -.greatestFiniteMagnitude
    private var isStarted = false
    private var lastSampleWasInside = false
    /// Pointer-locked particle scenes drop frame demand while the cursor is off
    /// this display. Entering the view must produce one frame so spawn can resume.
    var onPointerEnteredView: (() -> Void)?
    /// Defaults ON so `attach` behaves exactly as before the renderer's first
    /// post-load demand evaluation arrives.
    private var mouseMonitoringEnabled = true

    private static let mouseMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    /// `throttleFPS` bounds mailbox writes to display cadence. `throttleFPS <= 0` disables it. Safe because the mailbox is last-write-wins and the renderer re-reads every frame.
    init(
        mailbox: WPEPointerMailbox,
        view: NSView?,
        throttleFPS: Double = 120,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.mailbox = mailbox
        self.view = view
        self.now = now
        self.throttleInterval = throttleFPS > 0 ? 1.0 / throttleFPS : 0
    }

    /// True while the NSEvent mouse monitors are installed — not the start/stop lifecycle (`setMouseMonitoringEnabled(false)` reports false).
    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installGeometryObservers()
        publishGeometry() // seed current geometry so the first read isn't `.none`
        if mouseMonitoringEnabled { installMouseMonitors() }
    }

    /// Geometry observers stay installed; the `isStarted` guard is load-bearing: an enable queued before `detach()` can be delivered after it and must not resurrect monitors on a torn-down surface.
    func setMouseMonitoringEnabled(_ enabled: Bool) {
        mouseMonitoringEnabled = enabled
        guard isStarted else { return }
        if enabled {
            installMouseMonitors()
        } else {
            removeMouseMonitors()
        }
    }

    func stop() {
        isStarted = false
        removeMouseMonitors()
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    private func installMouseMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseMask) { [weak self] _ in
            self?.handleMouseEvent()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mouseMask) { [weak self] event in
            self?.handleMouseEvent()
            return event
        }
        // Seed the cursor: before any mouse event arrives (and after a gated-off stretch) the mailbox must report the real cursor, not the off-screen sentinel, or the first frames freeze parallax at center.
        ingestPointerLocation(NSEvent.mouseLocation, at: now())
    }

    private func removeMouseMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        lastSampleWasInside = false
    }

    // MARK: - Mouse

    private func handleMouseEvent() {
        // Global-monitor events carry no window; `NSEvent.mouseLocation` is the screen-space cursor for both, so the event's own coords are deliberately unused.
        ingestPointerLocation(NSEvent.mouseLocation, at: now())
    }

    /// Both edges bypass the throttle, not just enter: a dropped exit leaves the last inside position (`followPointerIsLive` stays true); a dropped enter would have the wake frame sample a stale outside location.
    func ingestPointerLocation(_ screenLocation: CGPoint, at time: TimeInterval? = nil) {
        let time = time ?? now()
        let inside = mailbox.sample(screenLocation: screenLocation).isInsideView
        let crossedEdge = inside != lastSampleWasInside
        let throttled = throttleInterval > 0 && time - lastMousePublishAt < throttleInterval
        if crossedEdge || !throttled {
            lastMousePublishAt = time
            mailbox.publishMouseLocation(
                screenLocation,
                timestampNanos: Self.nanos(from: time)
            )
        }
        let entered = inside && !lastSampleWasInside
        lastSampleWasInside = inside
        if entered {
            onPointerEnteredView?()
        }
    }

    // MARK: - Geometry

    private func installGeometryObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSApplication.didChangeScreenParametersNotification
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishGeometry() }
            }
            geometryObservers.append(observer)
        }
    }

    private func publishGeometry() {
        mailbox.publishGeometry(Self.geometry(of: view))
        // A display/window move can slide the view under a stationary pointer. Only resample while monitors are installed: gated off, `lastSampleWasInside` must stay the `false` that `removeMouseMonitors` left, or the re-enable seed would see no edge and skip its wake.
        if isRunning { ingestPointerLocation(NSEvent.mouseLocation) }
    }

    static func geometry(of view: NSView?) -> WPEPointerMailbox.Geometry {
        guard let view,
              let window = view.window,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return .none
        }
        let windowRect = view.convert(view.bounds, to: nil)
        return WPEPointerMailbox.Geometry(
            viewFrameInScreen: window.convertToScreen(windowRect)
        )
    }

    private static func nanos(from seconds: TimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
    }
}
#endif
