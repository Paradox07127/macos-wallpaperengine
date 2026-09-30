import LiveWallpaperCore
import SwiftUI

/// The effect layer's floating panel in the overlay workspace's top strip: a title row with the effect's switch,
/// and while open the effect's settings, hanging down over the canvas.
struct OverlayEffectPanel: View {
    let session: OverlayEditorSession
    let screen: Screen
    /// The canvas column's height; the settings scroll inside what is left under the title row.
    let availableHeight: CGFloat
    /// Copies one top-level layer's kind to the other displays, given its name; nil offers no copy.
    var copyLayer: ((OverlayKind, String) -> Void)?

    static let width: CGFloat = 300

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    /// `OverlaysInspectorPanel` edits a draft in place; the session's copy is read-only here, so
    /// the panel gets a local mirror that is reseeded whenever the applied configuration changes.
    @State private var draft = DraftState.default

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            if expanded {
                Divider().padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
                settings
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.lg))
        .onAppear { draft = session.draft }
        .onChange(of: session.draft) { draft = session.draft }
    }

    private var titleRow: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            Button(action: toggleExpanded) {
                HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                    Image(systemName: "sparkles")
                    Text("Effect Layer")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Effect Layer"))
            .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))
            effectSwitch
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .font(DesignTokens.EditDesk.Typography.body)
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
        .frame(height: OverlayWorkspaceLayout.panelTitleHeight)
        .contextMenu {
            if let copyLayer {
                Button("Copy to Other Displays") { copyLayer(.weather, String(localized: "Effect Layer", bundle: .appLanguage)) }
                    .disabled(screenManager.screens.count < 2 || !session.canEditEffect)
            }
        }
    }

    @ViewBuilder
    private var effectSwitch: some View {
        let toggle = Toggle("", isOn: Binding(get: { session.effectVisible }, set: { session.setEffectVisible($0) }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!session.canEditEffect)
            .accessibilityLabel(Text("Effect Layer"))
        // A help tag on an always-present control reads as advice; here it only explains why the switch is dead.
        if session.canEditEffect {
            toggle
        } else {
            toggle.help(Text("Apply a wallpaper to enable effects"))
        }
    }

    private var settings: some View {
        OverlaysInspectorPanel(
            screen: screen,
            draft: $draft,
            screenManager: screenManager,
            inspectorPanelWidth: Self.width,
            onParticleEffectChange: { effect in write { screenManager.updateParticleEffect(effect, for: screen) } },
            onParticleDensityChange: { density in write { screenManager.updateParticleDensity(density, for: screen) } },
            onWeatherReactiveChange: { on in write { screenManager.setWeatherReactive(on, for: screen) } },
            onWeatherWindChange: { on in write { screenManager.setWeatherWind(on, for: screen) } },
            onWeatherIntensityChange: { on in write { screenManager.setWeatherIntensity(on, for: screen) } }
        )
        // Hugs the settings until they outgrow the column under the strip, then scrolls.
        .frame(maxHeight: max(0, availableHeight - OverlayWorkspaceLayout.topBarHeight - OverlayGeometry.canvasInset))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The title row's switch reads the session's own copy of the applied configuration, which only the
    /// session can refresh; without this the switch lags the settings by one edit.
    private func write(_ apply: () -> Void) {
        apply()
        session.refreshAppliedConfiguration()
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22)) {
            expanded.toggle()
        }
    }
}
