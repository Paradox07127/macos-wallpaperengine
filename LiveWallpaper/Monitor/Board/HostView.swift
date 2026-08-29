import AppKit
import LiveWallpaperCore
import SwiftUI

/// How much of the board's window frame may swallow a pointer event.
///
/// AppKit dispatches by window frame, so a window made hit-testable for one
/// tile would eat every desktop click across the whole display. SwiftUI's
/// `allowsHitTesting(false)` does not hand the event back to the window below —
/// it only declines it inside this window — so the widget-only case has to be
/// filtered here, in `hitTest`, before AppKit ever consults the hosting view.
enum PointerScope: Equatable, Sendable {
    /// Click-through everywhere (the board behaves as plain wallpaper).
    case none
    /// Only the rectangles of widgets that asked for the pointer are live.
    case widgetsOnly
    /// The whole board takes the pointer (edit mode, or Mouse Interaction on).
    case wholeBoard
}

/// AppKit host that embeds the SwiftUI monitor board and connects it to the runtime.
@MainActor
final class HostView: NSView {

    private let dataModel: DataModel
    private let interactionModel: InteractionModel
    private let hostingView: NSHostingView<MonitorBoardRootContainer>

    private(set) var pointerScope: PointerScope
    private var reduceMotion: Bool
    private(set) var isSuspended = false
    /// The board inside the settings inspector rather than on the desktop:
    /// tiles are name-only (arranging must never pump live data) and the
    /// toolbar drops "Done", because leaving edit mode is what the preview is
    /// for — there is nothing else it could show.
    private let isInspectorPreview: Bool

    private var pendingPersistTask: Task<Void, Never>?
    /// Retained with the debounced task so teardown can flush synchronously instead of losing the final edit on cancel.
    private var pendingPersistConfig: MonitorBoardConfiguration?
    private static let persistDebounce: Duration = .milliseconds(250)

    var onConfigurationEdited: ((MonitorBoardConfiguration) -> Void)?

    /// Relays edit-mode transitions so the wallpaper host can force mouse interaction on while editing.
    var onEditingChanged: ((Bool) -> Void)? {
        get { interactionModel.onEditingChanged }
        set { interactionModel.onEditingChanged = newValue }
    }

    init(
        frame frameRect: NSRect,
        configuration: MonitorBoardConfiguration,
        isInspectorPreview: Bool = false,
        topInsetFraction: CGFloat = 0,
        referenceWidth: CGFloat = 0,
        historyStore: MonitorHistoryStore? = nil
    ) {
        let reduceMotion = Self.effectiveReduceMotion(configuration)
        self.pointerScope = Self.pointerScope(for: configuration, isEditing: false)
        self.isInspectorPreview = isInspectorPreview
        self.reduceMotion = reduceMotion
        self.dataModel = DataModel(historyStore: historyStore)
        self.interactionModel = InteractionModel(configuration: configuration)
        let container = MonitorBoardRootContainer(
            model: interactionModel,
            data: dataModel,
            reduceMotion: reduceMotion,
            suspended: false,
            isInspectorPreview: isInspectorPreview
        )
        self.hostingView = NSHostingView(rootView: container)

        super.init(frame: frameRect)

        interactionModel.topInsetFraction = topInsetFraction
        interactionModel.referenceWidth = referenceWidth

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)

        interactionModel.onConfigurationEdited = { [weak self] config in
            self?.scheduleConfigPersist(config)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingPersistTask?.cancel()
    }

    // MARK: - Data pump (externally driven)

    /// Runtime pushes at its own cadence; the host never polls.
    func push(_ snapshot: MonitorSnapshot) {
        dataModel.update(snapshot)
    }

    // MARK: - Live configuration

    /// Push a new board configuration (rebuilds the SwiftUI root).
    func apply(configuration: MonitorBoardConfiguration, topInsetFraction: CGFloat? = nil) {
        // Drop in-flight debounced persist: older edit would clobber this newer external config.
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        pendingPersistConfig = nil
        if let topInsetFraction { interactionModel.topInsetFraction = topInsetFraction }
        interactionModel.apply(configuration: configuration)
        pointerScope = Self.pointerScope(for: configuration, isEditing: interactionModel.isEditing)
        reduceMotion = Self.effectiveReduceMotion(configuration)
        rebuildRootView()
    }

    // MARK: - Suspend

