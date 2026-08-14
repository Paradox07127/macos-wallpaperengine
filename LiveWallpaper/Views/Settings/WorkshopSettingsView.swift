#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Pages this settings pane can push to.
enum WorkshopSettingsRoute: Hashable {
    case steamConnection
}

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1", store: .appScoped()) private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1", store: .appScoped()) private var hidesDownloadedInBrowse = false
    @AppStorage("loomscreen.workshop.checkAssetsUpdateAtLaunch.v1", store: .appScoped()) private var checksAssetsUpdateAtLaunch = false

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var preflightingDoctor = false
    /// Set when an action was refused for a reason the Doctor sheet cannot fix.
    @State private var blockedActionMessage: String?
    @State private var route: [WorkshopSettingsRoute] = []
    @State private var showingRemoveConfirm = false
    @State private var showingKeyEntry = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        _pendingSearchAnchor = pendingSearchAnchor
    }

    var body: some View {
        NavigationStack(path: $route) {
            form
                .navigationDestination(for: WorkshopSettingsRoute.self) { route in
                    switch route {
                    case .steamConnection:
                        WorkshopDoctorView(chrome: .pane)
                            .environment(doctorService)
                    }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                SettingRow(
                    icon: "key",
                    iconColor: .orange,
                    title: "Steam Web API key",
                    titleBadge: keyTitleBadge,
                    subtitle: "Your own free key — required to browse the Workshop online",
                    info: "The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS, and the key is stored only on this Mac (no iCloud sync). Get one free at steamcommunity.com/dev/apikey."
                ) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if workshopServices.hasWebAPIKey {
                            Button("Replace") { showingKeyEntry = true }
                                .adaptiveGlassButton(.regular, size: .small)
                                .help(Text("Set a new Steam Web API key"))
                            Button("Forget", role: .destructive) {
                                Task {
                                    try? await workshopServices.keychain.deleteWebAPIKey()
                                    await workshopServices.refreshAPIKeyStatus()
                                }
                            }
                            .adaptiveGlassButton(.regular, size: .small)
                            .tint(DesignTokens.Colors.Status.danger)
                            .help(Text(verbatim: WorkshopAPIKeyOwnershipInfo.forgetTooltip))
                        } else {
                            Button("Set key") { showingKeyEntry = true }
                                .adaptiveGlassButton(.prominent, size: .small)
                                .help(Text("Paste your Steam Web API key"))
                        }
                    }
                    .fixedSize()
                }

                SettingRow(
                    icon: "bolt.horizontal.circle",
                    iconColor: .teal,
                    title: "Steam connection",
                    titleBadge: doctorTitleBadge,
                    subtitle: steamConnectionSubtitle,
                    info: "Loomscreen reads installed Workshop items directly from the official Steam library after one folder authorization. Authenticated SteamCMD downloads are a separate capability and require Loomscreen's background Steam connector."
                ) {
                    // Pushed, not presented. Steam connection is a place with
                    // its own state to come back to, not one task to finish and
                    // dismiss — and a sheet opened from a settings page whose
                    // own rows open further sheets was three levels deep.
                    NavigationLink(value: WorkshopSettingsRoute.steamConnection) {
                        Text("Configure", bundle: .main)
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                    .help(Text("Configure Steam library access and SteamCMD"))
                }

                SettingRow(
                    icon: "shippingbox",
                    iconColor: .brown,
                    title: "Wallpaper Engine assets",
                    titleBadge: engineTitleBadge,
                    subtitle: engineAssetsSubtitle,
                    info: "Loomscreen bundles clean-room equivalents of the common Wallpaper Engine framework files, so most scenes render without a Wallpaper Engine install. Link one only for scenes that reference uncommon shared assets — read-only access, no files are modified."
                ) {
                    engineAssetsControl
                        .frame(maxHeight: 24)
                }
                if engineInstaller.hasManagedInstall {
                    SettingRow(
                        icon: "arrow.triangle.2.circlepath",
                        iconColor: .brown,
                        title: "Check for asset updates at launch",
                        subtitle: "Look for a newer Wallpaper Engine build when Loomscreen starts",
                        info: "Runs the same version check as the button, once per launch. It only reads Steam's build number — nothing is downloaded until you choose to update."
                    ) {
                        Toggle("", isOn: $checksAssetsUpdateAtLaunch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel(Text("Check for Wallpaper Engine asset updates at launch"))
                    }
                }
                if let status = engineAssetsStatusLine {
                    Text(verbatim: status.message)
                        .font(.caption)
                        .foregroundStyle(status.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                SettingsSearchSectionHeader("Setup", anchor: .workshopSetup)
            } footer: {
                WorkshopPrivacyLink()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                SettingRow(
                    icon: "eye.slash",
                    iconColor: .pink,
                    title: "Blur mature thumbnails",
                    subtitle: "Hide Mature covers in Browse until you click to reveal"
                ) {
                    Toggle("", isOn: $blurMatureThumbnails)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Blur mature thumbnails until clicked"))
                }
                SettingRow(
                    icon: "tray.full",
                    iconColor: .indigo,
                    title: "Hide items already in my library",
                    subtitle: "Keep Browse Online focused on wallpapers you don't have yet"
                ) {
                    Toggle("", isOn: $hidesDownloadedInBrowse)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Hide items already in my library when browsing"))
                }
            } header: {
                SettingsSearchSectionHeader("Content", anchor: .workshopContent)
            }

            WorkshopBadgeSection()
        }
        .settingsFormChrome()
        .settingsSearchAnchorScroller(
            pendingSearchAnchor: $pendingSearchAnchor,
            anchors: [
                .workshopSetup,
                .workshopContent,
                .workshopBadges
            ]
        )
        .overlay(alignment: .bottomTrailing) {
            DownloadToastHost()
                .padding(DesignTokens.Spacing.lg)
        }
        .sheet(isPresented: $showingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: workshopServices) {
                Task { await workshopServices.refreshAPIKeyStatus() }
            }
        }
        .task {
            engineInstaller.refreshManagedInstallState()
            await workshopServices.refreshAPIKeyStatus()
        }
    }

    private var engineAssetsSubtitle: LocalizedStringKey {
        engineInstaller.hasManagedInstall || engineAssets.isAuthorized
            ? "Linked for extra scene coverage"
            : "Link a Wallpaper Engine install for extra scene coverage"
    }

    /// Percent + transferred size so multi-GB downloads don't look stuck on a bare bar.
    private func downloadProgressLabel(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        guard let bytes = engineInstaller.progressBytes,
              let downloaded = bytes.downloaded, let total = bytes.total, total > 0 else {
            return "\(percent)%"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return "\(percent)%  ·  \(formatter.string(fromByteCount: Int64(downloaded))) / \(formatter.string(fromByteCount: Int64(total)))"
    }

    private func revealEngineAssetsInFinder() {
        guard let root = WPEEngineAssetsLibrary.managedInstallRoot() ?? engineAssets.resolveAuthorizedRoot() else { return }
        // Steam-folder path: needs the same security scope as other library reads.
        let scope = root.startAccessingSecurityScopedResource()
        defer { if scope { root.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    @ViewBuilder
    private var engineAssetsControl: some View {
        if preflightingDoctor {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            }
        } else if engineInstaller.isBusy {
            engineAssetsBusyControl
        } else if engineInstaller.hasManagedInstall {
            engineAssetsManagedControl
        } else if engineAssets.isAuthorized {
            engineAssetsManualControl
        } else {
            engineAssetsUnlinkedControl
        }
    }

    /// Run `action` when Doctor preflight is green; navigate to Steam connection
    /// only if it can fix the blocker.
    private func preflightThen(_ action: @escaping () -> Void) {
        // Config + cached login required; advisory ownership must not block recovery.
        blockedActionMessage = nil
        if doctorService.isDownloadReady { action(); return }
        // Unfixable blockers stay as inline copy — don't navigate to an all-green page.
        guard doctorService.downloadBlocker?.isFixableInDoctor ?? true else {
            blockedActionMessage = doctorService.downloadBlockerMessage
            return
        }
        Task {
            preflightingDoctor = true
            await doctorService.runAll()
            preflightingDoctor = false
            if doctorService.isDownloadReady {
                action()
            } else if doctorService.downloadBlocker?.isFixableInDoctor ?? true {
                route = [.steamConnection]
            } else {
                blockedActionMessage = doctorService.downloadBlockerMessage
            }
        }
    }

    @ViewBuilder
    private var engineAssetsBusyControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            switch engineInstaller.phase {
            case .downloading:
                if let fraction = engineInstaller.progress {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text(verbatim: downloadProgressLabel(fraction))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                }
                Text("Downloading…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                Button("Cancel") { engineInstaller.cancel() }
                    .adaptiveGlassButton(.regular, size: .small).fixedSize()
            case .pruning:
                ProgressView().controlSize(.small)
                Text("Finishing…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var engineAssetsManagedControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if engineInstaller.updateAvailable {
                Button("Update") { preflightThen { engineInstaller.download(using: doctorService) } }
                    .adaptiveGlassButton(.prominent, size: .small).fixedSize()
            } else {
                Button("Check for updates") { preflightThen { engineInstaller.checkForUpdate(using: doctorService) } }
                    .adaptiveGlassButton(.regular, size: .small).fixedSize()
            }
            Button {
                revealEngineAssetsInFinder()
            } label: {
                Image(systemName: "folder")
            }
            .adaptiveGlassButton(.regular, size: .small).fixedSize()
            .help(Text("Show the Wallpaper Engine assets folder in Finder"))
            .accessibilityLabel(Text("Show assets in Finder"))

            Button("Remove", role: .destructive) { showingRemoveConfirm = true }
                .adaptiveGlassButton(.regular, size: .small).fixedSize()
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text("Delete the downloaded Wallpaper Engine assets and unlink"))
                .confirmationDialog(
                    Text("Remove Wallpaper Engine assets?"),
                    isPresented: $showingRemoveConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) { engineInstaller.remove() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes the downloaded assets from this Mac. You can download them again anytime.")
                }
        }
    }

    @ViewBuilder
    private var engineAssetsManualControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button("Change") { Task { await requestManualEngineAssetsAccess() } }
                .adaptiveGlassButton(.regular, size: .small).fixedSize()
                .help(Text("Pick a different Wallpaper Engine install folder"))
            Button("Forget", role: .destructive) {
                engineAssets.clearAccess()
                engineInstaller.clearTransientStatus()
            }
                .adaptiveGlassButton(.regular, size: .small).fixedSize()
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text("Remove access to the Wallpaper Engine install folder"))
        }
    }

    @ViewBuilder
    private var engineAssetsUnlinkedControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button("Download from Steam") {
                preflightThen { engineInstaller.download(using: doctorService) }
            }
            .adaptiveGlassButton(.regular, size: .small).fixedSize()
            .help(Text("Download the copy of Wallpaper Engine you own for extra scene coverage"))
            Button("Link folder…") { Task { await requestManualEngineAssetsAccess() } }
                .adaptiveGlassButton(.regular, size: .small).fixedSize()
                .help(Text("Grant read-only access to a Wallpaper Engine install for extra scene coverage"))
        }
    }

    private func requestManualEngineAssetsAccess() async {
        if await engineAssets.requestAccess() {
            engineInstaller.refreshManagedInstallState()
            engineInstaller.clearTransientStatus()
        }
    }

    private var showsEngineDownloadHint: Bool {
        !engineInstaller.isBusy
            && !engineInstaller.hasManagedInstall
            && !engineAssets.isAuthorized
            && !doctorService.isDownloadReady
    }

    private struct EngineAssetsStatusLine {
        let message: String
        let tint: Color
    }

    private var engineAssetsStatusLine: EngineAssetsStatusLine? {
        if let blockedActionMessage {
            return EngineAssetsStatusLine(message: blockedActionMessage, tint: DesignTokens.Colors.Status.warning)
        }
        if case .failed(let message) = engineInstaller.phase {
            return EngineAssetsStatusLine(message: message, tint: DesignTokens.Colors.Status.danger)
        }
        if preflightingDoctor {
            return EngineAssetsStatusLine(
                message: String(localized: "Checking SteamCMD readiness before downloading.", comment: "Engine-assets settings status while preflighting SteamCMD."),
                tint: .secondary
            )
        }
        switch engineInstaller.phase {
        case .downloading:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloading Wallpaper Engine, then Loomscreen will keep only the assets folder and link it automatically.", comment: "Engine-assets settings status while downloading."),
                tint: .secondary
            )
        case .pruning:
            return EngineAssetsStatusLine(
                message: String(localized: "Download finished. Keeping the assets folder and linking it now.", comment: "Engine-assets settings status while pruning the downloaded WPE app."),
                tint: .secondary
            )
        case .checking:
            return EngineAssetsStatusLine(
                message: String(localized: "Checking Steam for the latest Wallpaper Engine build.", comment: "Engine-assets settings status while checking for updates."),
                tint: .secondary
            )
        case .idle, .failed:
            break
        }
        if let error = engineAssets.lastError {
            return EngineAssetsStatusLine(message: error, tint: DesignTokens.Colors.Status.danger)
        }
        if engineInstaller.hasManagedInstall {
            return managedEngineAssetsStatusLine
        }
        if engineAssets.isAuthorized {
            let name = engineAssets.engineRootDisplayName ?? String(
                localized: "selected folder",
                comment: "Fallback display name for a manually linked engine-assets folder."
            )
            return EngineAssetsStatusLine(
                message: String(localized: "Linked to \(name) for extra scene coverage.", comment: "Engine-assets settings status for a manually linked folder."),
                tint: DesignTokens.Colors.Status.active
            )
        }
        if showsEngineDownloadHint {
            return EngineAssetsStatusLine(
                message: String(localized: "Steam downloads need Loomscreen's background connector. You can still link an existing folder manually.", comment: "Engine-assets settings status when the Steam download connector is unavailable."),
                tint: .secondary
            )
        }
        return EngineAssetsStatusLine(
            message: String(localized: "Not linked. Most scenes still use Loomscreen's built-in equivalents.", comment: "Engine-assets settings status when no engine assets are linked."),
            tint: .secondary
        )
    }

    private var managedEngineAssetsStatusLine: EngineAssetsStatusLine {
        switch engineInstaller.updateCheckOutcome {
        case .available:
            return EngineAssetsStatusLine(
                message: String(localized: "Update available on Steam. Current downloaded assets are still linked.", comment: "Engine-assets settings status when an update is available."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .upToDate:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked and up to date.", comment: "Engine-assets settings status when downloaded assets are current."),
                tint: DesignTokens.Colors.Status.active
            )
        case .unableToCompare:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked, but their version is unknown. Download again to refresh them.", comment: "Engine-assets settings status when installed build id is unknown."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .checkFailed:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked. Couldn't check Steam for updates.", comment: "Engine-assets settings status when update check fails."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .checking:
            return EngineAssetsStatusLine(
                message: String(localized: "Checking Steam for the latest Wallpaper Engine build.", comment: "Engine-assets settings status while checking for updates."),
                tint: .secondary
            )
        case .notChecked:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked for extra scene coverage.", comment: "Engine-assets settings status for downloaded assets before checking updates."),
                tint: DesignTokens.Colors.Status.active
            )
        }
    }

    // MARK: - Title status badges (uniform icon-only seals next to each name)

    private var keyTitleBadge: SettingRowTitleBadge {
        workshopServices.hasWebAPIKey
            ? SettingRowTitleBadge(systemImage: "checkmark.seal.fill", tint: DesignTokens.Colors.Status.active, accessibilityLabel: Text("Set"))
            : SettingRowTitleBadge(systemImage: "exclamationmark.triangle.fill", tint: DesignTokens.Colors.Status.warning, accessibilityLabel: Text("Not set"))
    }

    private var doctorTitleBadge: SettingRowTitleBadge? {
        if doctorService.workdirBookmarkData == nil {
            return SettingRowTitleBadge(systemImage: "exclamationmark.triangle.fill", tint: DesignTokens.Colors.Status.warning, accessibilityLabel: Text("Steam Library authorization required"))
        }
        return SettingRowTitleBadge(systemImage: "externaldrive.badge.checkmark", tint: DesignTokens.Colors.Status.active, accessibilityLabel: Text("Steam Library connected"))
    }

    private var steamConnectionSubtitle: LocalizedStringKey {
        if doctorService.workdirBookmarkData == nil {
            return "Authorize your official Steam Library to read installed items"
        }
        return "Official library connected — SteamCMD downloads await the background connector"
    }

    private var engineTitleBadge: SettingRowTitleBadge? {
        if engineInstaller.updateAvailable {
            return SettingRowTitleBadge(systemImage: "arrow.down.circle.fill", tint: DesignTokens.Colors.Status.warning, accessibilityLabel: Text("Update available"))
        }
        if engineInstaller.hasManagedInstall || engineAssets.isAuthorized {
            return SettingRowTitleBadge(systemImage: "checkmark.seal.fill", tint: DesignTokens.Colors.Status.active, accessibilityLabel: Text("Linked"))
        }
        return nil
    }

}
#endif
