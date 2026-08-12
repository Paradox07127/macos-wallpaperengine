import AppKit
import LiveWallpaperCore
import SwiftUI

/// One overlay page's controls. Weather and Monitor are separate pages picked in
/// the toolbar, so neither is wrapped in a collapsible named after itself — the
/// page title already says which one you're looking at.
struct OverlaysInspectorPanel: View {
    let screen: Screen
    @Binding var draft: ScreenDetailDraftState
    let screenManager: ScreenManager
    let kind: OverlayKind
    let inspectorPanelWidth: CGFloat
    /// Whether a still frame of the current wallpaper exists to sit behind the board.
    let backdropAvailable: Bool
    let onParticleEffectChange: (ParticleEffect) -> Void
    let onParticleDensityChange: (Double) -> Void
    let onWeatherReactiveChange: (Bool) -> Void

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 12) {
                VStack(spacing: 12) {
                    switch kind {
                    case .weather:
                        weatherCard
                    case .monitor:
                        MonitorOverlaySection(
                            screen: screen,
                            screenManager: screenManager,
                            backdropAvailable: backdropAvailable
                        )
                    }
                }
                .padding(.horizontal, DesignTokens.Inspector.horizontalPadding(for: inspectorPanelWidth))
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Weather / particles

    private var weatherCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                // Leads with the on/off switch so this card and the Monitor
                // page's first card read as siblings — Monitor's own first row
                // is "Show on This Display".
                weatherEnabledRow

                if draft.selectedParticleEffect != .none {
                    particleEffectRow
                    particleDensityRow
                }

                Divider()

                weatherReactiveRow

                if draft.effectConfig.weatherReactive {
                    WeatherStatusBadge(
                        weatherService: screenManager.weatherService,
                        refresh: screenManager.weatherService.refresh
                    )
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var weatherEnabledRow: some View {
        SettingRow(
            icon: isWeatherOn ? "cloud.sun.rain.fill" : "cloud.sun",
            iconColor: isWeatherOn ? DesignTokens.Colors.Status.active : .secondary,
            title: "Show on This Display",
            info: "Particles are drawn over whatever wallpaper this display is playing"
        ) {
            Toggle("", isOn: weatherEnabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Weather overlay"))
        }
    }

    private var isWeatherOn: Bool { draft.selectedParticleEffect != .none }

    /// The model stores the effect as an 8-case enum, so a blunt on/off switch
    /// would otherwise forget the choice. Remembered per display, because the
    /// effect itself is per display — one global slot let one screen's last
    /// effect come back on another. App-scoped store so tests do not write here.
    private var weatherEnabledBinding: Binding<Bool> {
        Binding(
            get: { isWeatherOn },
            set: { isOn in
                let next: ParticleEffect
                if isOn {
                    next = rememberedParticleEffect
                } else {
                    rememberParticleEffect(draft.selectedParticleEffect)
                    next = .none
                }
                draft.selectedParticleEffect = next
                onParticleEffectChange(next)
            }
        )
    }

    private var rememberedEffectKey: String {
        "Overlay.LastParticleEffect.\(screen.displayFingerprint)"
    }

    private func rememberParticleEffect(_ effect: ParticleEffect) {
        guard effect != .none else { return }
        UserDefaults.appScoped().set(effect.rawValue, forKey: rememberedEffectKey)
    }

    private var rememberedParticleEffect: ParticleEffect {
        let raw = UserDefaults.appScoped().string(forKey: rememberedEffectKey)
        return raw.flatMap(ParticleEffect.init(rawValue:)) ?? .snow
    }

    private var particleEffectRow: some View {
        SettingRow(
            icon: "sparkles",
            iconColor: .purple,
            title: "Particles",
            info: "Drawn over the wallpaper, whatever type it is"
        ) {
            Picker("", selection: particleEffectBinding) {
                ForEach(ParticleEffect.allCases) { effect in
                    Text(effect.titleKey).tag(effect)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Particle effect"))
            .accessibilityValue(Text(draft.selectedParticleEffect.titleKey))
        }
    }

    private var particleDensityRow: some View {
        SettingRow(icon: "circle.hexagongrid", iconColor: .purple, title: "Density") {
            HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                Slider(value: particleDensityBinding, in: 0.2...3.0)
                    .controlSize(.small)
                    .frame(minWidth: 56, maxWidth: DesignTokens.Inspector.sliderWidth)
                    .accessibilityLabel(Text("Particle density"))
                    .accessibilityValue(String(format: "%.1f×", draft.particleDensity))
                Text(String(format: "%.1f", draft.particleDensity))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
            }
        }
    }

    private var weatherReactiveRow: some View {
        SettingRow(
            icon: "cloud.sun",
            iconColor: .cyan,
            title: "Match local weather"
        ) {
            Toggle("", isOn: weatherReactiveBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Weather-reactive effects"))
        }
    }

    // MARK: - Bindings

    private var particleEffectBinding: Binding<ParticleEffect> {
        Binding(
            get: { draft.selectedParticleEffect },
            set: { newValue in
                draft.selectedParticleEffect = newValue
                onParticleEffectChange(newValue)
            }
        )
    }

    private var particleDensityBinding: Binding<Double> {
        Binding(
            get: { draft.particleDensity },
            set: { newValue in
                draft.particleDensity = newValue
                onParticleDensityChange(newValue)
            }
        )
    }

    private var weatherReactiveBinding: Binding<Bool> {
        Binding(
            get: { draft.effectConfig.weatherReactive },
            set: { newValue in
                draft.effectConfig.weatherReactive = newValue
                onWeatherReactiveChange(newValue)
            }
        )
    }
}
