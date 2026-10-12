#if !LITE_BUILD
import AppKit
import LiveWallpaperCore

struct SceneHotZoneEvent: Equatable {
    enum Kind { case down, dragged, up, rightDown, rightUp, moved, entered, exited }
    let kind: Kind
    /// AppKit global screen coordinates (bottom-left origin).
    let screenLocation: CGPoint
    let timestamp: TimeInterval
}

@MainActor
final class SceneHotZoneController {
    private let onEvent: @MainActor (SceneHotZoneEvent) -> Void
    private var panels: [SceneHotZonePanel] = []
    private var zones: [CGRect] = []
    private var pressedPanel: SceneHotZonePanel?
    private var pressedKind: SceneHotZoneEvent.Kind?
    private var updatedWhilePressed = false
    private var lastLocation: CGPoint = .zero
    private var isTornDown = false

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                layout()
            } else {
                panels.forEach { $0.orderOut(nil) }
                cancelPress()
            }
        }
    }

    var isPressed: Bool {
        pressedPanel != nil
    }

    var panelsForTesting: [NSPanel] {
        panels
    }

    init(onEvent: @escaping @MainActor (SceneHotZoneEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// `zones` are AppKit global screen rects (bottom-left origin).
    func update(zones: [CGRect]) {
        guard !isTornDown else { return }
        self.zones = zones
        if isPressed {
            updatedWhilePressed = true
        }
        if isEnabled {
            layout()
        }
    }

    func tearDown() {
        isTornDown = true
        pressedPanel = nil
        pressedKind = nil
        panels.forEach { $0.close() }
        panels = []
    }

    private func layout() {
        guard !isTornDown, isEnabled else { return }
        let rects = zones.filter { $0.width >= 1 && $0.height >= 1 }
        var free = panels.filter { $0 !== pressedPanel }
        while free.count > rects.count {
            free.removeLast().close()
        }
        while free.count < rects.count {
            free.append(makePanel())
        }
        for (panel, rect) in zip(free, rects) {
            panel.setFrame(TestHostWindowParking.parkedFrame(rect), display: false)
            panel.orderFrontRegardless()
        }
        // Pressed panel first, so the re-layout after release hands it a zone instead of closing it.
        panels = (pressedPanel.map { [$0] } ?? []) + free
    }

    private func makePanel() -> SceneHotZonePanel {
        let panel = SceneHotZonePanel()
        let view = SceneHotZoneView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.autoresizingMask = [.width, .height]
        view.onMouse = { [weak self, weak panel] kind, event in
            guard let self, let panel else { return }
            handle(kind, event, from: panel)
        }
        panel.contentView = view
        return panel
    }

    private func handle(_ kind: SceneHotZoneEvent.Kind, _ event: NSEvent, from panel: SceneHotZonePanel) {
        let location = screenLocation(of: event, in: panel)
        lastLocation = location
        var released = false
        switch kind {
        case .down, .rightDown:
            if pressedPanel == nil {
                pressedPanel = panel
                pressedKind = kind
            }
        case .up, .rightUp:
            if panel === pressedPanel, kind == releaseKind(for: pressedKind) {
                pressedPanel = nil
                pressedKind = nil
                released = true
            }
        case .dragged, .moved, .entered, .exited:
            break
        }
        onEvent(SceneHotZoneEvent(kind: kind, screenLocation: location, timestamp: event.timestamp))
        if released, updatedWhilePressed {
            layout()
            updatedWhilePressed = false
        }
    }

    private func cancelPress() {
        guard let kind = releaseKind(for: pressedKind) else { return }
        pressedPanel = nil
        pressedKind = nil
        updatedWhilePressed = false
        onEvent(SceneHotZoneEvent(kind: kind, screenLocation: lastLocation, timestamp: ProcessInfo.processInfo.systemUptime))
    }

    private func releaseKind(for press: SceneHotZoneEvent.Kind?) -> SceneHotZoneEvent.Kind? {
        switch press {
        case .down: .up
        case .rightDown: .rightUp
        default: nil
        }
    }

    private func screenLocation(of event: NSEvent, in panel: NSPanel) -> CGPoint {
        let parked = panel.convertPoint(toScreen: event.locationInWindow)
        // Undo test-host parking so callers see the zone's real screen position.
        let logical = TestHostWindowParking.logicalFrame(panel).origin
        return CGPoint(x: parked.x - panel.frame.minX + logical.x, y: parked.y - panel.frame.minY + logical.y)
    }
}

private final class SceneHotZonePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        TestHostWindowParking.park(self)
        // `hidesOnDeactivate` defaults to true and would hide the zone whenever the app is inactive.
        hidesOnDeactivate = false
        canHide = false
        // `isFloatingPanel` rewrites `level`, so it must be set before the level.
        isFloatingPanel = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        sharingType = WallpaperCapturePolicy.windowSharingType
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class SceneHotZoneView: NSView {
    var onMouse: ((SceneHotZoneEvent.Kind, NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// No super calls: events must not bubble past the zone.
    override func mouseDown(with event: NSEvent) {
        onMouse?(.down, event)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouse?(.dragged, event)
    }

    override func mouseUp(with event: NSEvent) {
        onMouse?(.up, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onMouse?(.rightDown, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        onMouse?(.rightUp, event)
    }

    override func mouseMoved(with event: NSEvent) {
        onMouse?(.moved, event)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouse?(.entered, event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouse?(.exited, event)
    }
}
#endif
