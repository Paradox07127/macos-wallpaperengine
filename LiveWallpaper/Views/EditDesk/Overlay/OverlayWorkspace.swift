import AppKit
import LiveWallpaperCore
import SwiftUI

/// The layer list floats above the canvas; expanding it never resizes the artwork.
struct OverlayWorkspace: View {
    /// Shared by the add strip's tile drags, the canvas frame and the drag ghost.
    nonisolated static let dragSpace = "overlayWorkspace"

    let session: OverlayEditorSession
    let cover: CGImage?
    let screen: Screen
    let size: CGSize
    @Binding var layersVisible: Bool
    @Binding var inspectorVisible: Bool
    @Binding var inspectorWidth: Double
    @Binding var liveInspectorWidth: Double?
    var topInset: CGFloat = 0
    let recapture: () -> Void
    let swipe: (DetailSwipeStep) -> Void
    /// The side this display's canvas slides in from when another display is switched to.
    let switchEdge: HorizontalEdge

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var interaction: InteractionModel
    @State private var addExpanded = true
    @State private var addDrag: OverlayAddDragController
    @AppStorage(MonitorBoardPreviewMode.defaultsKey) private var previewMode: MonitorBoardPreviewMode = .snapshot

    init(session: OverlayEditorSession, cover: CGImage?, screen: Screen, size: CGSize,
         layersVisible: Binding<Bool>, inspectorVisible: Binding<Bool>,
         inspectorWidth: Binding<Double>, liveInspectorWidth: Binding<Double?>,
         topInset: CGFloat = 0, recapture: @escaping () -> Void,
         swipe: @escaping (DetailSwipeStep) -> Void, switchEdge: HorizontalEdge,
         dragController: OverlayAddDragController = OverlayAddDragController()) {
        self.session = session
        _addDrag = State(initialValue: dragController)
        self.cover = cover
        self.screen = screen
        self.size = size
        _layersVisible = layersVisible
        _inspectorVisible = inspectorVisible
        _inspectorWidth = inspectorWidth
        _liveInspectorWidth = liveInspectorWidth
        self.topInset = topInset
        self.recapture = recapture
        self.swipe = swipe
        self.switchEdge = switchEdge
        interaction = session.interaction
    }

    private var drawerHeight: CGFloat {
        addExpanded ? AddOverlayDrawer.expandedHeight : AddOverlayDrawer.collapsedHeight
    }

