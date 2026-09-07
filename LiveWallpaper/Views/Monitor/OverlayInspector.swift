import LiveWallpaperCore
import SwiftUI

/// The enclosing Overlays panel owns scrolling and padding.
struct MonitorOverlaySection: View {
    let screen: Screen
    let screenManager: ScreenManager
    /// Whether a still frame of the current wallpaper exists to sit behind the board.
    let backdropAvailable: Bool


    private var overlay: MonitorOverlayConfiguration {
        screenManager.monitorOverlay(for: screen)
    }

    var body: some View {
        VStack(spacing: 12) {
            displayCard
            BoardSettingsView(screen: screen, screenManager: screenManager)
        }
    }

    private var displayCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                showOnThisDisplayRow
                Divider()
                layerRow
                Divider()
                OverlayBackdropRow(available: backdropAvailable)
                MonitorPreviewModeRow()
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var showOnThisDisplayRow: some View {
        SettingRow(
            icon: overlay.enabled ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent",
            iconColor: overlay.enabled ? DesignTokens.Colors.Status.active : .secondary,
            title: "Show on This Display"
        ) {
            Toggle("", isOn: Binding(
                get: { overlay.enabled },
                set: { screenManager.setMonitorOverlayEnabled($0, for: screen) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text("Show widgets on this display"))
        }
    }

    private var layerRow: some View {
        SettingRow(
            icon: "square.stack.3d.up",
            iconColor: .blue,
            title: "Layer",
            info: "Desktop: below windows. On Top: above windows."
        ) {
            GlassSegmentedPicker(
                selection: Binding(
                    get: { overlay.level },
                    set: { screenManager.setMonitorOverlayLevel($0, for: screen) }
                ),
                values: [.desktop, .front],
                shell: .flat,
                title: { (level: MonitorOverlayLevel) in
                    level == .desktop ? "Desktop" : "On Top"
                }
            )
            .frame(width: 180)
            .disabled(!overlay.enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Overlay layer"))
        }
    }

}

/// Controls preview contents without changing the desktop overlay.
struct MonitorPreviewModeRow: View {
    @AppStorage(MonitorBoardPreviewMode.defaultsKey) private var mode: MonitorBoardPreviewMode = .snapshot

    var body: some View {
        SettingRow(
            icon: "rectangle.on.rectangle.angled",
            iconColor: .purple,
            title: "Preview Contents"
        ) {
            Picker("", selection: $mode) {
                ForEach(MonitorBoardPreviewMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Preview Contents"))
        }
    }
}

/// All overlay previews share the same wallpaper backdrop preference.
struct OverlayBackdropRow: View {
    /// Whether this display's wallpaper has a still frame to show at all.
    let available: Bool

    @AppStorage(MonitorPreviewBackdrop.showsWallpaperDefaultsKey) private var showsWallpaper = true

    var body: some View {
        SettingRow(
            icon: "photo",
            iconColor: .purple,
            title: "Wallpaper Backdrop",
            subtitle: available ? nil : "No still frame is available for this wallpaper.",
            info: available ? "Applies to all overlay previews." : nil
        ) {
            Toggle("", isOn: $showsWallpaper)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!available)
                .accessibilityLabel(Text("Show wallpaper backdrop in the preview"))
        }
    }
}
