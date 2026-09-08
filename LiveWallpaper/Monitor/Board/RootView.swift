import SwiftUI
import LiveWallpaperCore

// MARK: - Monitor board root view

// MARK: - Board clock

/// Single board clock: 1 Hz, stopped while suspended (avoids per-widget timers).
struct MonitorBoardClock: TimelineSchedule {
    let suspended: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let suspended = self.suspended
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = suspended ? nil : current.addingTimeInterval(1)
            return current
        }
    }
}

struct RootView: View {
    @ObservedObject var model: InteractionModel
    @ObservedObject var data: DataModel
    /// History is @Published inside the data model — observe it so tiles re-render on sample.
    @ObservedObject private var history: MonitorHistoryStore
    @Environment(\.monitorReduceMotion) private var reduceMotion
    @Environment(\.monitorSuspended) private var suspended
    /// How far the board is being shrunk into the inspector canvas. Only the
    /// edit chrome reads it — a widget tile shrinks with the board on purpose.
    @Environment(\.monitorRenderScale) private var renderScale
    @FocusState private var boardFocused: Bool

    @State private var addButtonFrame: CGRect = .zero
    @State private var toolbarFrame: CGRect = .zero
    /// Non-nil only for the settings inspector's copy of the board.
    private let preview: MonitorBoardPreview?

    private var isInspectorPreview: Bool {
        preview != nil
    }

    init(model: InteractionModel, data: DataModel, preview: MonitorBoardPreview? = nil) {
        self.model = model
        self.data = data
        self.history = data.historyStore
        self.preview = preview
    }

    var body: some View {
        TimelineView(MonitorBoardClock(suspended: suspended)) { timeline in
            boardContent(now: timeline.date)
        }
        .background(Color.clear)
        .focusable(model.isEditing)
        .focused($boardFocused)
        // Keep keyboard nudge and Delete support; the selected widget provides focus feedback
        // instead of a focus ring around the entire canvas.
        .focusEffectDisabled()
        .onMoveCommand(perform: handleMoveCommand)
        .onDeleteCommand {
            model.deleteSelectedWidget()
        }
        .onAppear { boardFocused = model.isEditing }
        .onChange(of: model.isEditing) { _, editing in
            boardFocused = editing
        }
    }

    @ViewBuilder
    private func boardContent(now: Date) -> some View {
        GeometryReader { proxy in
            let boardSize = proxy.size
            let geometry = MonitorBoardGeometry(
                boardSize: boardSize,
                safeArea: model.safeArea
            )

            ZStack(alignment: .topLeading) {
                // Empty space stays click-through unless the user opted the
                // board into the pointer. A window made hit-testable only for
                // a Now Playing layer's transport controls must not swallow
                // desktop clicks everywhere else.
                Color.clear
                    .contentShape(Rectangle())
                    .modifier(EmptyTapModifier(model: model))
                    .allowsHitTesting(model.isEditing || model.acceptsBoardWidePointer)

                if !geometry.isDegenerate {
                    if model.placements.isEmpty {
                        emptyBoardHint(boardSize: boardSize)
                    }

                    if model.isEditing, let drag = model.drag {
                        guideLayer(drag: drag, geometry: geometry)
                        ghostFrame(drag: drag, geometry: geometry)
                    }

                    ForEach(model.placements) { placement in
                        widgetTile(placement, geometry: geometry, now: now)
                    }

                    if model.isEditing {
                        editControls(geometry: geometry, boardSize: boardSize)
                    }
                }
            }
            .frame(width: boardSize.width, height: boardSize.height, alignment: .topLeading)
            .coordinateSpace(name: MonitorBoardCoordinateSpace.name)
            .onPreferenceChange(MonitorAddButtonFrameKey.self) { addButtonFrame = $0 }
            .onPreferenceChange(MonitorBoardToolbarFrameKey.self) { toolbarFrame = $0 }
            .onAppear { model.reflow(boardSize: boardSize) }
            .onChange(of: boardSize) { _, newSize in model.reflow(boardSize: newSize) }
        }
    }

    // MARK: Empty-board hint

    /// Passive (no hit testing); only while the board is empty.
    private func emptyBoardHint(boardSize: CGSize) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(MonitorBoardStrings.emptyBoardHint)
                .font(DesignTokens.Typography.body.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .frame(width: min(boardSize.width - 24, 320))
        .position(x: boardSize.width / 2, y: boardSize.height / 2)
        .allowsHitTesting(false)
        .zIndex(2)
    }