    private var editorHeight: CGFloat {
        max(1, size.height - drawerHeight - topInset)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            InspectorSplit(
                isMounted: true, isVisible: inspectorVisible,
                animationTrigger: inspectorVisible, reduceMotion: reduceMotion,
                storedWidth: $inspectorWidth, liveWidth: $liveInspectorWidth,
                minWidth: 340, maxWidth: 440, mainFloor: 320,
                onClose: { inspectorVisible = false },
                main: { canvas }, inspector: { width in
                    ObjectInspector(session: session, screen: screen, screenManager: screenManager,
                                    placements: interaction.placements,
                                    height: editorHeight, width: width)
                        .overlay(alignment: .leading) { Divider() }
                }
            )
            .frame(height: editorHeight)
            AddOverlayDrawer(session: session, isExpanded: $addExpanded, height: drawerHeight) { phase in
                addDrag.handle(phase, session: session)
            }
            .overlay(alignment: .top) { Divider() }
        }
        .coordinateSpace(name: Self.dragSpace)
        .overlay(alignment: .topLeading) { ghost }
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: layersVisible)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: addExpanded)
        .onChange(of: session.selection) { _, selection in
            inspectorVisible = selection != nil
        }
        .onChange(of: screen.id, initial: true) { _, _ in
            inspectorVisible = session.selection != nil
        }
        .onChange(of: previewMode) { _, _ in session.capturePreview() }
        .onChange(of: sessionKey) { addDrag.cancel() }
        .onDisappear { addDrag.cancel() }
    }

    /// A tile drag belongs to one session: it ends when that session is detached or another display's replaces it.
    private var sessionKey: SessionKey {
        SessionKey(session: ObjectIdentifier(session), generation: session.gestureGeneration)
    }

    private struct SessionKey: Equatable {
        /// A swap to another display's session can arrive with the generation the old one had.
        let session: ObjectIdentifier
        /// Bumped by every `detach()`, which the host calls on the old session before switching displays.
        let generation: Int
    }

    private var rows: [OverlayLayerRow] {
        OverlayLayerList.rows(placements: interaction.placements,
                              boardEnabled: session.boardEnabled,
                              clockEnabled: session.overlay.clock.enabled,
                              musicEnabled: session.overlay.music.enabled,
                              effectVisible: session.effectVisible)
            .filter { row in
                // Disabled singleton layers are available in the add strip, rather than empty rows.
                // The widget group has no add-strip entry, so it always stays.
                if row.kind != .board, case let .toggle(isOn) = row.action {
                    return isOn || row.selection == session.selection
                }
                return true
            }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let box = OverlayGeometry.aspectFit(
                logicalSize: session.logicalSize,
                in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: OverlayGeometry.canvasInset, dy: OverlayGeometry.canvasInset)
            )
            ZStack(alignment: .topLeading) {
                OverlayCanvas(session: session, cover: cover, size: box.size)
                    .frame(width: box.width, height: box.height)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: DetailPreviewFrameKey.self,
                                                   value: [screen.id: geometry.frame(in: .named(DetailPreviewSpace.name))])
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        GlassIconButton("arrow.clockwise", action: recapture)
                            .help(Text("Recapture preview"))
                            .accessibilityLabel(Text("Recapture preview"))
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        floatingLayers(availableHeight: proxy.size.height)
                            .padding(12)
                    }
                    .id(screen.id)
                    .transition(.detailSwitch(from: switchEdge, reduceMotion: reduceMotion))
            }
            .animation(.detailSwitch(reduceMotion: reduceMotion), value: screen.id)
            // Off the column, not the canvas: mid-switch the arriving canvas is still sliding and the leaving one still reports.
            .onGeometryChange(for: CGRect.self) { geometry in
                let column = geometry.frame(in: .named(Self.dragSpace))
                return box.offsetBy(dx: column.minX, dy: column.minY)
            } action: { addDrag.canvasFrame = $0 }
            // Outside the per-display identity: rebuilt mid-swipe, it would count the rest of the gesture as a second step.
            .background(DetailSwipeNavigator(enabled: true, navigate: swipe))
        }
    }

    /// Follows the pointer off the canvas; over it the canvas draws the landing instead.
    @ViewBuilder
    private var ghost: some View {
        if let ghost = addDrag.ghost {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard, style: .continuous)
            AddOverlayTileFace(item: ghost.item, onCanvas: false)
                .background(shape.fill(DesignTokens.EditDesk.Colors.panel))
                .overlay(shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeHotShell, lineWidth: 1))
                .frame(width: AddOverlayDrawer.tileWidth(containerWidth: size.width, count: OverlayLayerList.addItems.count),
                       height: AddOverlayDrawer.tileHeight)
                .shadow(color: DesignTokens.EditDesk.Shadow.hoverCard.color, radius: DesignTokens.EditDesk.Shadow.hoverCard.radius,
                        y: DesignTokens.EditDesk.Shadow.hoverCard.y)
                .opacity(ghost.overCanvas ? 0 : OverlayGeometry.ghostOpacity)
                .animation(.easeOut(duration: OverlayGeometry.dropDuration), value: ghost.overCanvas)
                .position(ghost.point)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func floatingLayers(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button { layersVisible.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d")
                    Text("Layers")
                    Text(verbatim: "\(OverlayLayerList.layerCount(rows))").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(layersVisible ? 180 : 0))
                }
                .font(DesignTokens.EditDesk.Typography.body)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Layers"))
            .accessibilityValue(Text(layersVisible ? "Expanded" : "Collapsed"))
            if layersVisible {
                Divider().padding(.horizontal, 12)
                LayerNavigator(session: session, rows: rows,
                               height: min(CGFloat(rows.count) * OverlayColumnLayout.rowHeight,
                                           max(30, min(300, availableHeight - 76))))
                    .padding(.vertical, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 220)
        .clipped()
        .adaptiveGlassSurface(.roundedRectangle(14))
    }
}

/// One add-strip drag at a time: where the ghost is, whether the pointer is over the canvas, and Escape.
@MainActor
@Observable
final class OverlayAddDragController {
    struct Ghost: Equatable {
        var item: OverlayAddItem
        var point: CGPoint
        var overCanvas: Bool
    }

    private(set) var ghost: Ghost?
    /// The canvas in `OverlayWorkspace.dragSpace`.
    @ObservationIgnored var canvasFrame = CGRect.zero
    /// Set by Escape; the rest of that gesture's events are ignored until its release.
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var escapeMonitor: Any?
    @ObservationIgnored private weak var session: OverlayEditorSession?

    func handle(_ phase: OverlayAddDragPhase, session: OverlayEditorSession) {
        switch phase {
        case let .began(item, point):
            finish()
            self.session = session
            cancelled = false
            ghost = Ghost(item: item, point: point, overCanvas: false)
            watchEscape()
            track(point)
        case let .moved(point):
            guard !cancelled, ghost != nil else { return }
            track(point)
        case let .ended(point):
            guard !cancelled, ghost != nil else {
                cancelled = false
                return
            }
            track(point)
            session.endAddDrag(commit: canvasFrame.contains(point))
            finish()
        }
    }

    func cancel() {
        guard ghost != nil else { return }
        session?.endAddDrag(commit: false)
        cancelled = true
        finish()
    }

    private func track(_ point: CGPoint) {
        guard let session, var ghost else { return }
        ghost.point = point
        ghost.overCanvas = canvasFrame.contains(point)
        self.ghost = ghost
        let scale = OverlayGeometry.validScale(session.renderScale)
        let boardPoint = ghost.overCanvas
            ? CGPoint(x: (point.x - canvasFrame.minX) / scale, y: (point.y - canvasFrame.minY) / scale)
            : nil
        let flags = NSEvent.modifierFlags
        session.updateAddDrag(ghost.item, boardPoint: boardPoint, bypassSnap: flags.contains(.command) || flags.contains(.option))
    }

    private func finish() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
            NSCursor.pop()
        }
        ghost = nil
    }

    /// A local monitor sees the key before the detail page's Escape shortcut, which would otherwise close the page.
    private func watchEscape() {
        NSCursor.closedHand.push()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.ghost != nil else { return false }
                self.cancel()
                return true
            }
            return consumed ? nil : event
        }
    }
}