    /// Stops the 1 Hz clock and repeating animations while the wallpaper is suspended.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        rebuildRootView()
    }

    private func rebuildRootView() {
        hostingView.rootView = MonitorBoardRootContainer(
            model: interactionModel,
            data: dataModel,
            reduceMotion: reduceMotion,
            suspended: isSuspended,
            isInspectorPreview: isInspectorPreview
        )
    }

    func setReferenceWidth(_ width: CGFloat) {
        guard interactionModel.referenceWidth != width else { return }
        interactionModel.referenceWidth = width
        if interactionModel.boardSize != .zero {
            interactionModel.reflow(boardSize: interactionModel.boardSize)
        }
    }

    // MARK: - Editing

    func setEditing(_ editing: Bool) {
        interactionModel.setEditing(editing)
    }

    var isEditing: Bool { interactionModel.isEditing }

    // MARK: - Click-through

    /// The scope a board should run at, given its config and edit state. Shared
    /// with `OverlayController` so the window's `ignoresMouseEvents` and this
    /// view's filter can never disagree.
    static func pointerScope(
        for configuration: MonitorBoardConfiguration,
        isEditing: Bool
    ) -> PointerScope {
        // No tile asks for the pointer on its own: the board is either being
        // edited, opted in wholesale, or plain wallpaper.
        isEditing || configuration.mouseInteractionEnabled ? .wholeBoard : .none
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinates (AppKit's hitTest
        // contract), so convert before comparing against board geometry.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard acceptsPointer(atLocalPoint: local) else { return nil }
        return super.hitTest(point)
    }

    /// Gate for one event, in this view's own coordinates. Split out of
    /// `hitTest` so it can be exercised without an NSHostingView underneath.
    func acceptsPointer(atLocalPoint local: NSPoint) -> Bool {
        switch pointerScope {
        case .none:
            return false
        case .wholeBoard:
            return true
        case .widgetsOnly:
            // Board tiles never claim the pointer by themselves; the Now Playing
            // layer, which does, has its own host.
            return false
        }
    }

    func setPointerScope(_ scope: PointerScope) {
        pointerScope = scope
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    // MARK: - Persistence debounce

    private func scheduleConfigPersist(_ config: MonitorBoardConfiguration) {
        pendingPersistTask?.cancel()
        pendingPersistConfig = config
        pendingPersistTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.persistDebounce)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingPersistConfig = nil
            self.pendingPersistTask = nil
            self.onConfigurationEdited?(config)
        }
    }

    /// Flush debounced edit immediately (teardown / window close).
    func flushPendingEdits() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        guard let config = pendingPersistConfig else { return }
        pendingPersistConfig = nil
        onConfigurationEdited?(config)
    }

    // MARK: - Helpers

    private static func effectiveReduceMotion(_ configuration: MonitorBoardConfiguration) -> Bool {
        if let override = configuration.reduceMotionOverride { return override }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

struct MonitorBoardRootContainer: View {
    @ObservedObject var model: InteractionModel
    @ObservedObject var data: DataModel
    let reduceMotion: Bool
    var suspended: Bool = false
    var isInspectorPreview: Bool = false

    var body: some View {
        RootView(model: model, data: data, isInspectorPreview: isInspectorPreview)
            .environment(\.monitorReduceMotion, reduceMotion)
            .environment(\.monitorSuspended, suspended)
    }
}

// MARK: - Menu-bar top inset

extension HostView {
    /// The display's menu-bar forbidden zone as a fraction of its height.
    static func menuBarTopInsetFraction(forFrame frame: NSRect) -> CGFloat {
        guard let screen = NSScreen.screens.first(where: { framesMatch($0.frame, frame) }) else { return 0 }
        let height = screen.frame.height
        guard height > 0 else { return 0 }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(0, min(menuBar / height, 1))
    }

    private static func framesMatch(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 1 && abs(a.origin.y - b.origin.y) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

// MARK: - Reduce-motion environment

/// System setting + config `reduceMotionOverride`.
private struct MonitorReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monitorReduceMotion: Bool {
        get { self[MonitorReduceMotionKey.self] }
        set { self[MonitorReduceMotionKey.self] = newValue }
    }
}

// MARK: - Suspend environment

/// True while performance policy has the wallpaper suspended.
private struct MonitorSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monitorSuspended: Bool {
        get { self[MonitorSuspendedKey.self] }
        set { self[MonitorSuspendedKey.self] = newValue }
    }
}
