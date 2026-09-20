import AppKit
import LiveWallpaperCore
import SwiftUI

/// Widget-only hit testing must happen in `hitTest` before AppKit sees the hosting view: `allowsHitTesting(false)` does not hand events to windows below.
enum PointerScope: Equatable, Sendable {
    /// Click-through everywhere (the board behaves as plain wallpaper).
    case none
    /// Only the rectangles of widgets that asked for the pointer are live.
    case widgetsOnly
    /// The whole board takes the pointer (edit mode, or Mouse Interaction on).
    case wholeBoard
}

@MainActor
final class HostView: NSView {

    private let dataModel: DataModel
    let interactionModel: InteractionModel
    private let hostingView: NSHostingView<MonitorBoardRootContainer>

    private(set) var pointerScope: PointerScope
    private var reduceMotion: Bool
    private(set) var isSuspended = false
    private(set) var preview: MonitorBoardPreview?

    var isInspectorPreview: Bool {
        preview != nil
    }

    /// What each tile draws in this host; nil on the desktop, which draws live.
    var previewTile: MonitorBoardPreview.Tile? {
        preview?.tile
    }

    /// Live sky for the Weather tile. Nil in the preview and in tests.
    private var weatherService: WeatherReactiveService?

    /// Layout size when it differs from the drawn size; shrink inside the SwiftUI tree, never via an AppKit transform on the host.
    var logicalSize: CGSize? {
        didSet {
            guard logicalSize != oldValue else { return }
            rebuildRootView()
        }
    }

    private var reduceMotionOverride: Bool?
    private lazy var reduceMotionWatcher = ReduceMotionWatcher { [weak self] _ in
        self?.systemReduceMotionDidChange()
    }

    private var pendingPersistTask: Task<Void, Never>?
    /// Retained with the debounced task so teardown can flush synchronously instead of losing the final edit on cancel.
    private var pendingPersistConfig: MonitorBoardConfiguration?
    private static let persistDebounce: Duration = .milliseconds(250)

    var onConfigurationEdited: ((MonitorBoardConfiguration) -> Void)?

    var onEditingChanged: ((Bool) -> Void)? {
        get { interactionModel.onEditingChanged }
        set { interactionModel.onEditingChanged = newValue }
    }

    init(
        frame frameRect: NSRect,
        configuration: MonitorBoardConfiguration,
        preview: MonitorBoardPreview? = nil,
        safeArea: MonitorSafeAreaInsets = .none,
        historyStore: MonitorHistoryStore? = nil,
        weatherService: WeatherReactiveService? = nil
    ) {
        let reduceMotion = Self.effectiveReduceMotion(configuration)
        self.pointerScope = Self.pointerScope(for: configuration, isEditing: false)
        self.preview = preview
        self.weatherService = weatherService
        self.reduceMotion = reduceMotion
        self.dataModel = DataModel(historyStore: historyStore)
        self.interactionModel = InteractionModel(configuration: configuration)
        let container = MonitorBoardRootContainer(
            model: interactionModel,
            data: dataModel,
            reduceMotion: reduceMotion,
            suspended: false,
            preview: preview,
            weatherService: weatherService
        )
        self.hostingView = NSHostingView(rootView: container)

        super.init(frame: frameRect)

        reduceMotionOverride = configuration.reduceMotionOverride
        reduceMotionWatcher.start()
        interactionModel.safeArea = safeArea

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

    func push(_ snapshot: MonitorSnapshot) {
        dataModel.update(snapshot)
    }

    // MARK: - Live configuration

    func apply(configuration: MonitorBoardConfiguration, safeArea: MonitorSafeAreaInsets? = nil) {
        // Drop in-flight debounced persist: older edit would clobber this newer external config.
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        pendingPersistConfig = nil
        if let safeArea {
            interactionModel.safeArea = safeArea
        }
        interactionModel.apply(configuration: configuration)
        pointerScope = Self.pointerScope(for: configuration, isEditing: interactionModel.isEditing)
        reduceMotionOverride = configuration.reduceMotionOverride
        reduceMotion = reduceMotionOverride ?? reduceMotionWatcher.isReduced
        rebuildRootView()
    }

    func setWeatherService(_ service: WeatherReactiveService?) {
        guard weatherService !== service else { return }
        weatherService = service
        rebuildRootView()
    }

    private func systemReduceMotionDidChange() {
        let next = reduceMotionOverride ?? reduceMotionWatcher.isReduced
        guard next != reduceMotion else { return }
        reduceMotion = next
        rebuildRootView()
    }

    #if DEBUG
    var debugReduceMotion: Bool {
        hostingView.rootView.reduceMotion
    }

    var debugWeatherService: WeatherReactiveService? {
        hostingView.rootView.weatherService
    }

    var reduceMotionWatcherOverride: Bool? {
        get { reduceMotionWatcher.override }
        set { reduceMotionWatcher.override = newValue }
    }
    #endif

    // MARK: - Suspend

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        rebuildRootView()
    }

