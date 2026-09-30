import LiveWallpaperCore
import SwiftUI

/// Inspector pane of the overlay workspace: the selected object's controls, reusing the old detail page's sections.
struct ObjectInspector: View {
    let session: OverlayEditorSession
    let screen: Screen?
    let screenManager: ScreenManager
    let placements: [MonitorWidgetPlacement]
    let height: CGFloat
    var width: CGFloat = DetailGeometry.inspectorWidth

    static let headerHeight: CGFloat = 44

    private var content: OverlayInspectorContent {
        OverlayLayerList.inspectorContent(for: session.selection)
    }

    /// The wallpaper inspector's inset, so both columns start their groups on the same edge.
    private var padding: CGFloat {
        DesignTokens.Inspector.horizontalPadding(for: width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if content != .empty {
                header
            }
            editor(for: content)
        }
        .frame(height: height, alignment: .top)
        .clipped()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(verbatim: title)
                .font(DesignTokens.Typography.sectionTitle)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if case let .widget(id) = content {
                Button(role: .destructive) {
                    session.removeWidget(id: id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DesignTokens.Colors.Status.danger)
            }
        }
        .padding(.horizontal, padding)
        .frame(height: Self.headerHeight)
    }

    private var title: String {
        switch content {
        case .board: String(localized: "Widgets", bundle: .appLanguage)
        case let .widget(id):
            placements.first { $0.id == id }.map { WidgetFactory.displayName($0.kind) }
                ?? String(localized: "No Selection", bundle: .appLanguage)
        case .music: String(localized: "Music", bundle: .appLanguage)
        case .clock: String(localized: "Clock", bundle: .appLanguage)
        case .empty: String(localized: "No Selection", bundle: .appLanguage)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func editor(for content: OverlayInspectorContent) -> some View {
        switch content {
        case .board:
            if let screen {
                scrolling {
                    MonitorOverlaySection(screen: screen, screenManager: screenManager, editBoard: session.editBoard)
                }
            }
        case let .widget(id):
            if let placement = placements.first(where: { $0.id == id }) {
                scrolling {
                    VStack(spacing: DesignTokens.Spacing.md) {
                        if placement.kind == .fleet {
                            AgentFolderAccessSection()
                        }
                        WidgetSettingsPopover(
                            placement: placement,
                            onUpdate: { session.interaction.updateWidget($0) },
                            onRemove: { session.removeWidget(id: id) },
                            embedded: true
                        )
                    }
                }
            } else {
                emptyState
            }
        case .music:
            if let screen {
                scrolling {
                    MusicOverlaySection(screen: screen, screenManager: screenManager)
                }
            }
        case .clock:
            if let screen {
                scrolling {
                    ClockOverlaySection(screen: screen, screenManager: screenManager)
                }
            }
        case .empty:
            emptyState
        }
    }

    /// Same insets as `OverlaysInspectorPanel`'s own scroll view.
    private func scrolling(@ViewBuilder _ builder: () -> some View) -> some View {
        ScrollView {
            builder()
                .padding(.horizontal, padding)
                .padding(.vertical, DesignTokens.Spacing.md)
        }
    }

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "cursorarrow",
            title: "No Selection",
            variant: .compact
        )
    }
}
