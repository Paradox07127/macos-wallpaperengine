import AppKit
import LiveWallpaperCore
import SwiftUI

struct OverlaysInspectorPanel: View {
    let screen: Screen
    @Binding var draft: DraftState
    let screenManager: ScreenManager
    let inspectorPanelWidth: CGFloat
    let onParticleEffectChange: (ParticleEffect) -> Void
    let onParticleDensityChange: (Double) -> Void
    let onWeatherReactiveChange: (Bool) -> Void
    let onWeatherWindChange: (Bool) -> Void
    let onWeatherIntensityChange: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                weatherCard
            }
            .padding(.horizontal, DesignTokens.Inspector.horizontalPadding(for: inspectorPanelWidth))
            .padding(.vertical, 12)
        }
    }

    // MARK: - Weather / particles

    private var weatherCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                if draft.selectedParticleEffect != .none {
                    particleEffectRow
                    particleDensityRow
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
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
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

    /// `.none` is what "off" is: closing it must go through `OverlayEditorSession.setEffectVisible`
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
