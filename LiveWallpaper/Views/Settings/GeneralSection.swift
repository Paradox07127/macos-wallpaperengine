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
                icon: "circle.righthalf.filled",
                iconColor: .indigo,
                title: "Appearance",
                subtitle: "Match the system, or pin the app's windows to light or dark",
                info: "Applies to the app's own windows. Panels that float over your wallpaper — the monitor board's controls and the media previews — stay dark whichever you pick, because following a light system appearance would make them white over your wallpaper."
            ) {
                appearancePicker
            }

            SettingRow(
                icon: "square.grid.2x2",
                iconColor: .orange,
                title: "Library tile size",
                subtitle: "How large wallpaper tiles are drawn in Bookmarks, Workshop and the other libraries"
            ) {
                libraryTileSizePicker
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
                icon: "arrow.triangle.2.circlepath",
                iconColor: .purple,
                title: "Check for updates automatically",
                subtitle: "Look for a newer version in the background",
                info: "Nothing is downloaded until you choose to install. When an update is found the menu bar shows an Update button instead of interrupting with a dialog."
            ) {
                Toggle("", isOn: $checksUpdatesAtLaunch)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: checksUpdatesAtLaunch) { _, enabled in
                        SparkleUpdaterController.shared.automaticallyChecksForUpdates = enabled
                    }
                    .accessibilityLabel(Text("Check for updates automatically"))
                    .accessibilityHint(Text("Looks for a newer version in the background"))
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
                icon: "camera.viewfinder",
                iconColor: .pink,
                title: "Show wallpaper in screenshots",
                subtitle: "Let screenshots, screen recording, and screen sharing capture the wallpaper",
                info: "When off, captures show the static macOS desktop picture instead. Turning it off also keeps a full-screen animation out of a shared meeting stream, which can cut the bandwidth it costs. The Monitor overlay follows this setting too."
            ) {
                Toggle("", isOn: $wallpaperVisibleInScreenCapture)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: wallpaperVisibleInScreenCapture) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Show wallpaper in screenshots"))
                    .accessibilityHint(Text("Lets screenshots, screen recording, and screen sharing capture the wallpaper"))
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

    private var libraryTileSizePicker: some View {
        GlassSegmentedPicker(
            selection: libraryTileSizeSelection,
            values: LibraryTileSize.allCases,
            shell: .flat,
            title: { $0.title }
        )
        .frame(width: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Library tile size"))
    }

    private var libraryTileSizeSelection: Binding<LibraryTileSize> {
        Binding(
            get: { LibraryTileSize(rawValue: libraryTileSizeRaw) ?? .medium },
            set: { libraryTileSizeRaw = $0.rawValue }
        )
    }

    private var appearancePicker: some View {
        GlassSegmentedPicker(
            selection: appearanceSelection,
            values: AppAppearance.allCases,
            shell: .flat,
            title: { Self.appearanceTitle($0) }
        )
        .frame(width: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Appearance"))
    }

    static func appearanceTitle(_ appearance: AppAppearance) -> LocalizedStringKey {
        switch appearance {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private var appearanceSelection: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .system },
            set: {
                appearanceRawValue = $0.rawValue
                $0.apply()
            }
        )
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
            return String(localized: "Checking…", bundle: .appLanguage, comment: "Inline status while waiting for macOS Login Items state.")
        }
        switch loginItemStatus {
        case .enabled:
            return String(localized: "Enabled", bundle: .appLanguage, comment: "Login item is enabled.")
        case .requiresApproval:
            return String(localized: "Needs Approval", bundle: .appLanguage, comment: "Login item waiting for user approval in System Settings.")
        case .notRegistered:
            return startOnLogin
                ? String(localized: "Not Granted", bundle: .appLanguage, comment: "Login item not granted yet.")
                : String(localized: "Off", bundle: .appLanguage, comment: "Feature is off.")
        case .notFound:
            return String(localized: "Unavailable", bundle: .appLanguage, comment: "Login item service unavailable.")
        @unknown default:
            return String(localized: "Unknown", bundle: .appLanguage, comment: "Unknown status value.")
        }
    }

    private var loginItemStatusSubtitle: String {
        if loginItemStatusRefreshPending {
            return String(
                localized: "Waiting for macOS to update Login Items status",
                bundle: .appLanguage, comment: "Help text while Login Items status refreshes."
            )
        }
        switch loginItemStatus {
        case .enabled:
            return String(localized: "Launch at login is enabled", bundle: .appLanguage, comment: "Help text when launch-at-login is on.")
        case .requiresApproval:
            return String(
                localized: "Approve LiveWallpaper in Login Items",
                bundle: .appLanguage, comment: "Help text prompting approval in System Settings → Login Items."
            )
        case .notRegistered:
            return startOnLogin
                ? String(
                    localized: "Registration is pending or blocked",
                    bundle: .appLanguage, comment: "Help text when login item registration has not completed."
                )
                : String(localized: "Launch at login is off", bundle: .appLanguage, comment: "Help text when launch-at-login is off.")
        case .notFound:
            return String(
                localized: "macOS could not find the app service",
                bundle: .appLanguage, comment: "Help text when SMAppService cannot find the login item."
            )
        @unknown default:
            return String(
                localized: "macOS returned an unknown login item status",
                bundle: .appLanguage, comment: "Help text for an unexpected Login Items status."
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
