import LiveWallpaperCore
import SwiftUI

/// The Monitor overlay as one section of the Overlays tab — a sibling of the
/// weather overlay, not a whole right column. The enclosing panel owns the
/// scrolling and padding so both overlays share one rhythm.
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
            title: "Show on This Display",
            info: "The board floats over whatever wallpaper this display is playing"
        ) {
            Toggle("", isOn: Binding(
                get: { overlay.enabled },
                set: { screenManager.setMonitorOverlayEnabled($0, for: screen) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text("Show Monitor on this display"))
        }
    }

    private var layerRow: some View {
        SettingRow(
            icon: "square.stack.3d.up",
            iconColor: .blue,
            title: "Layer",
            info: "Desktop keeps the board under your windows; On Top floats it above everything"
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

/// What the board preview draws. A setting rather than a control on the preview
/// itself: it sits with the backdrop switch because both describe the preview,
/// and neither changes anything on the desktop.
struct MonitorPreviewModeRow: View {
    @AppStorage(MonitorBoardPreviewMode.defaultsKey) private var mode: MonitorBoardPreviewMode = .snapshot

    var body: some View {
        SettingRow(
            icon: "rectangle.on.rectangle.angled",
            iconColor: .purple,
            title: "Preview Contents",
            info: "What the board preview draws: this display's last reading, fixed sample data, or just the instrument names"
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

/// The preview's wallpaper backdrop, shown on every overlay page.
/// One switch, three places: the setting is a single `@AppStorage` key every overlay preview
/// canvas already reads, so turning it off on the Music page makes the Monitor page follow too.
/// It sits on each page because that's where the preview it changes is.
struct OverlayBackdropRow: View {
    /// Whether this display's wallpaper has a still frame to show at all.
    let available: Bool

    @AppStorage(MonitorPreviewBackdrop.showsWallpaperDefaultsKey) private var showsWallpaper = true

    var body: some View {
        SettingRow(
            icon: "photo",
            iconColor: .purple,
            title: "Wallpaper Backdrop",
            info: available
                ? "Preview the overlay over this display's wallpaper instead of an empty canvas"
                : "This wallpaper has no still frame to preview the overlay against"
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