    // MARK: Widget tiles

    @ViewBuilder
    private func widgetTile(
        _ placement: MonitorWidgetPlacement,
        geometry: MonitorBoardGeometry,
        now: Date
    ) -> some View {
        let restRawRect = rawRect(placement, geometry: geometry)
        let isDragging = model.drag?.widgetID == placement.id
        // Drag follows free origin; ghost shows snapped target separately.
        let liveRawRect = isDragging ? draggedRawRect(placement, geometry: geometry) : restRawRect
        let liveRenderRect = geometry.renderRect(forRawRect: liveRawRect)

        tileBody(placement: placement, cornerRadius: geometry.cornerRadius, renderHeight: liveRenderRect.height, now: now)
            .frame(width: liveRenderRect.width, height: liveRenderRect.height)
            .modifier(SelectionChrome(
                isEditing: model.isEditing,
                isSelected: model.selectedID == placement.id,
                isDragging: isDragging,
                cornerRadius: geometry.cornerRadius
            ))
            .offset(x: liveRenderRect.minX, y: liveRenderRect.minY)
            .zIndex(isDragging ? 40 : 3)
            // Board tiles are display-only outside edit mode; the window above
            // is click-through anyway unless Mouse Interaction is on.
            .allowsHitTesting(model.isEditing)
            .modifier(WidgetDragModifier(
                model: model,
                placement: placement,
                geometry: geometry,
                restRawRect: restRawRect
            ))
            .modifier(MonitorPlacementAccessibilityActions(
                model: model,
                placementID: placement.id
            ))
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            model.moveSelectedWidget(.left)
        case .right:
            model.moveSelectedWidget(.right)
        case .up:
            model.moveSelectedWidget(.up)
        case .down:
            model.moveSelectedWidget(.down)
        @unknown default:
            break
        }
    }

    @ViewBuilder
    private func tileBody(
        placement: MonitorWidgetPlacement,
        cornerRadius: CGFloat,
        renderHeight: CGFloat,
        now: Date
    ) -> some View {
        if let preview {
            switch preview.tile {
            case .names:
                MonitorWidgetNameTile(kind: placement.kind, cellHeight: renderHeight, cornerRadius: cornerRadius)
            case .empty:
                MonitorPreviewEmptyTile(
                    kind: placement.kind, cellHeight: renderHeight, cornerRadius: cornerRadius
                )
            case .widget:
                // Same factory the desktop uses, on frozen data and a frozen
                // clock — the clock is what every chart's window is measured
                // from, so a preview left open does not slide its own samples
                // off the axis.
                WidgetFactory.tile(
                    context: MonitorWidgetContext(
                        snapshot: preview.snapshot ?? MonitorSnapshot(),
                        history: preview.history,
                        placement: placement,
                        isEditing: model.isEditing,
                        reduceMotion: reduceMotion,
                        now: preview.chartReference(fallback: now)
                    )
                )
            }
        } else {
            WidgetFactory.tile(
                context: MonitorWidgetContext(
                    snapshot: data.snapshot,
                    history: history.current,
                    placement: placement,
                    isEditing: model.isEditing,
                    reduceMotion: reduceMotion,
                    now: now
                )
            )
        }
    }

    private func rawRect(_ placement: MonitorWidgetPlacement, geometry: MonitorBoardGeometry) -> CGRect {
        let origin = LayoutEngine.pixelOrigin(
            normalized: CGPoint(x: placement.x, y: placement.y), boardSize: geometry.boardSize
        )
        let footprint = geometry.pixelSize(for: placement.kind, size: placement.size)
        // Clamp for draw only: coords from another aspect's grid can overflow until reflow; stored values stay untouched.
        return CGRect(origin: geometry.clampOrigin(origin, footprint: footprint), size: footprint)
    }

    private func draggedRawRect(_ placement: MonitorWidgetPlacement, geometry: MonitorBoardGeometry) -> CGRect {
        guard let drag = model.drag else { return rawRect(placement, geometry: geometry) }
        return CGRect(origin: drag.freeOrigin, size: drag.footprint)
    }

    // MARK: Ghost frame and guides

    @ViewBuilder
    private func ghostFrame(drag: MonitorBoardDragState, geometry: MonitorBoardGeometry) -> some View {
        if let ghostOrigin = drag.snappedOrigin {
            let raw = CGRect(origin: ghostOrigin, size: drag.footprint)
            let rect = geometry.renderRect(forRawRect: raw)
            RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                .fill(DesignTokens.Colors.boardEditAccent.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.boardEditAccent.opacity(0.5), lineWidth: 1)
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .zIndex(6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func guideLayer(drag: MonitorBoardDragState, geometry: MonitorBoardGeometry) -> some View {
        let draggedRect = CGRect(origin: drag.snappedOrigin ?? drag.freeOrigin, size: drag.footprint)
        ZStack {
            if let guide = drag.guideX {
                guideLine(guide, draggedRect: draggedRect, geometry: geometry)
            }
            if let guide = drag.guideY {
                guideLine(guide, draggedRect: draggedRect, geometry: geometry)
            }
        }
        .zIndex(6)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func guideLine(
        _ guide: MonitorSnapGuide,
        draggedRect: CGRect,
        geometry: MonitorBoardGeometry
    ) -> some View {
        let seg = LayoutEngine.guideSegment(guide, draggedRect: draggedRect, geometry: geometry)
        Path { path in
            path.move(to: seg.start)
            path.addLine(to: seg.end)
        }
        .stroke(DesignTokens.Colors.boardEditAccent.opacity(0.55), lineWidth: 1)
    }

    // MARK: Edit controls (floating per-widget + catalog)

    @ViewBuilder
    private func editControls(geometry: MonitorBoardGeometry, boardSize: CGSize) -> some View {
        // Chrome sizes itself in screen points and is grown back to board points;
        // panels are still placed in board points. Every conversion is here.
        let metrics = MonitorBoardChromeMetrics(boardSize: boardSize, renderScale: renderScale)

        MonitorBoardEditToolbar(model: model, showsDone: !isInspectorPreview)
            .monitorChromeScaled()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MonitorBoardToolbarFrameKey.self,
                        value: proxy.frame(in: .named(MonitorBoardCoordinateSpace.name))
                    )
                }
            )
            .padding(.top, metrics.toolbarTopInset)
            .frame(width: boardSize.width, height: boardSize.height, alignment: .top)
            .zIndex(70)

        if let selectedID = model.selectedID,
           let placement = model.placements.first(where: { $0.id == selectedID }),
           model.drag == nil {
            let render = geometry.renderRect(forRawRect: rawRect(placement, geometry: geometry))
            MonitorWidgetControlBar(model: model, placement: placement)
                .fixedSize()
                .monitorChromeScaled()
                .modifier(ControlBarPlacement(
                    anchorRect: render,
                    boardSize: boardSize,
                    estimatedSize: metrics.controlBarEstimate(for: placement.kind),
                    boost: metrics.boost
                ))
                .zIndex(60)
        }

        if let settingsID = model.settingsOpenID,
           let placement = model.placements.first(where: { $0.id == settingsID }),
           model.drag == nil {
            let render = geometry.renderRect(forRawRect: rawRect(placement, geometry: geometry))
            MonitorWidgetSettingsCard(
                model: model, placement: placement, maxHeight: metrics.settingsCardMaxHeight
            )
            .monitorChromeScaled()
            .modifier(SettingsCardPlacement(
                anchorRect: render, boardSize: boardSize, boost: metrics.boost
            ))
            .zIndex(80)
        }

        if model.isCatalogOpen {
            let catalogWidth = metrics.catalogWidth
            let anchor = metrics.catalogAnchor(
                toolbarFrame: toolbarFrame, addButtonFrame: addButtonFrame
            )
            let scrollCap = metrics.catalogScrollCap(anchorMaxY: anchor.maxY)
            MonitorCatalogView(model: model, maxScrollHeight: scrollCap)
                .frame(width: catalogWidth)
                .fixedSize(horizontal: false, vertical: true)
                .monitorChromeScaled()
                .modifier(CatalogBelowPlacement(
                    anchorFrame: anchor,
                    boardSize: boardSize,
                    panelWidth: metrics.board(catalogWidth),
                    estimatedHeight: metrics.board(scrollCap + 64),
                    boost: metrics.boost
                ))
                .zIndex(75)
        }
    }
}

