import LiveWallpaperCore
import SwiftUI

/// Rows of the overlay workspace's floating Layers panel: every object on this display, board order first.
struct LayerNavigator: View {
    let session: OverlayEditorSession
    let rows: [OverlayLayerRow]
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        OverlayLayerRowView(session: session, row: row)
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
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            Button {
                session.select(row.selection)
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
            action
        }
        .padding(.leading, indent)
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
        .frame(height: OverlayColumnLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.shelfCard, style: .continuous)
                .fill(fill)
        )
        .onHover { hovered = $0 }
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
                .disabled(isEffect && !session.canEditEffect)
                .accessibilityLabel(Text(verbatim: name))
                .modifier(EffectHint(shown: isEffect && !session.canEditEffect))
        }
    }

    private var isEffect: Bool {
        row.kind == .effect
    }

    private func setEnabled(_ isOn: Bool) {
        switch row.kind {
        case .board: session.setBoardEnabled(isOn)
        case .clock: session.setClockEnabled(isOn)
        case .music: session.setMusicEnabled(isOn)
        case .effect: session.setEffectVisible(isOn)
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
        case .effect: String(localized: "Effect Layer", bundle: .appLanguage)
        }
    }

    private var dotColor: Color {
        switch row.kind {
        case .board, .widget: DesignTokens.EditDesk.Colors.sceneGroupLayers
        case .clock: DesignTokens.EditDesk.Colors.sceneGroupColors
        case .music: DesignTokens.EditDesk.Colors.success
        case .effect: DesignTokens.EditDesk.Colors.sceneGroupEffects
        }
    }
}

/// A help tag on an always-present control reads as advice; here it only explains why the
/// switch is dead, so it is attached only while it is.
private struct EffectHint: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        if shown {
            content.help(Text("Apply a wallpaper to enable effects"))
        } else {
            content
        }
    }
}
