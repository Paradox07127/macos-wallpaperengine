#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Linking or downloading a Wallpaper Engine install for the assets some
/// scenes reference.
/// The download progress gets a row of its own here: a multi-GB bar squeezed into the
/// trailing slot next to three buttons was the one place this page ran out of width.
struct WorkshopEngineAssetsSection: View {
    @Environment(WorkshopSetupController.self) private var controller

    @AppStorage("loomscreen.workshop.checkAssetsUpdateAtLaunch.v1", store: .appScoped()) private var checksAssetsUpdateAtLaunch = false

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var showingRemoveConfirm = false

    var body: some View {
        Section {
            SettingRow(
                icon: "shippingbox",
                iconColor: .brown,
                title: "Wallpaper Engine assets",
                subtitle: engineAssetsSubtitle,
                info: "Scenes reference textures, shaders and models that ship with Wallpaper Engine rather than with the scene. Loomscreen bundles clean-room equivalents of the most common ones, but the rest are skipped without an install — the scene still renders, so the loss is silent. Read-only access; no files are modified."
            ) {
                engineAssetsControl
                    .frame(maxHeight: 24)
            }
            .task {
                engineInstaller.refreshManagedInstallState()
            }

            if let fraction = downloadFraction {
                downloadProgressRow(fraction)
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
            SettingsSearchSectionHeader("Scene resources", anchor: .workshopAssets)
        }
    }

    private var engineAssetsSubtitle: LocalizedStringKey {
        engineInstaller.hasManagedInstall || engineAssets.isAuthorized
            ? "Linked — scenes can use Wallpaper Engine's shared assets"
            : "Required for full scene support — download or link an install"
    }

    // MARK: - Download progress

    /// Only the determinate download has its own row; the short indeterminate
    /// phases stay in the trailing slot where a spinner costs nothing.
    private var downloadFraction: Double? {
        guard engineInstaller.isBusy, case .downloading = engineInstaller.phase else { return nil }
        return engineInstaller.progress
    }

    private func downloadProgressRow(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(verbatim: downloadProgressLabel(fraction))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)

                Spacer(minLength: DesignTokens.Spacing.sm)

                Button("Cancel") { engineInstaller.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Downloading Wallpaper Engine assets"))
        .accessibilityValue(Text(verbatim: downloadProgressLabel(fraction)))
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

    // MARK: - Controls

    @ViewBuilder
    private var engineAssetsControl: some View {
        if controller.isPreflightingDownload {
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

    @ViewBuilder
    private var engineAssetsBusyControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            switch engineInstaller.phase {
            case .downloading:
                // The bar and its numbers live on their own row; anything left
                // here would only duplicate them.
                if engineInstaller.progress == nil {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                    Button("Cancel") { engineInstaller.cancel() }
                        .fixedSize()
                }
            case .pruning:
                ProgressView().controlSize(.small)
                Text("Finishing…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                Button("Cancel") { engineInstaller.cancel() }
                    .fixedSize()
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var engineAssetsManagedControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if engineInstaller.updateAvailable {
                Button("Update") { controller.downloadEngineAssets() }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            } else {
                Button("Check for updates") { controller.checkEngineAssetsUpdate() }
                    .fixedSize()
            }
            Button {
                revealEngineAssetsInFinder()
            } label: {
                Image(systemName: "folder")
            }
            .fixedSize()
            .help(Text("Show the Wallpaper Engine assets folder in Finder"))
            .accessibilityLabel(Text("Show assets in Finder"))

            Button("Remove", role: .destructive) { showingRemoveConfirm = true }
                .fixedSize()
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
            Button("Change") { Task { await controller.linkEngineAssetsFolder() } }
                .fixedSize()
                .help(Text("Pick a different Wallpaper Engine install folder"))
            Button("Forget", role: .destructive) {
                engineAssets.clearAccess()
                engineInstaller.clearTransientStatus()
            }
                .fixedSize()
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text("Remove access to the Wallpaper Engine install folder"))
        }
    }

    /// The same two routes the onboarding step offers, in the same order:
    /// download the copy you own, or point at one you already have.
    private var engineAssetsUnlinkedControl: some View {
        WorkshopSetupRoutes(
            primary: WorkshopSetupRoute(
                id: "assets.download",
                title: "Download automatically",
                unavailableReason: controller.engineAssetsDownloadBlockReason
            ) { controller.downloadEngineAssets() },
            secondary: [
                WorkshopSetupRoute(id: "assets.link", title: "Link manually") {
                    Task { await controller.linkEngineAssetsFolder() }
                }
            ],
            emphasizesPrimary: true
        )
    }

    private func revealEngineAssetsInFinder() {
        guard let root = WPEEngineAssetsLibrary.managedInstallRoot() ?? engineAssets.resolveAuthorizedRoot() else { return }
        // Steam-folder path: needs the same security scope as other library reads.
        let scope = root.startAccessingSecurityScopedResource()
        defer { if scope { root.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - Status line

    private struct EngineAssetsStatusLine {
        let message: String
        let tint: Color
    }

    private var engineAssetsStatusLine: EngineAssetsStatusLine? {
        if let engineAssetsError = controller.engineAssetsError {
            return EngineAssetsStatusLine(message: engineAssetsError, tint: DesignTokens.Colors.Status.warning)
        }
        if case .failed(let message) = engineInstaller.phase {
            return EngineAssetsStatusLine(message: message, tint: DesignTokens.Colors.Status.danger)
        }
        if controller.isPreflightingDownload {
            return EngineAssetsStatusLine(
                message: String(localized: "Checking SteamCMD readiness before downloading.", bundle: .appLanguage, comment: "Engine-assets settings status while preflighting SteamCMD."),
                tint: .secondary
            )
        }
        switch engineInstaller.phase {
        case .downloading:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloading Wallpaper Engine, then Loomscreen will keep only the assets folder and link it automatically.", bundle: .appLanguage, comment: "Engine-assets settings status while downloading."),
                tint: .secondary
            )
        case .pruning:
            return EngineAssetsStatusLine(
                message: String(localized: "Download finished. Keeping the assets folder and linking it now.", bundle: .appLanguage, comment: "Engine-assets settings status while pruning the downloaded WPE app."),
                tint: .secondary
            )
        case .checking:
            return EngineAssetsStatusLine(
                message: String(localized: "Checking Steam for the latest Wallpaper Engine build.", bundle: .appLanguage, comment: "Engine-assets settings status while checking for updates."),
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
                bundle: .appLanguage, comment: "Fallback display name for a manually linked engine-assets folder."
            )
            return EngineAssetsStatusLine(
                message: String(localized: "Linked to \(name) for extra scene coverage.", bundle: .appLanguage, comment: "Engine-assets settings status for a manually linked folder."),
                tint: DesignTokens.Colors.Status.active
            )
        }
        // Names the missing prerequisite rather than the generic sentence: this
        // is also the only non-hover way to read why Download is greyed out.
        if let reason = controller.engineAssetsDownloadBlockReason, !controller.hasEngineAssets {
            return EngineAssetsStatusLine(message: reason, tint: .secondary)
        }
        return EngineAssetsStatusLine(
            message: String(localized: "Not linked. Most scenes still use Loomscreen's built-in equivalents.", bundle: .appLanguage, comment: "Engine-assets settings status when no engine assets are linked."),
            tint: .secondary
        )
    }

    private var managedEngineAssetsStatusLine: EngineAssetsStatusLine? {
        switch engineInstaller.updateCheckOutcome {
        case .available:
            return EngineAssetsStatusLine(
                message: String(localized: "Update available on Steam. Current downloaded assets are still linked.", bundle: .appLanguage, comment: "Engine-assets settings status when an update is available."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .upToDate:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked and up to date.", bundle: .appLanguage, comment: "Engine-assets settings status when downloaded assets are current."),
                tint: DesignTokens.Colors.Status.active
            )
        case .unableToCompare:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked, but their version is unknown. Download again to refresh them.", bundle: .appLanguage, comment: "Engine-assets settings status when installed build id is unknown."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .loginRequired:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked. Your Steam sign-in expired, so the version check couldn't run.", bundle: .appLanguage, comment: "Engine-assets settings status when Steam refused the cached session during an update check."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .checkFailed:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked. Couldn't check Steam for updates.", bundle: .appLanguage, comment: "Engine-assets settings status when update check fails."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .checking:
            return EngineAssetsStatusLine(
                message: String(localized: "Checking Steam for the latest Wallpaper Engine build.", bundle: .appLanguage, comment: "Engine-assets settings status while checking for updates."),
                tint: .secondary
            )
        case .notChecked:
            // Silent: the row's own subtitle already says the assets are
            // linked, and repeating it underneath said nothing new.
            return nil
        }
    }
}
#endif
