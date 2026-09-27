import LiveWallpaperCore
import SwiftUI

/// Rows of the overlay workspace's floating Layers panel: every object on this display, board order first.
struct LayerNavigator: View {
    let session: OverlayEditorSession
    let rows: [OverlayLayerRow]
    let height: CGFloat
    /// Copies one top-level layer's kind to the other displays, given the row's name; nil offers no copy.
    var copyLayer: ((OverlayKind, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        OverlayLayerRowView(session: session, row: row, copyLayer: copyLayer)
                    }
                }
                .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
            }
        }
        .frame(height: height, alignment: .top)
        .clipped()
    }
}

private struct OverlayLayerRowView: View {
    let session: OverlayEditorSession
    let row: OverlayLayerRow
    let copyLayer: ((OverlayKind, String) -> Void)?
    @Environment(ScreenManager.self) private var screenManager
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            Button {
                session.select(row.selection)
                session.requestInspector()
            } label: {
                HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(verbatim: name)
                        .font(DesignTokens.EditDesk.Typography.body)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(session.selection == row.selection ? .isSelected : [])
            if hasSettings {
                GlassIconButton("gearshape", size: .small) {
                    session.select(row.selection)
                    session.requestInspector()
                }
                .help(Text("Settings"))
                .accessibilityLabel(Text("Settings"))
            }
            if case let .widget(id) = row.selection {
                WidgetShownToggle(interaction: session.interaction, id: id, name: name)
            }
            action
        }
        .padding(.leading, indent)
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
        .frame(height: OverlayWorkspaceLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.shelfCard, style: .continuous)
                .fill(fill)
        )
        .onHover { hovered = $0 }
        .contextMenu {
            if let copyLayer, let kind = copiedKind {
                Button("Copy to Other Displays") { copyLayer(kind, name) }
                    .disabled(screenManager.screens.count < 2)
            }
        }
    }

    /// nil for a single widget: the copy moves the whole board.
    private var copiedKind: OverlayKind? {
        switch row.kind {
        case .board: .monitor
        case .clock: .clock
        case .music: .music
        case .widget: nil
        }
    }

    @ViewBuilder
    private var action: some View {
        switch row.action {
        case .remove:
            Button {
                if case let .widget(id) = row.selection {
                    session.removeWidget(id: id)
                }
            } label: {
                Image(systemName: "minus.circle")
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.danger)
            }
            .buttonStyle(.borderless)
            .help(Text("Remove"))
            .accessibilityLabel(Text("Remove"))
            .accessibilityValue(Text(verbatim: name))
        case let .toggle(isOn):
            Toggle("", isOn: Binding(get: { isOn }, set: setEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(Text(verbatim: name))
        }
    }

    private var hasSettings: Bool {
        switch row.kind {
        case .board, .clock, .music: true
        case .widget: false
        }
    }

    private func setEnabled(_ isOn: Bool) {
        switch row.kind {
        case .board: session.setBoardEnabled(isOn)
        case .clock: session.setClockEnabled(isOn)
        case .music: session.setMusicEnabled(isOn)
        case .widget: break
        }
    }

    private var fill: Color {
        if session.selection == row.selection {
            DesignTokens.EditDesk.Colors.fillSelectedChip
        } else if hovered {
            DesignTokens.EditDesk.Colors.fillNavPill
        } else {
            .clear
        }
    }

    private var indent: CGFloat {
        if case .widget = row.kind {
            DesignTokens.EditDesk.Spacing.s12
        } else {
            0
        }
    }

    private var name: String {
        switch row.kind {
        case .board: String(localized: "Widgets", bundle: .appLanguage)
        case let .widget(kind): WidgetFactory.displayName(kind)
        case .clock: String(localized: "Clock", bundle: .appLanguage)
        case .music: String(localized: "Music", bundle: .appLanguage)
        }
    }

    private var dotColor: Color {
        switch row.kind {
        case .board, .widget: DesignTokens.EditDesk.Colors.sceneGroupLayers
        case .clock: DesignTokens.EditDesk.Colors.sceneGroupColors
        case .music: DesignTokens.EditDesk.Colors.success
        }
    }
}

/// Observes the board itself: the row's own inputs do not change when a widget is hidden.
private struct WidgetShownToggle: View {
    @ObservedObject var interaction: InteractionModel
    let id: UUID
    let name: String

    var body: some View {
        Toggle("", isOn: Binding(
            get: { interaction.placements.first { $0.id == id }?.isHidden == false },
            set: { interaction.setHidden(id, to: !$0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityLabel(Text(verbatim: name))
    }
}
