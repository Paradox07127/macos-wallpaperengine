import LiveWallpaperCore
import ServiceManagement
import SwiftUI
#if !LITE_BUILD
@preconcurrency import Translation
#endif

extension GeneralSettingsView {
    @ViewBuilder
    var generalSection: some View {
        Section {
            #if !LITE_BUILD
            if #available(macOS 15.0, *) {
                TranslationLanguageDownloadRows(appLanguage: appLanguageRawValue) { languageRow }
            } else {
                languageRow
            }
            #else
            languageRow
            #endif
        } header: {
            SettingsSearchSectionHeader("Language", anchor: .generalLanguage)
        }

        Section {
            SettingRow(
                icon: "power.circle.fill",
                iconColor: loginItemShowsInlineStatus ? loginItemStatusColor : .green,
                title: "Start at login"
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
                }
            }

            SettingRow(
                icon: "arrow.triangle.2.circlepath",
                iconColor: .purple,
                title: "Check for updates automatically",
                info: "Checks at launch and periodically while the app is running."
            ) {
                Toggle("", isOn: $checksUpdatesAtLaunch)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: checksUpdatesAtLaunch) { _, enabled in
                        SparkleUpdaterController.shared.automaticallyChecksForUpdates = enabled
                    }
                    .accessibilityLabel(Text("Check for updates automatically"))
                    .accessibilityHint(Text("Checks at launch and periodically while the app is running."))
            }

            SettingRow(
                icon: "dock.rectangle",
                iconColor: .indigo,
                title: "Show in Dock",
                info: "When off, hides the app from the Dock and ⌘Tab. Open it from the menu bar."
            ) {
                Toggle("", isOn: $showInDock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: showInDock) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Show in Dock"))
                    .accessibilityHint(Text("Toggles whether the app appears in the Dock and the Cmd-Tab switcher"))
            }
        } header: {
            SettingsSearchSectionHeader("Startup", anchor: .generalStartup)
        }

        Section {
            SettingRow(
                icon: "lock.display",
                iconColor: .blue,
                title: "Capture video frame when locking",
                subtitle: "On lock, sets enabled displays’ video frames as desktop pictures. These remain after unlock."
            ) {
                Toggle("", isOn: $preservePlaybackOnLock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: preservePlaybackOnLock) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Capture video frame when locking"))
                    .accessibilityHint(Text("On lock, sets enabled displays’ video frames as desktop pictures. These remain after unlock."))
            }

            SettingRow(
                icon: "camera.viewfinder",
                iconColor: .pink,
                title: "Show wallpaper in screen captures",
                info: "Applies to screenshots, recording, and sharing, including widgets. When off, shows the macOS desktop picture."
            ) {
                Toggle("", isOn: $wallpaperVisibleInScreenCapture)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: wallpaperVisibleInScreenCapture) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Show wallpaper in screen captures"))
                    .accessibilityHint(Text("Applies to screenshots, recording, and sharing, including widgets. When off, shows the macOS desktop picture."))
            }

            WallpaperOpeningSettingRow()

            WallpaperTransitionSettingRow()
        } header: {
            SettingsSearchSectionHeader("Wallpaper", anchor: .generalWallpaper)
        }
    }

    private var languageRow: some View {
        SettingRow(icon: "globe", iconColor: .teal, title: "Language") {
            languagePicker
        }
    }

    private var languagePicker: some View {
        Picker("", selection: appLanguageSelection) {
            ForEach(AppLanguagePreference.menuCases) { language in
                language.pickerLabel.tag(language)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Language"))
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

#if !LITE_BUILD
/// The Language row, then the Translate wallpaper text switch, which also offers the download while
/// Chinese → app language is supported but not installed. The pack checks ride on the Language row.
@available(macOS 15.0, *)
private struct TranslationLanguageDownloadRows<Language: View>: View {
    /// Stored `AppLanguagePreference` raw value.
    let appLanguage: String
    @ViewBuilder let language: Language
    @State private var offer = TranslationPackOffer()
    @AppStorage(WPEPropertyLabelTranslator.enabledPreferenceKey, store: .appScoped()) private var translationEnabled = true

    var body: some View {
        language
            .task(id: appLanguage) { await offer.refresh(target: target) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await offer.refresh(target: target) }
            }
            .translationTask(offer.configuration, action: offer.prepare)
        SettingRow(
            icon: "translate",
            iconColor: .blue,
            title: "Translate wallpaper text",
            subtitle: offersDownload
                ? "Download the translation languages for Chinese and \(languageName) to show Chinese wallpaper names, settings, and descriptions in \(languageName)."
                : nil,
            info: offersDownload ? nil : "Translates wallpaper titles, settings, and descriptions into the app language. Requires the matching translation languages, downloaded in System Settings."
        ) {
            HStack(spacing: 8) {
                if offersDownload {
                    Button("Download") { offer.requestDownload(target: target) }
                        .fixedSize()
                }
                Toggle("", isOn: $translationEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Translate wallpaper text"))
            }
        }
    }

    private var offersDownload: Bool {
        translationEnabled && offer.offersDownload
    }

    private var target: Locale.Language {
        WPEPropertyLabelTranslator.effectiveTargetLanguage(preference: appLanguage)
    }

    /// The app language's name in that language, such as "English"; fills both placeholders of the download subtitle.
    private var languageName: String {
        let code = target.languageCode?.identifier ?? target.minimalIdentifier
        return Locale(identifier: target.minimalIdentifier).localizedString(forLanguageCode: code) ?? code
    }
}

@available(macOS 15.0, *)
@MainActor
@Observable
private final class TranslationPackOffer {
    private static let chinese = Locale.Language(identifier: "zh-Hans")
    private(set) var offersDownload = false
    private(set) var configuration: TranslationSession.Configuration?

    func refresh(target: Locale.Language) async {
        guard target.languageCode != .chinese else {
            offersDownload = false
            return
        }
        offersDownload = await LanguageAvailability().status(from: Self.chinese, to: target) == .supported
    }

    func requestDownload(target: Locale.Language) {
        if configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: Self.chinese, target: target)
        }
    }

    /// `.translationTask` action; `nonisolated` for the same reason as `WPEPropertyLabelTranslator.translateLabels`.
    nonisolated func prepare(using session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch {
            Logger.notice("Translation language download did not finish: \(error.localizedDescription)", category: .settings)
        }
        await finishDownload()
    }

    private func finishDownload() async {
        if let target = configuration?.target {
            await refresh(target: target)
        }
        NotificationCenter.default.post(name: WPEPropertyLabelTranslator.languagePacksMayHaveChanged, object: nil)
    }
}
#endif
