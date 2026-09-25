import AppKit
import LiveWallpaperCore
import SwiftUI

struct OverlaysInspectorPanel: View {
    let screen: Screen
    @Binding var draft: DraftState
    let screenManager: ScreenManager
    let kind: OverlayKind
    let inspectorPanelWidth: CGFloat
    let backdropAvailable: Bool
    var showsBackdropControl = true
    /// The weather card's own "Show on This Display"; Edit Desk turns it off from the layer list instead.
    var showsVisibilityControl = true
    let onParticleEffectChange: (ParticleEffect) -> Void
    let onParticleDensityChange: (Double) -> Void
    let onWeatherReactiveChange: (Bool) -> Void
    let onWeatherWindChange: (Bool) -> Void
    let onWeatherIntensityChange: (Bool) -> Void

    var body: some View {
        ScrollView {
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
                case .clock:
                    ClockOverlaySection(screen: screen, screenManager: screenManager, backdropAvailable: backdropAvailable)
                case .music:
                    MusicOverlaySection(
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

    // MARK: - Weather / particles

    private var weatherCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                if showsVisibilityControl {
                    weatherEnabledRow
                }

                if draft.selectedParticleEffect != .none {
                    particleEffectRow
                    particleDensityRow
                }

                if showsVisibilityControl || draft.selectedParticleEffect != .none {
                    Divider()
                }

                weatherReactiveRow

                if draft.effectConfig.weatherReactive {
                    weatherIntensityRow
                    weatherWindRow
                    WeatherStatusBadge(
                        weatherService: screenManager.weatherService,
                        refresh: screenManager.weatherService.refresh
                    )
                }

                if showsBackdropControl {
                    Divider()
                    OverlayBackdropRow(available: backdropAvailable)
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var weatherEnabledRow: some View {
        SettingRow(
            icon: isWeatherOn ? "cloud.sun.rain.fill" : "cloud.sun",
            iconColor: isWeatherOn ? DesignTokens.Colors.Status.active : .secondary,
            title: "Show on This Display"
        ) {
            Toggle("", isOn: weatherEnabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Weather overlay"))
        }
    }

    private var isWeatherOn: Bool { draft.selectedParticleEffect != .none }

    /// The model stores the effect as an enum, so a blunt on/off switch would
    /// forget the choice; remembered per display because the effect is per display.
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
            title: "Particles"
        ) {
            Picker("", selection: particleEffectBinding) {
                ForEach(Self.pickerEffects) { effect in
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
            CoalescedSlider(
                value: draft.particleDensity,
                in: 0.2...3.0,
                owner: screen.id,
                sizing: .flexible(minimum: 56, maximum: DesignTokens.Inspector.sliderWidth),
                accessibilityLabel: Text("Particle density"),
                accessibilityValue: { Text(verbatim: String(format: "%.1f×", $0)) },
                write: { particleDensityBinding.wrappedValue = $0 },
                readout: { live in
                    Text(verbatim: String(format: "%.1f", live))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            )
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
                .controlSize(.small)
                .accessibilityLabel(Text("Weather-reactive effects"))
        }
    }

    private var weatherIntensityRow: some View {
        SettingRow(
            icon: "cloud.heavyrain",
            iconColor: .cyan,
            title: "Match density to weather"
        ) {
            Toggle("", isOn: weatherIntensityBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Match density to weather"))
        }
    }

    private var weatherWindRow: some View {
        SettingRow(
            icon: "wind",
            iconColor: .cyan,
            title: "Follow wind direction"
        ) {
            Toggle("", isOn: weatherWindBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Follow wind direction"))
        }
    }

    // MARK: - Bindings

    /// `.none` is what "off" is: closing it must go through `weatherEnabledBinding`
    /// so the last effect is remembered.
    static var pickerEffects: [ParticleEffect] {
        ParticleEffect.allCases.filter { $0 != .none }
    }

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

    private var weatherWindBinding: Binding<Bool> {
        Binding(
            get: { draft.effectConfig.weatherWind },
            set: { newValue in
                draft.effectConfig.weatherWind = newValue
                onWeatherWindChange(newValue)
            }
        )
    }

    private var weatherIntensityBinding: Binding<Bool> {
        Binding(
            get: { draft.effectConfig.weatherIntensity },
            set: { newValue in
                draft.effectConfig.weatherIntensity = newValue
                onWeatherIntensityChange(newValue)
            }
        )
    }
}
