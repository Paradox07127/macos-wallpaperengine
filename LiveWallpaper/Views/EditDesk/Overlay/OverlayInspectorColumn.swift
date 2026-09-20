import LiveWallpaperCore
import SwiftUI

/// The 372pt overlay column: layers on top, the selected object's controls in the middle, the
/// add drawer resident at the bottom. Alignment snapping and copy-to-other-displays live in the
/// detail top bar, not here.
struct OverlayInspectorColumn: View {
    let session: OverlayEditorSession
    let backdropAvailable: Bool
    @ObservedObject private var interaction: InteractionModel
    @Environment(ScreenManager.self) private var screenManager
    @State private var drawerExpanded = false

    init(session: OverlayEditorSession, backdropAvailable: Bool = false) {
        self.session = session
        self.backdropAvailable = backdropAvailable
        interaction = session.interaction
    }

    var body: some View {
        GeometryReader { proxy in
            let rows = OverlayLayerList.rows(
                placements: interaction.placements,
                clockEnabled: session.overlay.clock.enabled,
                musicEnabled: session.overlay.music.enabled,
                effectVisible: session.effectVisible
            )
            let heights = OverlayColumnLayout.heights(
                total: proxy.size.height, rowCount: rows.count, drawerExpanded: drawerExpanded
            )
            VStack(spacing: 0) {
                LayerNavigator(session: session, rows: rows, height: heights.layers)
                ObjectInspector(
                    session: session, screen: screen, screenManager: screenManager,
                    placements: interaction.placements, backdropAvailable: backdropAvailable,
                    height: heights.inspector
                )
                .overlay(alignment: .top) { rule }
                AddOverlayDrawer(session: session, isExpanded: $drawerExpanded, height: heights.drawer)
                    .overlay(alignment: .top) { rule }
            }
        }
    }

    /// Drawn as an overlay, not a `Divider`: the three heights already add up to the column and a
    /// laid-out separator would push the drawer past the bottom edge.
    private var rule: some View {
        DesignTokens.EditDesk.Colors.strokePanel.frame(height: 1)
    }

    private var screen: Screen? {
        guard let identity = session.identity else { return nil }
        return screenManager.screens.first {
            $0.id == identity.displayID && $0.displayFingerprint == identity.fingerprint
        }
    }
}
