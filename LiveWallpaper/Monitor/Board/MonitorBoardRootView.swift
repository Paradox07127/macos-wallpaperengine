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

struct MonitorBoardRootView: View {
    @ObservedObject var model: MonitorBoardInteractionModel
    @ObservedObject var data: MonitorBoardDataModel
    /// History is @Published inside the data model — observe it so tiles re-render on sample.
    @ObservedObject private var history: MonitorHistoryStore
    @Environment(\.monitorReduceMotion) private var reduceMotion
    @Environment(\.monitorSuspended) private var suspended
    @FocusState private var boardFocused: Bool

    @State private var addButtonFrame: CGRect = .zero
    private let nameOnlyTiles: Bool

    init(model: MonitorBoardInteractionModel, data: MonitorBoardDataModel, nameOnlyTiles: Bool = false) {
        self.model = model
        self.data = data
        self.history = data.historyStore
        self.nameOnlyTiles = nameOnlyTiles
    }

    var body: some View {
        TimelineView(MonitorBoardClock(suspended: suspended)) { timeline in
            boardContent(now: timeline.date)
        }
        .background(Color.clear)
        .focusable(model.isEditing)
        .focused($boardFocused)
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
                referenceWidth: model.referenceWidth,
                topInsetFraction: model.topInsetFraction
            )

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .modifier(EmptyTapModifier(model: model))