// MARK: - Empty-space tap

private struct EmptyTapModifier: ViewModifier {
    @ObservedObject var model: InteractionModel

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) {
                model.setEditing(!model.isEditing)
            }
            .onTapGesture {
                guard model.isEditing else { return }
                model.select(nil)
                model.isCatalogOpen = false
                model.settingsOpenID = nil
            }
    }
}

// MARK: - Selection / hover chrome

/// Edit-mode hairline + drag shadow; no-op outside edit mode.
private struct SelectionChrome: ViewModifier {
    let isEditing: Bool
    let isSelected: Bool
    let isDragging: Bool
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(borderOverlay)
            .shadow(
                color: Color.black.opacity(isDragging ? 0.55 : 0),
                radius: isDragging ? 28 : 0, x: 0, y: isDragging ? 16 : 0
            )
            .onHover { if isEditing { hovering = $0 } }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isEditing && (isSelected || isDragging || hovering) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    DesignTokens.Colors.boardEditBorder.opacity(isSelected || isDragging ? 0.55 : 0.3),
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Floating-panel placement

/// Keep panel left edge inside the board; centre if wider than available span.
private func clampPanelLeft(_ left: CGFloat, width: CGFloat, span: CGFloat, margin: CGFloat) -> CGFloat {
    let maxLeft = span - width - margin
    guard margin <= maxLeft else { return max((span - width) / 2, 0) }
    return min(max(left, margin), maxLeft)
}

/// Top-anchored clamp; taller-than-board panels pin to the top margin.
private func clampPanelTop(_ top: CGFloat, height: CGFloat, span: CGFloat, margin: CGFloat) -> CGFloat {
    let maxTop = max(span - height - margin, margin)
    return min(max(top, margin), maxTop)
}

/// Above widget → below → tuck inside top edge as last resort.
private struct ControlBarPlacement: ViewModifier {
    let anchorRect: CGRect
    let boardSize: CGSize
    let estimatedSize: CGSize
    /// Gaps are drawn through the same shrink the chrome undoes, so they are
    /// grown with it — otherwise the bar ends up a screen point off its tile.
    let boost: CGFloat
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let size = measured ?? estimatedSize
        let margin: CGFloat = 6 * boost
        let gap: CGFloat = 8 * boost
        var top = anchorRect.minY - size.height - gap
        if top < margin {
            let below = anchorRect.maxY + gap
            top = (below + size.height <= boardSize.height - margin) ? below : anchorRect.minY + gap
        }
        let left = clampPanelLeft(anchorRect.midX - size.width / 2, width: size.width, span: boardSize.width, margin: margin)
        return content
            .modifier(MonitorPanelSizeReader(size: $measured))
            .offset(x: left, y: clampPanelTop(top, height: size.height, span: boardSize.height, margin: margin))
    }
}

