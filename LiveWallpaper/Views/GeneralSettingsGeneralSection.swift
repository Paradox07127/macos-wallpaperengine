import LiveWallpaperCore
import ServiceManagement
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var generalSection: some View {
        Section {
            SettingRow(icon: "globe", iconColor: .teal, title: "Language", subtitle: "Choose the display language used by LiveWallpaper") {
                languagePicker
            }

            SettingRow(
                icon: "power.circle.fill",
                iconColor: loginItemShowsInlineStatus ? loginItemStatusColor : .green,
                title: "Start at login",
                subtitle: "Automatically launch LiveWallpaper when you log in"
            ) {
                HStack(spacing: 8) {
                    if loginItemShowsInlineStatus {
                        StatusChip(verbatim: loginItemStatusText, tint: loginItemStatusColor)
                            .help(Text(verbatim: loginItemStatusSubtitle))
                    }

                    if loginItemNeedsApproval {
                        Button("Open") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .adaptiveGlassButton(.regular, size: .small)
                        .fixedSize()
                        .accessibilityLabel(Text("Open Login Items settings"))
                    }

                    Toggle("", isOn: $startOnLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: startOnLogin) { _, _ in
                            updateGlobalSettings()
                            scheduleSystemStatusRefresh(.loginItem)
                        }
                        .accessibilityLabel(Text("Start at login"))
                        .accessibilityHint(Text("Automatically launch LiveWallpaper when you log in"))
                }
            }

            SettingRow(
                icon: "lock.display",
                iconColor: .blue,
                title: "Capture video frame when locking",
                subtitle: "Update the macOS desktop picture from enabled video displays when the screen locks",
                info: "This is not an unlock-restore option. When the screen locks, enabled video displays capture their current frame and set it as the macOS desktop picture. The desktop picture remains changed after unlock."
            ) {
                Toggle("", isOn: $preservePlaybackOnLock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: preservePlaybackOnLock) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Capture video frame when locking"))
                    .accessibilityHint(Text("Updates the macOS desktop picture from enabled video displays when the screen locks"))
            }

            SettingRow(
                icon: "dock.rectangle",
                iconColor: .indigo,
                title: "Show in Dock",
                subtitle: "Make the app visible in the Dock and Cmd-Tab switcher",
                info: "When off, the app keeps running in the background — reopen this window anytime from the menu bar icon at the top-right of your screen."
            ) {
                Toggle("", isOn: $showInDock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: showInDock) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Show in Dock"))
                    .accessibilityHint(Text("Toggles whether the app appears in the Dock and the Cmd-Tab switcher"))
            }
        } header: {
            Text("General")
        }
    }

    private var languagePicker: some View {
        Picker("", selection: appLanguageSelection) {
            ForEach(AppLanguagePreference.allCases) { language in
                Text(language.titleKey).tag(language)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Language"))
        .accessibilityHint(Text("Choose the display language used by LiveWallpaper"))
    }

    private var appLanguageSelection: Binding<AppLanguagePreference> {
        Binding(
            get: { AppLanguagePreference(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
    }

    // MARK: - Login Item Inline Status

    private var loginItemNeedsApproval: Bool {
        startOnLogin && !loginItemStatusRefreshPending && loginItemStatus == .requiresApproval
    }

    private var loginItemShowsInlineStatus: Bool {
        startOnLogin || loginItemNeedsApproval || loginItemStatusRefreshPending
    }

    private var loginItemStatusText: String {
        if loginItemStatusRefreshPending {
            return String(localized: "Checking…", comment: "Inline status while waiting for macOS Login Items state.")
        }
        switch loginItemStatus {
        case .enabled:
            return String(localized: "Enabled", comment: "Login item is enabled.")
        case .requiresApproval:
            return String(localized: "Needs Approval", comment: "Login item waiting for user approval in System Settings.")
        case .notRegistered:
            return startOnLogin
                ? String(localized: "Not Granted", comment: "Login item not granted yet.")
                : String(localized: "Off", comment: "Feature is off.")
        case .notFound:
            return String(localized: "Unavailable", comment: "Login item service unavailable.")
        @unknown default:
            return String(localized: "Unknown", comment: "Unknown status value.")
        }
    }

    private var loginItemStatusSubtitle: String {
        if loginItemStatusRefreshPending {
            return String(
                localized: "Waiting for macOS to update Login Items status",
                comment: "Help text while Login Items status refreshes."
            )
        }
        switch loginItemStatus {
        case .enabled:
            return String(localized: "Launch at login is enabled", comment: "Help text when launch-at-login is on.")
        case .requiresApproval:
            return String(
                localized: "Approve LiveWallpaper in Login Items",
                comment: "Help text prompting approval in System Settings → Login Items."
            )
        case .notRegistered:
            return startOnLogin
                ? String(
                    localized: "Registration is pending or blocked",
                    comment: "Help text when login item registration has not completed."
                )
                : String(localized: "Launch at login is off", comment: "Help text when launch-at-login is off.")
        case .notFound:
            return String(
                localized: "macOS could not find the app service",
                comment: "Help text when SMAppService cannot find the login item."
            )
        @unknown default:
            return String(
                localized: "macOS returned an unknown login item status",
                comment: "Help text for an unexpected Login Items status."
            )
        }
    }

    private var loginItemStatusColor: Color {
        if loginItemStatusRefreshPending {
            return .secondary
        }
        switch loginItemStatus {
        case .enabled:
            return DesignTokens.Colors.Status.active
        case .requiresApproval:
            return DesignTokens.Colors.Status.warning
        case .notRegistered:
            return startOnLogin ? DesignTokens.Colors.Status.warning : .secondary
        case .notFound:
            return DesignTokens.Colors.Status.danger
        @unknown default:
            return .secondary
        }
    }
}