                if !geometry.isDegenerate {
                    if model.placements.isEmpty {
                        emptyBoardHint(boardSize: boardSize)
                    }

                    if model.isEditing, let drag = model.drag {
                        guideLayer(drag: drag, geometry: geometry)
                        ghostFrame(drag: drag, geometry: geometry)
                    }

                    ForEach(model.placements) { placement in
                        widgetTile(placement, geometry: geometry, boardSize: boardSize, now: now)
                    }

                    if model.isEditing {
                        editControls(geometry: geometry, boardSize: boardSize)
                    }
                }
            }
            .frame(width: boardSize.width, height: boardSize.height, alignment: .topLeading)
            .coordinateSpace(name: MonitorBoardCoordinateSpace.name)
            .onPreferenceChange(MonitorAddButtonFrameKey.self) { addButtonFrame = $0 }
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
                .font(.system(size: 12, weight: .medium, design: .rounded))
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
        boardSize: CGSize,
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
        if nameOnlyTiles {
            MonitorWidgetNameTile(kind: placement.kind, cellHeight: renderHeight, cornerRadius: cornerRadius)
        } else {
            MonitorWidgetFactory.tile(
                context: MonitorWidgetContext(
                    snapshot: data.snapshot,
                    history: history.current,
                    placement: placement,
                    isEditing: model.isEditing,
                    reduceMotion: reduceMotion,
                    now: now
                ),
                cornerRadius: cornerRadius
            )
        }
    }

    private func rawRect(_ placement: MonitorWidgetPlacement, geometry: MonitorBoardGeometry) -> CGRect {
        let origin = MonitorBoardLayoutEngine.pixelOrigin(
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
        if let ghostOrigin = drag.ghostOrigin {
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
        let seg = MonitorBoardLayoutEngine.guideSegment(guide, draggedRect: draggedRect, geometry: geometry)
        Path { path in
            path.move(to: seg.start)
            path.addLine(to: seg.end)
        }
        .stroke(DesignTokens.Colors.boardEditAccent.opacity(0.55), lineWidth: 1)
    }

    // MARK: Edit controls (floating per-widget + catalog)

    @ViewBuilder
    private func editControls(geometry: MonitorBoardGeometry, boardSize: CGSize) -> some View {
        MonitorBoardEditToolbar(model: model)
            .padding(.top, toolbarTopInset(boardHeight: boardSize.height))
            .frame(width: boardSize.width, height: boardSize.height, alignment: .top)
            .zIndex(70)

        if let selectedID = model.selectedID,
           let placement = model.placements.first(where: { $0.id == selectedID }),
           model.drag == nil {
            let render = geometry.renderRect(forRawRect: rawRect(placement, geometry: geometry))
            MonitorWidgetControlBar(model: model, placement: placement)
                .fixedSize()
                .modifier(ControlBarPlacement(
                    anchorRect: render,
                    boardSize: boardSize,
                    estimatedSize: Self.controlBarEstimate(for: placement.kind)
                ))
                .zIndex(60)
        }

        if let settingsID = model.settingsOpenID,
           let placement = model.placements.first(where: { $0.id == settingsID }),
           model.drag == nil {
            let render = geometry.renderRect(forRawRect: rawRect(placement, geometry: geometry))
            MonitorWidgetSettingsCard(model: model, placement: placement, maxHeight: boardSize.height - 16)
                .modifier(SettingsCardPlacement(anchorRect: render, boardSize: boardSize))
                .zIndex(80)
        }

        if model.isCatalogOpen {
            let catalogWidth = min(760, boardSize.width * 0.86)
            let anchor = catalogAnchorFrame(boardSize: boardSize)
            let scrollCap = catalogScrollCap(anchorMaxY: anchor.maxY, boardHeight: boardSize.height)
            MonitorCatalogView(model: model, maxScrollHeight: scrollCap)
                .frame(width: catalogWidth)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(CatalogBelowPlacement(
                    anchorFrame: anchor,
                    boardSize: boardSize,
                    panelWidth: catalogWidth,
                    estimatedHeight: scrollCap + 64
                ))
                .zIndex(75)
        }
    }

    /// Pre-measure estimate: gear+trash (~68) + ~30pt per size segment.
    private static func controlBarEstimate(for kind: MonitorWidgetKind) -> CGSize {
        let count = kind.allowedSizes.count
        return CGSize(width: 68 + (count > 1 ? CGFloat(count) * 30 + 16 : 0), height: 36)
    }

    /// ≤55% board height; 64pt reserves catalog header + padding above the bottom margin.
    private func catalogScrollCap(anchorMaxY: CGFloat, boardHeight: CGFloat) -> CGFloat {
        max(min(boardHeight * 0.55, boardHeight - anchorMaxY - 16 - 64), 80)
    }

    private func toolbarTopInset(boardHeight: CGFloat) -> CGFloat {
        boardHeight >= 500 ? min(max(boardHeight * 0.035, 44), 60) : boardHeight * 0.055
    }

    /// Prefer Add Widget frame; else top-centre under the toolbar.
    private func catalogAnchorFrame(boardSize: CGSize) -> CGRect {
        if addButtonFrame != .zero { return addButtonFrame }
        let inset = toolbarTopInset(boardHeight: boardSize.height)
        return CGRect(x: boardSize.width / 2 - 40, y: inset, width: 80, height: 30)
    }
}

// MARK: - Empty-space tap

private struct EmptyTapModifier: ViewModifier {
    @ObservedObject var model: MonitorBoardInteractionModel

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
            .scaleEffect(isEditing && hovering && !isDragging ? 1.0 : 1.0)
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
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let size = measured ?? estimatedSize
        let margin: CGFloat = 6
        let gap: CGFloat = 8
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
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let size = measured ?? CGSize(width: MonitorWidgetSettingsCard.cardWidth, height: 340)
        let margin: CGFloat = 8
        let gap: CGFloat = 8
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
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let height = measured?.height ?? estimatedHeight
        let margin: CGFloat = 8
        let left = clampPanelLeft(anchorFrame.midX - panelWidth / 2, width: panelWidth, span: boardSize.width, margin: margin)
        let top = clampPanelTop(anchorFrame.maxY + 8, height: height, span: boardSize.height, margin: margin)
        return content
            .modifier(MonitorPanelSizeReader(size: $measured))
            .offset(x: left, y: top)
    }
}
