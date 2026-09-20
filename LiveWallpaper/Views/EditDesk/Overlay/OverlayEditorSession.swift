import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

enum OverlaySelection: Hashable {
    case widget(UUID), music, clock, effect
}

struct OverlayEditorIdentity: Hashable {
    let displayID: CGDirectDisplayID
    let fingerprint: String
}

struct OverlayEditorSnapshot {
    var overlay: MonitorOverlayConfiguration
    var configuration: ScreenConfiguration?
    var logicalSize: CGSize
    var safeArea: MonitorSafeAreaInsets
}

@MainActor
protocol OverlayEditorStore: AnyObject {
    var displays: [OverlayEditorIdentity] { get }
    func read(_ identity: OverlayEditorIdentity) -> OverlayEditorSnapshot?
    func writeBoard(_ board: MonitorBoardConfiguration, for identity: OverlayEditorIdentity)
    func writeOverlayEnabled(_ enabled: Bool, for identity: OverlayEditorIdentity)
    func writeMusic(_ music: MusicOverlayConfiguration, for identity: OverlayEditorIdentity)
    func writeClock(_ clock: ClockOverlayConfiguration, for identity: OverlayEditorIdentity)
    func writeEffect(_ effect: ParticleEffect, for identity: OverlayEditorIdentity)
    func copy(_ kind: OverlayKind, from identity: OverlayEditorIdentity)
}

@MainActor
final class OverlayEditorScreenStore: OverlayEditorStore {
    let manager: ScreenManager

    init(manager: ScreenManager) {
        self.manager = manager
    }

    var displays: [OverlayEditorIdentity] {
        manager.screens.map { OverlayEditorIdentity(displayID: $0.id, fingerprint: $0.displayFingerprint) }
    }

    private func screen(_ identity: OverlayEditorIdentity) -> Screen? {
        manager.screens.first { $0.id == identity.displayID && $0.displayFingerprint == identity.fingerprint }
    }

    func read(_ identity: OverlayEditorIdentity) -> OverlayEditorSnapshot? {
        guard let screen = screen(identity) else { return nil }
        return OverlayEditorSnapshot(
            overlay: manager.monitorOverlay(for: screen), configuration: manager.getConfiguration(for: screen),
            logicalSize: CGSize(width: max(screen.frame.width, 1), height: max(screen.frame.height, 1)),
            safeArea: MonitorSafeAreaInsets.of(screen.nsScreen)
        )
    }

    func writeBoard(_ board: MonitorBoardConfiguration, for identity: OverlayEditorIdentity) {
        guard let screen = screen(identity) else { return }
        manager.setMonitorOverlayBoard(board, for: screen)
    }

    func writeOverlayEnabled(_ enabled: Bool, for identity: OverlayEditorIdentity) {
        guard let screen = screen(identity) else { return }
        manager.setMonitorOverlayEnabled(enabled, for: screen)
    }

    func writeMusic(_ music: MusicOverlayConfiguration, for identity: OverlayEditorIdentity) {
        guard let screen = screen(identity) else { return }
        manager.setMusicOverlay(music, for: screen)
    }

    func writeClock(_ clock: ClockOverlayConfiguration, for identity: OverlayEditorIdentity) {
        guard let screen = screen(identity) else { return }
        manager.setClockOverlay(clock, for: screen)
    }

    func writeEffect(_ effect: ParticleEffect, for identity: OverlayEditorIdentity) {
        guard let screen = screen(identity) else { return }
        manager.updateParticleEffect(effect, for: screen)
    }

    func copy(_ kind: OverlayKind, from identity: OverlayEditorIdentity) {
        guard let screen = screen(identity) else { return }
        manager.applyOverlayToAllDisplays(kind, from: screen)
    }
}

@MainActor
@Observable
final class OverlayEditorSession {
    enum LifecycleStep: Equatable { case flush, endGestures, unbind, load }

    struct CopyResult: Equatable {
        var copied: Int
        var total: Int
    }

    struct Drag {
        var selection: OverlaySelection
        var startRect: CGRect
        var rect: CGRect
        var snap: MonitorSnapResult
        var didMove = false
    }

    let interaction: InteractionModel
    let data = DataModel()
    private(set) var identity: OverlayEditorIdentity?
    private(set) var selection: OverlaySelection?
    private(set) var overlay = MonitorOverlayConfiguration.default
    private(set) var draft = DraftState.default
    private(set) var canEditEffect = false
    private(set) var logicalSize = CGSize(width: 1, height: 1)
    private(set) var safeArea = MonitorSafeAreaInsets.none
    private(set) var drag: Drag?
    private(set) var isActive = false
    private(set) var gestureGeneration = 0
    var renderScale: CGFloat = 1 {
        didSet { interaction.renderScale = renderScale }
    }

    var snapEnabled = true {
        didSet { interaction.snapEnabled = snapEnabled }
    }

    private(set) var preview = MonitorBoardPreview(mode: .snapshot)
    @ObservationIgnored var onLifecycleStep: ((LifecycleStep) -> Void)?
    @ObservationIgnored private var store: (any OverlayEditorStore)?
    @ObservationIgnored private var pendingBoard: MonitorBoardConfiguration?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let persistDebounce: Duration = .milliseconds(250)