    func setPreview(_ preview: MonitorBoardPreview) {
        guard self.preview != nil, self.preview != preview else { return }
        self.preview = preview
        rebuildRootView()
    }

    private(set) var forcesOpaquePanels = false

    var usesGlassPanels: Bool {
        MonitorPanelAppearance.usesGlass(
            UserDefaults.appScoped().object(forKey: MonitorPanelAppearance.glassKey) as? Bool
                ?? MonitorPanelAppearance.defaultGlass,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    func setForcesOpaquePanels(_ forced: Bool) {
        guard forcesOpaquePanels != forced else { return }
        forcesOpaquePanels = forced
        rebuildRootView()
    }

    private func rebuildRootView() {
        hostingView.rootView = MonitorBoardRootContainer(
            model: interactionModel,
            data: dataModel,
            reduceMotion: reduceMotion,
            suspended: isSuspended,
            preview: preview,
            weatherService: weatherService,
            logicalSize: logicalSize,
            forcesOpaquePanels: forcesOpaquePanels
        )
    }

    // MARK: - Editing

    func setEditing(_ editing: Bool) {
        interactionModel.setEditing(editing)
    }

    var isEditing: Bool { interactionModel.isEditing }

    // MARK: - Click-through

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

// MARK: - Menu-bar / Dock safe area

extension MonitorSafeAreaInsets {
    @MainActor
    static func of(_ screen: NSScreen) -> MonitorSafeAreaInsets {
        MonitorSafeAreaInsets(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// Matched by frame because the caller holds a display rect, not an
    /// `NSScreen`. An unmatched frame (a display that just went away) has no
    /// known Dock, so it gets no insets rather than another display's.
    @MainActor
    static func forScreen(matching frame: NSRect) -> MonitorSafeAreaInsets {
        guard let screen = NSScreen.screens.first(where: { framesMatch($0.frame, frame) }) else {
            return .none
        }
        return of(screen)
    }

    private static func framesMatch(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 1 && abs(a.origin.y - b.origin.y) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

// MARK: - Reduce-motion environment

private struct MonitorReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monitorReduceMotion: Bool {
        get { self[MonitorReduceMotionKey.self] }
        set { self[MonitorReduceMotionKey.self] = newValue }
    }
}

// MARK: - Render scale environment

extension EnvironmentValues {
    @Entry var monitorRenderScale: CGFloat = 1
}

// MARK: - Weather environment

extension EnvironmentValues {
    /// The app's one weather service, for the Weather tile. Nil where no sky is
    /// available (inspector preview, tests), and the tile says so instead of drawing one.
    @Entry var monitorWeather: WeatherReactiveService?
}

// MARK: - Suspend environment

private struct MonitorSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var monitorSuspended: Bool {
        get { self[MonitorSuspendedKey.self] }
        set { self[MonitorSuspendedKey.self] = newValue }
    }
}