/// Prefer right of widget; flip left on overflow.
private struct SettingsCardPlacement: ViewModifier {
    let anchorRect: CGRect
    let boardSize: CGSize
    let boost: CGFloat
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let size = measured ?? CGSize(
            width: MonitorWidgetSettingsCard.cardWidth * boost, height: 340 * boost
        )
        let margin: CGFloat = 8 * boost
        let gap: CGFloat = 8 * boost
        var left = anchorRect.maxX + gap
        if left + size.width > boardSize.width - margin {
            let toLeft = anchorRect.minX - gap - size.width
            left = toLeft >= margin ? toLeft : boardSize.width - size.width - margin
        }
        left = clampPanelLeft(left, width: size.width, span: boardSize.width, margin: margin)
        let top = clampPanelTop(anchorRect.minY, height: size.height, span: boardSize.height, margin: margin)
        return content
            .modifier(MonitorPanelSizeReader(size: $measured))
            .offset(x: left, y: top)
    }
}

/// ~8pt below Add Widget, centred on it.
private struct CatalogBelowPlacement: ViewModifier {
    let anchorFrame: CGRect
    let boardSize: CGSize
    let panelWidth: CGFloat
    let estimatedHeight: CGFloat
    let boost: CGFloat
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let height = measured?.height ?? estimatedHeight
        let margin: CGFloat = 8 * boost
        let left = clampPanelLeft(anchorFrame.midX - panelWidth / 2, width: panelWidth, span: boardSize.width, margin: margin)
        let top = clampPanelTop(anchorFrame.maxY + 8 * boost, height: height, span: boardSize.height, margin: margin)
        return content
            .modifier(MonitorPanelSizeReader(size: $measured))
            .offset(x: left, y: top)
    }
}
