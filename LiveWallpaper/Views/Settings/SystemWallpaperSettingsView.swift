import LiveWallpaperCore
import SwiftUI

@available(macOS 26.0, *)
struct SystemWallpaperSettingsView: View {
    @Environment(WallpaperExportService.self) private var service

    var body: some View {
        Form {
            Section {
                SettingRow(
                    icon: "play.rectangle",
                    iconColor: .indigo,
                    title: "Video playback"
                ) {
                    GlassSegmentedPicker(
                        selection: Binding(get: { service.playbackMode }, set: { service.setPlaybackMode($0) }),
                        values: [.always, .stillOnDesktop],
                        shell: .flat,
                        title: { (mode: SystemWallpaperPlaybackMode) in
                            mode == .always ? "Always" : "Lock screen only"
                        }
                    )
                    .frame(width: 230)
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("The lock screen and login window always play the video.")
            }

            Section {
                SystemWallpaperProviderNotice()
                status
                actions
            } header: {
                Text("Extension status")
            } footer: {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("macOS chooses the wallpaper for each display and Space. Importing a video does not apply it to every desktop.")
                    Text("System Wallpaper plays exported videos independently of Loomscreen. App wallpaper effects, overlays and playback controls do not apply here.")
                }
            }
        }
        .settingsFormChrome()
        .onAppear { service.refresh() }
        .task {
            while !Task.isCancelled {
                service.refreshProviderStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Settled states are rows; states carrying a reason are banners. Neither holds the
    /// buttons — `SettingRow` gives its trailing slot the leftover width, which two
    /// text buttons collapse into unreadable stubs.
    @ViewBuilder
    private var status: some View {
        switch service.status {
        case let .failed(message):
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.warning,
                symbol: "exclamationmark.triangle.fill",
                title: Text("Couldn't update System Wallpaper"),
                message: Text(verbatim: message),
                surface: .content
            )
        case .systemIncompatible:
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.danger,
                symbol: "xmark.circle.fill",
                title: Text("This version of macOS is not compatible with the wallpaper extension."),
                surface: .content
            )
        case .inUse:
            SettingRow(
                icon: "checkmark.circle.fill",
                iconColor: DesignTokens.Colors.Status.active,
                title: "Selected by macOS"
            ) {
                EmptyView()
            }
        case .empty, .publishedNotSelected:
            SettingRow(
                icon: "arrow.right.circle.fill",
                iconColor: .accentColor,
                title: "Choose a wallpaper in System Settings"
            ) {
                EmptyView()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button("Refresh") { service.refresh() }
            Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

@available(macOS 26.0, *)
struct SystemWallpaperProviderNotice: View {
    @Environment(WallpaperExportService.self) private var service

    var body: some View {
        if let issue = service.providerIssue {
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.warning,
                symbol: "exclamationmark.triangle",
                title: Text("System Wallpaper needs attention"),
                message: message(for: issue),
                surface: .content
            ) {
                Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func message(for issue: WallpaperExportService.ProviderIssue) -> Text {
        switch issue {
        case .differentCopy:
            Text("macOS is using another copy of the wallpaper extension. Open the installed Loomscreen app and remove old app copies.")
        case .stopped, .unresponsive:
            Text("The wallpaper extension stopped responding. Select the video again in System Settings. If it still fails, sign out and sign back in to restart the system wallpaper service.")
        }
    }
}
