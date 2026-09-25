import LiveWallpaperCore
import SwiftUI

/// A tile drag as the workspace sees it. Points are in `OverlayWorkspace.dragSpace`.
enum OverlayAddDragPhase: Equatable {
    case began(OverlayAddItem, CGPoint)
    case moved(CGPoint)
    case ended(CGPoint)
}

/// Bottom strip of the overlay workspace. Collapsed it is one row; expanded it lays every object this
/// display can carry out in two rows. A click adds at the board's first free slot, a drag where it is released.
struct AddOverlayDrawer: View {
    let session: OverlayEditorSession
    @Binding var isExpanded: Bool
    let height: CGFloat
    let onDrag: (OverlayAddDragPhase) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var interaction: InteractionModel
    @State private var boardFull = false
    @State private var draggedItem: OverlayAddItem?

    static let tileHeight: CGFloat = 46
    private static let gap = DesignTokens.EditDesk.Spacing.s8
    private static let side = DesignTokens.EditDesk.Spacing.s12
    /// Above the header row and between it and the tiles.
    private static let rim = DesignTokens.Spacing.xs
    static let collapsedHeight = rim + OverlayColumnLayout.drawerCollapsedHeight + rim
    static let expandedHeight = collapsedHeight + 2 * tileHeight + gap + side
    /// The modal preview's threshold, so a click that wobbles a little stays a click.
    private static let dragThreshold: CGFloat = 6

    static func columns(for count: Int) -> Int {
        max(1, (count + 1) / 2)
    }

    /// `containerWidth` is the whole strip, side insets included.
    static func tileWidth(containerWidth: CGFloat, count: Int) -> CGFloat {
        let columns = CGFloat(columns(for: count))
        return max(0, (containerWidth - 2 * side - (columns - 1) * gap) / columns)
    }

    init(session: OverlayEditorSession, isExpanded: Binding<Bool>, height: CGFloat,
         onDrag: @escaping (OverlayAddDragPhase) -> Void) {
        self.session = session
        _isExpanded = isExpanded
        self.height = height
        self.onDrag = onDrag
        interaction = session.interaction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rim) {
            header
            if isExpanded {
                grid
            }
        }
        .padding(.top, Self.rim)
        .padding(.horizontal, Self.side)
        .frame(height: height, alignment: .top)
        .clipped()
        .onChange(of: interaction.placements) { boardFull = false }
        .onChange(of: session.identity) { boardFull = false }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                Text(verbatim: "\(isExpanded ? "−" : "+") \(String(localized: "Add Overlay", bundle: .appLanguage))")
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                    .lineLimit(1)
                    .frame(height: OverlayColumnLayout.drawerCollapsedHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Add Overlay"))
            if let warning {
                Text(warning)
                    .font(DesignTokens.EditDesk.Typography.footnote)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.warning)
                    .lineLimit(2)
            } else if isExpanded {
                Text("Drag onto the canvas to place it, or click to add it to a free spot.")
                    .font(DesignTokens.EditDesk.Typography.footnote)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var warning: LocalizedStringKey? {
        if case .noRoom? = session.addDrop {
            return "No room here. Release over a free spot."
        }
        if session.addDropRejected {
            return "No room here. Release over a free spot."
        }
        return boardFull ? "No room for another widget. Remove a widget or make one smaller, then try again." : nil
    }

    private var grid: some View {
        let items = OverlayLayerList.addItems
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: Self.columns(for: items.count)),
            spacing: Self.gap
        ) {
            ForEach(items) { item in
                tile(item)
            }
        }
    }

    private func tile(_ item: OverlayAddItem) -> some View {
        let enabled = item != .effect || session.canEditEffect
        let onCanvas = OverlayLayerList.isOnCanvas(
            item, musicEnabled: session.overlay.music.enabled, clockEnabled: session.overlay.clock.enabled,
            effectVisible: session.effectVisible
        )
        return Button { add(item) } label: {
            AddOverlayTileFace(item: item, onCanvas: onCanvas)
                .frame(maxWidth: .infinity)
                .frame(height: Self.tileHeight)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // High priority: a drag that ends back on the tile must not also count as a click.
        .highPriorityGesture(dragGesture(item), including: enabled ? .all : .subviews)
        .accessibilityLabel(Text(verbatim: AddOverlayTileFace.name(item)))
        .accessibilityValue(onCanvas ? Text("On Canvas") : Text(verbatim: ""))
    }

    private func dragGesture(_ item: OverlayAddItem) -> some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(OverlayWorkspace.dragSpace))
            .onChanged { value in
                if draggedItem == item {
                    onDrag(.moved(value.location))
                } else {
                    draggedItem = item
                    onDrag(.began(item, value.location))
                }
            }
            .onEnded { value in
                draggedItem = nil
                onDrag(.ended(value.location))
            }
    }

    private func add(_ item: OverlayAddItem) {
        switch item {
        case let .widget(kind):
            boardFull = !session.addWidget(kind: kind)
        case .music:
            session.addSingleton(.music)
        case .clock:
            session.addSingleton(.clock)
        case .effect:
            session.setEffectVisible(true)
            session.select(.effect)
        }
    }
}

/// A tile's face, shared by the strip and the drag ghost.
struct AddOverlayTileFace: View {
    let item: OverlayAddItem
    let onCanvas: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard, style: .continuous)
        VStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: Self.icon(item))
                .font(DesignTokens.EditDesk.Typography.stageTitle)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
            Text(verbatim: Self.name(item))
                .font(DesignTokens.EditDesk.Typography.footnote)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(DesignTokens.EditDesk.Colors.fillShell))
        .overlay(shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if onCanvas {
                Image(systemName: "checkmark.circle.fill")
                    .font(DesignTokens.EditDesk.Typography.footnote)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.success)
                    .padding(DesignTokens.Spacing.xs)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    static func name(_ item: OverlayAddItem) -> String {
        switch item {
        case let .widget(kind): WidgetFactory.displayName(kind)
        case .music: String(localized: "Music", bundle: .appLanguage)
        case .clock: String(localized: "Clock", bundle: .appLanguage)
        case .effect: String(localized: "Effect Layer", bundle: .appLanguage)
        }
    }

    static func icon(_ item: OverlayAddItem) -> String {
        switch item {
        case let .widget(kind): WidgetFactory.icon(kind)
        case .music: "music.note"
        case .clock: "clock"
        case .effect: "sparkles"
        }
    }
}