    init(defaults: UserDefaults = .appScoped()) {
        self.defaults = defaults
        interaction = InteractionModel(configuration: .default)
    }

    func transition(to identity: OverlayEditorIdentity?, store: any OverlayEditorStore, editing: Bool) {
        detach()
        self.store = store
        if self.identity != identity {
            selection = nil
        }
        self.identity = identity
        onLifecycleStep?(.load)
        guard let identity, let snapshot = store.read(identity) else { return }
        load(snapshot)
        isActive = editing
        bind()
        interaction.setEditing(editing)
    }

    func capturePreview() {
        let mode = defaults.string(forKey: MonitorBoardPreviewMode.defaultsKey)
            .flatMap(MonitorBoardPreviewMode.init(rawValue:)) ?? .snapshot
        preview = MonitorBoardPreview.resolve(mode: mode, latest: OverlayController.shared.lastDeliveredData)
    }

    func detach() {
        onLifecycleStep?(.flush)
        flushPendingEdits()
        onLifecycleStep?(.endGestures)
        interaction.endDrag(bypassSnap: !snapEnabled)
        endDrag()
        // Ending a board gesture emits its final placement while the old writer is still bound.
        flushPendingEdits()
        isActive = false
        gestureGeneration += 1
        onLifecycleStep?(.unbind)
        interaction.onConfigurationEdited = nil
        interaction.onSelectionChanged = nil
        interaction.setEditing(false)
        store = nil
    }

    private func load(_ snapshot: OverlayEditorSnapshot) {
        overlay = snapshot.overlay
        logicalSize = snapshot.logicalSize
        safeArea = snapshot.safeArea
        draft = DraftState.from(config: snapshot.configuration, fallbackHasPreviewSource: false)
        canEditEffect = snapshot.configuration != nil
        interaction.safeArea = safeArea
        interaction.boardSize = logicalSize
        interaction.apply(configuration: overlay.board)
        if case let .widget(id) = selection, !interaction.placements.contains(where: { $0.id == id }) {
            selection = nil
        }
    }

    private func bind() {
        interaction.onConfigurationEdited = { [weak self] board in self?.scheduleBoard(board) }
        interaction.onSelectionChanged = { [weak self] id in
            guard let self else { return }
            if let id {
                selection = .widget(id)
            } else if case .widget = selection {
                selection = nil
            }
        }
        if case let .widget(id) = selection {
            interaction.select(id)
        }
    }

    func refreshAppliedConfiguration() {
        guard let identity, let snapshot = store?.read(identity) else { return }
        draft = DraftState.from(config: snapshot.configuration, fallbackHasPreviewSource: false)
        canEditEffect = snapshot.configuration != nil
        guard pendingBoard == nil, interaction.drag == nil, drag == nil else { return }
        if snapshot.overlay != overlay || snapshot.logicalSize != logicalSize || snapshot.safeArea != safeArea {
            load(snapshot)
        }
    }

    func select(_ next: OverlaySelection?) {
        if case let .widget(id) = next {
            interaction.select(id)
        } else {
            interaction.select(nil)
        }
        selection = next
    }

    func deleteSelection() {
        guard isActive, case let .widget(id) = selection else { return }
        interaction.perform(.delete(id: id))
    }

    func setMusicEnabled(_ enabled: Bool) {
        guard let identity, let store, var next = store.read(identity)?.overlay.music, next.enabled != enabled else {
            return
        }
        next.enabled = enabled
        overlay.music = next
        store.writeMusic(next, for: identity)
    }

    func setClockEnabled(_ enabled: Bool) {
        guard let identity, let store, var next = store.read(identity)?.overlay.clock, next.enabled != enabled else {
            return
        }
        next.enabled = enabled
        overlay.clock = next
        store.writeClock(next, for: identity)
    }

    /// `overlay.enabled` gates the whole board, so adding into a switched-off board would write a
    /// widget nothing renders.
    @discardableResult
    func addWidget(kind: MonitorWidgetKind) -> Bool {
        if !overlay.enabled, let identity, let store {
            overlay.enabled = true
            store.writeOverlayEnabled(true, for: identity)
        }
        return interaction.addWidget(kind: kind)
    }

    func removeWidget(id: UUID) {
        guard isActive else { return }
        interaction.perform(.delete(id: id))
    }

    func moveSelection(_ direction: MonitorBoardPlacementDirection) {
        guard isActive else { return }
        if case let .widget(id) = selection {
            interaction.moveWidget(id: id, direction: direction)
        } else if let selection, selection == .music || selection == .clock {
            let delta = switch direction {
            case .left: CGSize(width: -10, height: 0)
            case .right: CGSize(width: 10, height: 0)
            case .up: CGSize(width: 0, height: -10)
            case .down: CGSize(width: 0, height: 10)
            }
            updateDrag(selection, translation: delta, bypassSnap: true)
            endDrag()
        }
    }

