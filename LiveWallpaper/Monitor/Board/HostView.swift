import AppKit
import LiveWallpaperCore
import SwiftUI

/// AppKit host that embeds the SwiftUI monitor board and connects it to the runtime.
@MainActor
final class HostView: NSView {

    private let dataModel: DataModel
    private let interactionModel: InteractionModel
    private let hostingView: NSHostingView<MonitorBoardRootContainer>

    private var allowMouseInteraction: Bool
    private var reduceMotion: Bool
    private(set) var isSuspended = false
    /// Inspector preview: name-only tiles so arranging never pumps live data.
    private let nameOnlyTiles: Bool

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
        nameOnlyTiles: Bool = false,
        topInsetFraction: CGFloat = 0,
        referenceWidth: CGFloat = 0
    ) {
        let reduceMotion = Self.effectiveReduceMotion(configuration)
        self.allowMouseInteraction = configuration.mouseInteractionEnabled
        self.nameOnlyTiles = nameOnlyTiles
        self.reduceMotion = reduceMotion
        self.dataModel = DataModel()
        self.interactionModel = InteractionModel(configuration: configuration)
        let container = MonitorBoardRootContainer(
            model: interactionModel,
            data: dataModel,
            reduceMotion: reduceMotion,
            suspended: false,
            nameOnlyTiles: nameOnlyTiles
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

    /// Call on pump restart for a NEW session only — not on same-session suspend/resume.
    func resetHistory() {
        dataModel.resetHistory()
    }

    // MARK: - Live configuration

    /// Apply without rebuilding the view.
    func apply(configuration: MonitorBoardConfiguration, topInsetFraction: CGFloat? = nil) {
        // Drop in-flight debounced persist: older edit would clobber this newer external config.
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        pendingPersistConfig = nil
        if let topInsetFraction { interactionModel.topInsetFraction = topInsetFraction }
        interactionModel.apply(configuration: configuration)
        allowMouseInteraction = configuration.mouseInteractionEnabled
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
            nameOnlyTiles: nameOnlyTiles
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        allowMouseInteraction = enabled
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

/// Wraps the board with the reduce-motion + suspend environment.
struct MonitorBoardRootContainer: View {
    @ObservedObject var model: InteractionModel
    @ObservedObject var data: DataModel
    let reduceMotion: Bool
    var suspended: Bool = false
    var nameOnlyTiles: Bool = false

    var body: some View {
        RootView(model: model, data: data, nameOnlyTiles: nameOnlyTiles)
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
