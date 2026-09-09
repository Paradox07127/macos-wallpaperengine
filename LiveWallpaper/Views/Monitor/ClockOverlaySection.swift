import LiveWallpaperCore
import SwiftUI

struct ClockOverlaySection: View {
    let screen: Screen
    let screenManager: ScreenManager
    let backdropAvailable: Bool

    private var clock: ClockOverlayConfiguration {
        screenManager.monitorOverlay(for: screen).clock
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ClockOverlayConfiguration, Value>) -> Binding<Value> {
        Binding(get: { clock[keyPath: keyPath] }, set: { value in
            var next = screenManager.monitorOverlay(for: screen).clock
            next[keyPath: keyPath] = value
            screenManager.setClockOverlay(next, for: screen)
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            GroupBox {
                VStack(spacing: 8) {
                    toggleRow("Show on This Display", icon: "clock", keyPath: \.enabled)
                    Divider()
                    SettingRow(icon: "square.stack.3d.up", iconColor: .blue, title: "Layer",
                               info: "Desktop: below windows. On Top: above windows.") {
                        GlassSegmentedPicker(selection: binding(\.level), values: [.desktop, .front], shell: .flat,
                                             title: { (level: MonitorOverlayLevel) in level == .desktop ? "Desktop" : "On Top" })
                            .frame(width: 180)
                            .disabled(!clock.enabled)
                            .accessibilityLabel(Text("Clock layer"))
                    }
                    Divider()
                    widthRow
                    Text("Drag the clock to move it. Drag its corner to resize.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    OverlayBackdropRow(available: backdropAvailable)
                }
            }
            .groupBoxStyle(ContainerGroupBoxStyle())

            GroupBox {
                VStack(spacing: 8) {
                    toggleRow("24-Hour Time", icon: "clock", keyPath: \.uses24HourTime)
                    Divider()
                    toggleRow("Leading Hour Zero", icon: "textformat.123", keyPath: \.padsHour)
                    Divider()
                    toggleRow("Blink Separators", icon: "lightbulb", keyPath: \.blinksSeparators)
                    Divider()
                    SettingRow(icon: "circle.lefthalf.filled", iconColor: .purple, title: "Opacity") {
                        CoalescedSlider(
                            value: clock.opacity, in: 0.2 ... 1, owner: screen.id,
                            sizing: .flexible(minimum: 56, maximum: DesignTokens.Inspector.sliderWidth),
                            accessibilityLabel: Text("Clock opacity"),
                            accessibilityValue: { Text(verbatim: String(format: "%.0f%%", $0 * 100)) },
                            write: { binding(\.opacity).wrappedValue = $0 },
                            readout: { value in
                                Text(verbatim: String(format: "%.0f%%", value * 100))
                                    .font(DesignTokens.Typography.metric)
                                    .foregroundStyle(.secondary)
                                    .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                            }
                        )
                    }
                }
                .disabled(!clock.enabled)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private var widthRow: some View {
        SettingRow(icon: "arrow.up.left.and.arrow.down.right", iconColor: .blue, title: "Size") {
            CoalescedSlider(
                value: clock.width, in: ClockOverlayConfiguration.widthRange, owner: screen.id,
                sizing: .flexible(minimum: 56, maximum: DesignTokens.Inspector.sliderWidth),
                accessibilityLabel: Text("Clock width"),
                accessibilityValue: { Text(verbatim: String(format: "%.0f pt", $0)) },
                write: { binding(\.width).wrappedValue = $0 },
                readout: { value in
                    Text(verbatim: String(format: "%.0f", value))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
                }
            )
            .disabled(!clock.enabled)
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, icon: String,
                           keyPath: WritableKeyPath<ClockOverlayConfiguration, Bool>) -> some View {
        SettingRow(icon: icon, iconColor: .orange, title: title) {
            Toggle("", isOn: binding(keyPath))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(title))
        }
    }
}