    private func scheduleBoard(_ board: MonitorBoardConfiguration) {
        overlay.board = board
        pendingBoard = board
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.persistDebounce) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flushPendingEdits()
        }
    }

    func flushPendingEdits() {
        persistTask?.cancel()
        persistTask = nil
        guard let board = pendingBoard, let identity, let store else { return }
        pendingBoard = nil
        store.writeBoard(board, for: identity)
    }

    func rect(for selection: OverlaySelection) -> CGRect {
        if let drag, drag.selection == selection {
            return drag.rect
        }
        switch selection {
        case .music: return OverlayGeometry.musicRect(overlay.music, logicalSize: logicalSize, safeArea: safeArea)
        case .clock: return OverlayGeometry.clockRect(overlay.clock, logicalSize: logicalSize, safeArea: safeArea)
        case .widget, .effect: return .zero
        }
    }

    func updateDrag(_ selection: OverlaySelection, translation: CGSize, bypassSnap: Bool) {
        guard isActive, selection == .music || selection == .clock else { return }
        if drag == nil {
            select(selection)
            let start = rect(for: selection)
            drag = Drag(selection: selection, startRect: start, rect: start,
                        snap: MonitorSnapResult(origin: start.origin, snappedX: false, snappedY: false, guideX: nil, guideY: nil))
        }
        guard var drag, drag.selection == selection else { return }
        guard translation != .zero || drag.didMove else { return }
        drag.didMove = true
        let free = drag.startRect.offsetBy(dx: translation.width, dy: translation.height)
        let candidates = overlay.enabled ? interaction.placements.map {
            MonitorBoardItem(id: $0.id, rect: CGRect(origin: interaction.pixelOrigin(for: $0), size: interaction.footprint(for: $0)))
        } : []
        drag.snap = OverlayGeometry.snap(freeRect: free, geometry: interaction.geometry, candidates: candidates,
                                         renderScale: renderScale, enabled: snapEnabled && !bypassSnap)
        let origin: CGPoint
        if selection == .music {
            let inset = interaction.geometry.tileInset
            let raw = interaction.geometry.clampOrigin(
                CGPoint(x: drag.snap.origin.x - inset, y: drag.snap.origin.y - inset),
                footprint: CGSize(width: free.width + 2 * inset, height: free.height + 2 * inset)
            )
            origin = CGPoint(x: raw.x + inset, y: raw.y + inset)
        } else {
            origin = interaction.geometry.clampOrigin(drag.snap.origin, footprint: free.size)
        }
        if origin.x != drag.snap.origin.x {
            drag.snap.guideX = nil
        }
        if origin.y != drag.snap.origin.y {
            drag.snap.guideY = nil
        }
        drag.rect = CGRect(origin: origin, size: free.size)
        self.drag = drag
    }

    func endDrag() {
        guard let drag, let identity, let store else { return }
        self.drag = nil
        guard drag.didMove, let latest = store.read(identity)?.overlay else { return }
        switch drag.selection {
        case .music:
            // Music persists the raw cell origin; the drag rectangle excludes the gutter.
            let inset = interaction.geometry.tileInset
            let origin = CGPoint(x: drag.rect.minX - inset, y: drag.rect.minY - inset)
            let normalized = LayoutEngine.normalized(pixelOrigin: origin, boardSize: logicalSize)
            let next = MusicOverlayLayout.setting(x: normalized.x, y: normalized.y, on: latest.music)
            overlay.music = next
            if next != latest.music {
                store.writeMusic(next, for: identity)
            }
        case .clock:
            let next = ClockOverlayLayout.placing(latest.clock, origin: drag.rect.origin, canvas: logicalSize,
                                                  referenceWidth: 0, safeArea: safeArea)
            overlay.clock = next
            if next != latest.clock {
                store.writeClock(next, for: identity)
            }
        case .widget, .effect: break
        }
    }

    var effectVisible: Bool {
        draft.selectedParticleEffect != .none
    }

    func setEffectVisible(_ visible: Bool) {
        guard canEditEffect, let identity, let store else { return }
        let key = "Overlay.LastParticleEffect.\(identity.fingerprint)"
        let next: ParticleEffect
        if visible {
            next = defaults.string(forKey: key).flatMap(ParticleEffect.init(rawValue:)) ?? .snow
        } else {
            if draft.selectedParticleEffect != .none {
                defaults.set(draft.selectedParticleEffect.rawValue, forKey: key)
            }
            next = .none
        }
        store.writeEffect(next, for: identity)
        refreshAppliedConfiguration()
    }

    func copyToOtherDisplays() -> CopyResult {
        guard let identity, let store else { return CopyResult(copied: 0, total: 0) }
        let editing = isActive
        transition(to: identity, store: store, editing: editing)
        let targets = store.displays.filter { $0 != identity }
        let source = store.read(identity)
        for kind in OverlayKind.allCases {
            store.copy(kind, from: identity)
        }
        let copied = targets.filter { target in
            guard let source, let actual = store.read(target), actual.overlay == source.overlay,
                  let sourceConfig = source.configuration, let targetConfig = actual.configuration else { return false }
            var expected = targetConfig
            expected.adoptWeatherOverlay(from: sourceConfig)
            return expected == targetConfig
        }.count
        return CopyResult(copied: copied, total: targets.count)
    }
}
