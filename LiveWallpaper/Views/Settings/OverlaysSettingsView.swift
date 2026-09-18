import LiveWallpaperCore
import SwiftUI

/// Appearance here is shared by every overlay panel on every display; the per-display
/// parts of an overlay stay in the board's own inspector.
struct OverlaysSettingsView: View {
    @AppStorage(MonitorTemperature.fahrenheitDefaultsKey) private var temperatureFahrenheit = false
    @AppStorage(MonitorPanelAppearance.tintKey, store: .appScoped())
    private var widgetTintHex = MonitorPanelAppearance.defaultTintHex
    @AppStorage(MonitorPanelAppearance.opacityKey, store: .appScoped())
    private var widgetOpacity = MonitorPanelAppearance.defaultOpacity
    @AppStorage(MonitorPanelAppearance.glassKey, store: .appScoped())
    private var widgetLiquidGlass = MonitorPanelAppearance.defaultGlass

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Form {
            Section {
                widgetTintRow
                widgetOpacityRow
                widgetGlassRow
            } header: {
                SettingsSearchSectionHeader("Widgets", anchor: .overlaysAppearance)
            } footer: {
                Text("Applies to every widget panel on every display.")
            }

            Section {
                temperatureUnitRow
            } header: {
                SettingsSearchSectionHeader("Units", anchor: .overlaysUnits)
            }
        }
        .settingsFormChrome()
    }

    private var widgetTintRow: some View {
        SettingRow(
            icon: "paintpalette",
            iconColor: .teal,
            title: "Widget tint",
            valueSubtitle: widgetTintHex.isEmpty ? nil : widgetTintHex
        ) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ColorPicker("", selection: Binding(
                    get: { MonitorPanelAppearance.color(fromHex: widgetTintHex) ?? Design.panelFillTop },
                    set: { widgetTintHex = MonitorPanelAppearance.hex(from: $0) }
                ), supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(Text("Widget tint"))

                Button("Reset") { widgetTintHex = MonitorPanelAppearance.defaultTintHex }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(widgetTintHex.isEmpty)
                    .accessibilityLabel(Text("Reset widget tint to the default"))
            }
        }
    }

    private var widgetOpacityRow: some View {
        SettingRow(
            icon: "circle.lefthalf.filled",
            iconColor: .teal,
            title: "Widget opacity",
            valueSubtitle: "\(Int(MonitorPanelAppearance.resolvedOpacity(widgetOpacity) * 100))%"
        ) {
            CoalescedSlider(
                value: MonitorPanelAppearance.resolvedOpacity(widgetOpacity),
                in: MonitorPanelAppearance.opacityRange,
                owner: MonitorPanelAppearance.opacityKey,
                sizing: .fixed(DesignTokens.Settings.sliderWidth),
                accessibilityLabel: Text("Widget opacity"),
                accessibilityValue: { Text("\(Int($0 * 100)) percent") },
                write: { widgetOpacity = $0 },
                readout: { live in
                    Text(verbatim: "\(Int(live * 100))%")
                }
            )
        }
    }

    @ViewBuilder
    private var widgetGlassRow: some View {
        if #available(macOS 26.0, *) {
            SettingRow(
                icon: "circle.hexagongrid.circle",
                iconColor: .teal,
                title: "Liquid Glass",
                subtitle: reduceTransparency
                    ? "Unavailable while Reduce Transparency is on."
                    : nil,
                info: "Refracts the wallpaper through widget cards. May increase energy use."
            ) {
                Toggle("", isOn: $widgetLiquidGlass)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(reduceTransparency)
                    .accessibilityLabel(Text("Liquid Glass widget cards"))
            }
        }
    }

    private var temperatureUnitRow: some View {
        SettingRow(
            icon: "thermometer.variable.and.figure",
            iconColor: .orange,
            title: "Temperature"
        ) {
            GlassSegmentedPicker(
                selection: Binding(
                    get: { temperatureFahrenheit },
                    set: { temperatureFahrenheit = $0 }
                ),
                values: [false, true],
                shell: .flat
            ) { fahrenheit, isSelected in
                Text(verbatim: fahrenheit ? "°F" : "°C")
                    .font(isSelected ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
            }
            .frame(width: 100)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Temperature unit"))
        }
    }
}
