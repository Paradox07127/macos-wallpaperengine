import SwiftUI
import LiveWallpaperCore

struct ColorAdjustmentsView: View {
    @Binding var effectConfig: VideoEffectConfig
    /// Per-display colourspace override.
    @Binding var videoColorSpace: VideoColorSpace
    var screen: Screen
    var screenManager: ScreenManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 12) {
                colorSpaceRow

                Divider()

                effectSlider(title: "Blur", value: effectBinding(\.blurRadius), in: 0...30, format: "%.0f")
                effectSlider(title: "Brightness", value: effectBinding(\.brightness), in: -0.5...0.5, format: "%.2f")
                effectSlider(title: "Saturation", value: effectBinding(\.saturation), in: 0...2, format: "%.1f")
                effectSlider(title: "Warmth", value: effectBinding(\.warmth), in: 2500...8000, format: "%.0f")
                effectSlider(title: "Vignette", value: effectBinding(\.vignetteIntensity), in: 0...5, format: "%.1f")

                Divider()

                SettingRow(
                    icon: "sun.max",
                    title: "Auto warm tint",
                    info: "Automatically adjust color temperature by time of day"
                ) {
                    Toggle("", isOn: effectBinding(\.autoTimeTint))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Auto warm tint"))
                        .accessibilityHint(Text("Automatically adjusts color warmth based on time of day"))
                }

                Divider()

                HStack {
                    Spacer()
                    Button(action: resetEffects) {
                        Label("Reset Color & Filters", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(DesignTokens.Colors.Status.danger)
                    .help(Text("Reset blur, brightness, saturation, warmth, vignette, and auto-tint to defaults"))
                    Spacer()
                }
            }
        }
    }

    private var colorSpaceRow: some View {
        SettingRow(
            icon: "paintpalette",
            title: "Color Management",
            info: String.LocalizationValue(stringLiteral: videoColorSpace.descriptionKey)
        ) {
            Picker("", selection: Binding(
                get: { videoColorSpace },
                set: { newValue in
                    guard videoColorSpace != newValue else { return }
                    videoColorSpace = newValue
                    screenManager.updateVideoColorSpace(newValue, for: screen)
                }
            )) {
                ForEach(VideoColorSpace.allCases) { space in
                    Text(LocalizedStringKey(space.titleKey)).tag(space)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            .accessibilityLabel(Text("Color management"))
        }
    }

    private func resetEffects() {
        effectConfig = Self.resettingColorAdjustments(effectConfig)
        screenManager.updateEffectConfig(effectConfig, for: screen)
    }

    /// Reset colour/filter fields only; preserve weather and particle settings.
    static func resettingColorAdjustments(_ config: VideoEffectConfig) -> VideoEffectConfig {
        var result = config
        let defaults = VideoEffectConfig.default
        result.blurRadius = defaults.blurRadius
        result.brightness = defaults.brightness
        result.saturation = defaults.saturation
        result.warmth = defaults.warmth
        result.vignetteIntensity = defaults.vignetteIntensity
        result.autoTimeTint = defaults.autoTimeTint
        return result
    }

    private func effectBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<VideoEffectConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { effectConfig[keyPath: keyPath] },
            set: { newValue in
                guard effectConfig[keyPath: keyPath] != newValue else { return }
                effectConfig[keyPath: keyPath] = newValue
                screenManager.updateEffectConfig(effectConfig, for: screen)
            }
        )
    }

    /// Coalesced: `effectBinding`'s setter persists the config and rebuilds the
    /// display's `CIFilter` chain, which is not something to do once per
    /// gesture sample.
    private func effectSlider(
        title: LocalizedStringKey,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
            Text(title)
                .font(DesignTokens.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 90, alignment: .leading)

            CoalescedSlider(
                value: value.wrappedValue,
                in: range,
                owner: screen.id,
                sizing: .flexible(minimum: 0, maximum: .infinity),
                accessibilityLabel: Text(title),
                accessibilityValue: { Text(verbatim: String(format: format, $0)) },
                write: { value.wrappedValue = $0 },
                readout: { live in
                    Text(verbatim: String(format: format, live))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            )
        }
    }
}
