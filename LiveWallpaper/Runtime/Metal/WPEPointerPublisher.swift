#if !LITE_BUILD
import AppKit

/// Feeds a `WPEPointerMailbox` from AppKit so the render thread never reads
/// `NSEvent` / `NSView`. Owns only the mouse-position and window-geometry slots;
/// `pointerFrame` and `clickCaptureEnabled` are pushed by the view/renderer.
///
/// Global + local monitors are both required. `addGlobalMonitorForEvents` sees
/// events destined for *other* processes — including the desktop the wallpaper
/// sits behind — but never this app's own windows. `addLocalMonitorForEvents`
/// sees only this app's own events. Wallpaper parallax must track the cursor
/// everywhere on screen, so only their union is complete; neither alone covers
/// both "over another app / the desktop" and "over our own settings window".
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
    /// Defaults ON so `attach` behaves exactly as before the renderer's first
    /// post-load demand evaluation arrives.
    private var mouseMonitoringEnabled = true

    private static let mouseMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    /// `throttleFPS` bounds mailbox writes to display cadence: at 120 Hz a burst
    /// of sub-8 ms mouse events collapses to one write. Safe because the mailbox
    /// is last-write-wins and the renderer re-reads every frame — a dropped
    /// intermediate move is one the renderer would never have sampled. Cost: the
    /// final move before the cursor stops can lag by up to one interval (< 1
    /// frame), invisible at parallax cadence. `throttleFPS <= 0` disables it.
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

    /// True while the NSEvent mouse monitors are installed — not the start/stop
    /// lifecycle: a started publisher whose monitors were gated off by
    /// `setMouseMonitoringEnabled(false)` reports false. No production reader;
    /// tests observe the demand gate through it.
    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    /// Idempotent: a second `start()` while already running is a no-op.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        installGeometryObservers()
        publishGeometry() // seed current geometry so the first read isn't `.none`
        if mouseMonitoringEnabled { installMouseMonitors() }
    }

    /// The renderer's suspend/demand gate over the NSEvent monitors alone.
    /// Geometry observers stay installed so a later re-enable publishes against
    /// current geometry; the flag persists while stopped so a re-`start()` honors
    /// the last request. The `isStarted` guard is load-bearing: an enable queued
    /// before `detach()` can be delivered after it, and must not resurrect the
    /// monitors on a torn-down surface. Main-actor because NSEvent monitors must be added and
    /// removed on the main thread.
    func setMouseMonitoringEnabled(_ enabled: Bool) {
        mouseMonitoringEnabled = enabled
        guard isStarted else { return }
        if enabled {
            installMouseMonitors()
        } else {
            removeMouseMonitors()
        }
    }

    /// Idempotent: unloads both monitors and the geometry observers; safe to call
    /// when never started or already stopped.
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
        // Seed the cursor: the old live sampler read `NSEvent.mouseLocation`
        // every frame, so before any mouse *event* arrives — including right
        // after a gated-off stretch, when the slot still holds the pre-gate
        // position — the mailbox must report the real cursor (not the off-screen
        // sentinel) or the first frames would freeze parallax at center.
        let time = now()
        lastMousePublishAt = time
        mailbox.publishMouseLocation(NSEvent.mouseLocation, timestampNanos: Self.nanos(from: time))
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
    }

    // MARK: - Mouse

    private func handleMouseEvent() {
        let time = now()
        if throttleInterval > 0, time - lastMousePublishAt < throttleInterval { return }
        lastMousePublishAt = time
        // Global-monitor events carry no window; `NSEvent.mouseLocation` is the
        // screen-space cursor for both monitors, so the event's own coords are
        // deliberately unused.
        mailbox.publishMouseLocation(
            NSEvent.mouseLocation,
            timestampNanos: Self.nanos(from: time)
        )
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
    }

    /// The view's current frame in screen coordinates. Missing view/window or a
    /// degenerate bounds yields `.none`, matching `sampleSceneUV`'s guards so the
    /// mailbox resolves `.inactive`.
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
