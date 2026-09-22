import LiveWallpaperCore
import SwiftUI

/// Middle section of the overlay column: the controls of whatever the navigator or the canvas
/// has selected. Each object type reuses the section the old detail page already renders.
struct ObjectInspector: View {
    let session: OverlayEditorSession
    let screen: Screen?
    let screenManager: ScreenManager
    let placements: [MonitorWidgetPlacement]
    let backdropAvailable: Bool
    let height: CGFloat
    var width: CGFloat = DetailGeometry.inspectorWidth

    /// `OverlaysInspectorPanel` edits a draft in place; the session's copy is read-only here, so
    /// the panel gets a local mirror that is reseeded whenever the applied configuration changes.
    @State private var draft = DraftState.default

    private var content: OverlayInspectorContent {
        OverlayLayerList.inspectorContent(for: session.selection)
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
        .onAppear { draft = session.draft }
        .onChange(of: session.draft) { draft = session.draft }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(verbatim: title)
                    .font(DesignTokens.EditDesk.Typography.stageTitle)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                if let meta {
                    Text(verbatim: meta)
                        .font(DesignTokens.EditDesk.Typography.badgeMono)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if content == .effect {
                headerToggle
            }
        }
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
        .padding(.vertical, DesignTokens.EditDesk.Spacing.s8)
    }

    @ViewBuilder
    private var headerToggle: some View {
        switch content {
        case .music:
            toggle(isOn: session.overlay.music.enabled, set: session.setMusicEnabled)
        case .clock:
            toggle(isOn: session.overlay.clock.enabled, set: session.setClockEnabled)
        case .effect:
            toggle(isOn: session.effectVisible, set: session.setEffectVisible)
                .disabled(!session.canEditEffect)
        case .widget, .empty:
            EmptyView()
        }
    }

    private func toggle(isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text(verbatim: title))
    }

    private var title: String {
        switch content {
        case let .widget(id):
            placements.first { $0.id == id }.map { WidgetFactory.displayName($0.kind) }
                ?? String(localized: "No Selection", bundle: .appLanguage)
        case .music: String(localized: "Music", bundle: .appLanguage)
        case .clock: String(localized: "Clock", bundle: .appLanguage)
        case .effect: String(localized: "Effect Layer", bundle: .appLanguage)
        case .empty: String(localized: "No Selection", bundle: .appLanguage)
        }
    }

    private var meta: String? {
        let kind: String? = switch content {
        case .widget: String(localized: "Widget", bundle: .appLanguage)
        case .music: String(localized: "Music", bundle: .appLanguage)
        case .clock: String(localized: "Clock", bundle: .appLanguage)
        case .effect: String(localized: "Effect", bundle: .appLanguage)
        case .empty: nil
        }
        guard let kind else { return nil }
        return "\(String(localized: "Selected", bundle: .appLanguage)) · \(kind)"
    }

    // MARK: Content

    @ViewBuilder
    private func editor(for content: OverlayInspectorContent) -> some View {
        switch content {
        case let .widget(id):
            if let placement = placements.first(where: { $0.id == id }) {
                scrolling {
                    WidgetSettingsPopover(
                        placement: placement,
                        onUpdate: { session.interaction.updateWidget($0) },
                        onRemove: { session.removeWidget(id: id) },
                        embedded: true
                    )
                }
            } else {
                emptyState
            }
        case .music:
            if let screen {
                scrolling {
                    MusicOverlaySection(screen: screen, screenManager: screenManager, backdropAvailable: backdropAvailable, showsVisibilityControl: false)
                }
            }
        case .clock:
            if let screen {
                scrolling {
                    ClockOverlaySection(screen: screen, screenManager: screenManager, backdropAvailable: backdropAvailable, showsVisibilityControl: false)
                }
            }
        case .effect:
            if let screen {
                effectPanel(screen)
            }
        case .empty:
            emptyState
        }
    }

    private func scrolling(@ViewBuilder _ builder: () -> some View) -> some View {
        ScrollView {
            builder()
                .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
                .padding(.bottom, DesignTokens.EditDesk.Spacing.s12)
        }
    }

    /// `OverlaysInspectorPanel` brings its own `ScrollView`, so this case is not wrapped again.
    private func effectPanel(_ screen: Screen) -> some View {
        OverlaysInspectorPanel(
            screen: screen,
            draft: $draft,
            screenManager: screenManager,
            kind: .weather,
            inspectorPanelWidth: width,
            backdropAvailable: backdropAvailable,
            onParticleEffectChange: { effect in write { screenManager.updateParticleEffect(effect, for: screen) } },
            onParticleDensityChange: { density in write { screenManager.updateParticleDensity(density, for: screen) } },
            onWeatherReactiveChange: { on in write { screenManager.setWeatherReactive(on, for: screen) } },
            onWeatherWindChange: { on in write { screenManager.setWeatherWind(on, for: screen) } },
            onWeatherIntensityChange: { on in write { screenManager.setWeatherIntensity(on, for: screen) } }
        )
    }

    /// The layer row reads the session's own copy of the applied configuration, which only the
    /// session can refresh; without this the row's switch lags the panel by one edit.
    private func write(_ apply: () -> Void) {
        apply()
        session.refreshAppliedConfiguration()
    }

    private var emptyState: some View {
        Text("No Selection")
            .font(DesignTokens.EditDesk.Typography.body)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
