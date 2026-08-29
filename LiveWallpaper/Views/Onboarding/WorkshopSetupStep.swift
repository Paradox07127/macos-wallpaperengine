#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Direct-Pro first-run Workshop setup, drawn as a dependency tree.
///
/// The old layout was four flat rows, which read as four independent chores —
/// and its subtitle even claimed all four were required. They aren't: they form
/// two short chains and one side door. Capabilities are the folders, setup
/// steps are the files inside, so parallel groups sit at the same indent and
/// order-within-a-group reads top-down:
///
///   Browse the Workshop      ← API key, nothing else
///   Download wallpapers      ← SteamCMD, then sign-in
///   Every scene layer        ← link a folder (zero requirements), or
///                              download via the group above (account must own WPE)
///
/// Scenes PLAY without any of this — a missing assets install only skips the
/// layers it would have supplied — so nothing here gates Continue.
struct OnboardingWorkshopSetupView: View {
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor

    let continueAction: () -> Void

    @State private var installer = SteamCMDManagedInstallCoordinator.shared
    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var showingKeyEntry = false
    @State private var showingConnection = false
    @State private var showingInstallConsent = false
    @State private var setupError: String?
    @State private var isVerifyingInstall = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text("Set Up Steam Workshop")
                    .font(DesignTokens.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Each group unlocks one capability. Set up what you want — everything can be finished later in Settings.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                TreeGroupHeader(title: "Browse the Workshop", state: apiKeyState)
                TreeRow(
                    isLast: true,
                    icon: "key",
                    title: "Steam Web API key",
                    detail: apiKeyDetail,
                    info: "The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS, and the key is stored only on this Mac (no iCloud sync). Get one free at steamcommunity.com/dev/apikey."
                ) {
                    if services.hasWebAPIKey {
                        Button("Replace") { showingKeyEntry = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Set key") { showingKeyEntry = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                TreeGroupHeader(title: "Download wallpapers", state: downloadGroupState)
                    .padding(.top, DesignTokens.Spacing.xs)
                // Three rows, not two pointing at one sheet: signing in is its
                // own signal and was invisible while it sat two levels down
                // inside the connection sheet.
                TreeRow(
                    isLast: false,
                    icon: "terminal",
                    title: "SteamCMD",
                    detail: steamCMDDetail,
                    state: steamCMDState,
                    info: "Valve's command-line downloader. Loomscreen can install it for you or locate an existing verified Homebrew or tarball install."
                ) {
                    steamCMDControl
                }
                TreeRow(
                    isLast: false,
                    icon: "externaldrive",
                    title: "Steam library",
                    detail: doctor.workdirDisplayPath
                        ?? String(localized: "Not authorized", comment: "Steam library step detail when no folder has been picked."),
                    state: doctor.libraryStepState,
                    info: "Loomscreen reads installed Workshop items directly from the official Steam library after one folder authorization. The sandbox cannot grant this itself — the panel opens on Steam's default location so it is one click."
                ) {
                    Button("Configure") { showingConnection = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                TreeRow(
                    isLast: true,
                    icon: "person.badge.key",
                    title: "Steam account",
                    detail: accountDetail,
                    state: doctor.accountStepState,
                    info: "Downloads sign in as your own Steam account through SteamCMD. Loomscreen lists the accounts Steam has already signed in on this Mac; it never stores your password."
                ) {
                    Button("Sign in") { showingConnection = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                TreeGroupHeader(title: "Every scene layer", state: engineAssetsState)
                    .padding(.top, DesignTokens.Spacing.xs)
                if hasEngineAssets {
                    TreeRow(
                        isLast: true,
                        icon: "shippingbox",
                        title: "Wallpaper Engine assets",
                        detail: engineAssets.engineRootDisplayName
                            ?? String(localized: "Ready", comment: "Onboarding engine-assets step detail when the assets are available.")
                    ) {
                        Button("Change") { Task { await linkEngineAssetsFolder() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else {
                    TreeRow(
                        isLast: false,
                        icon: "folder",
                        title: "Link an existing install",
                        detail: String(localized: "No sign-in needed — read-only access to a Wallpaper Engine folder", comment: "Onboarding engine-assets link-folder path detail: this path has no prerequisites.")
                    ) {
                        Button("Link folder…") { Task { await linkEngineAssetsFolder() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    TreeRow(
                        isLast: true,
                        icon: "arrow.down.circle",
                        title: "Download from Steam",
                        detail: assetsDownloadDetail
                    ) {
                        if engineInstaller.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Download") { engineInstaller.download(using: doctor) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!doctor.isDownloadReady)
                        }
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            )

            if let setupError {
                Label(setupError, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Button(action: continueAction) {
                    Text("Continue")
                        .frame(minWidth: 140)
                }
                .buttonStyle(CapsuleButtonStyle(preset: .large))
                .keyboardShortcut(.defaultAction)

                // Same action as Continue — it exists to say out loud that
                // nothing on this page is required.
                Button(action: continueAction) {
                    Text("Skip for Now", comment: "Secondary onboarding action that defers wallpaper setup.")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .sheet(isPresented: $showingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: services) {
                Task { await services.refreshAPIKeyStatus() }
            }
        }
        .sheet(isPresented: $showingConnection) {
            WorkshopDoctorView()
                .environment(doctor)
        }
        .sheet(isPresented: $showingInstallConsent) {
            SteamCMDManagedInstallSheet(onConfirm: runManagedInstall)
        }
        .task {
            await services.refreshAPIKeyStatus()
            await doctor.autoConfigureIfNeeded()
            engineInstaller.refreshManagedInstallState()
        }
    }

    // MARK: - Group states

    private var apiKeyState: WorkshopStepState {
        guard services.hasWebAPIKey else { return .notStarted }
        return services.apiKeyRejected ? .attention : .ready
    }

    private var apiKeyDetail: String {
        services.hasWebAPIKey
            ? String(localized: "Ready", comment: "Workshop setup status when a Steam Web API key exists.")
            : String(localized: "Your own free key — unlocks the full native search", comment: "Workshop settings subtitle for Steam Web API key.")
    }

    private var downloadGroupState: WorkshopStepState {
        isSteamCMDBusy ? .working : doctor.connectionStepState
    }

    private var engineAssetsState: WorkshopStepState {
        .engineAssets(library: engineAssets, installer: engineInstaller)
    }

    private var hasEngineAssets: Bool {
        WorkshopStepState.hasEngineAssets(library: engineAssets, installer: engineInstaller)
    }

    private var accountDetail: String {
        doctor.username
            ?? String(localized: "Not signed in", comment: "Onboarding Steam account row detail when no account is selected.")
    }

    private var assetsDownloadDetail: String {
        if engineInstaller.isBusy {
            return String(localized: "Downloading from Steam…", comment: "Onboarding engine-assets step detail while the download runs.")
        }
        if doctor.isDownloadReady {
            return String(localized: "Your Steam account must own Wallpaper Engine.", comment: "Onboarding engine-assets download-path detail once the Download group is ready.")
        }
        return String(localized: "Ready once the Download group above is — the account must own Wallpaper Engine.", comment: "Onboarding engine-assets download-path detail while its prerequisites are missing.")
    }

    // MARK: - SteamCMD

    @ViewBuilder
    private var steamCMDControl: some View {
        if isSteamCMDBusy {
            ProgressView().controlSize(.small)
        } else if isSteamCMDReady {
            Button("Configure") { showingConnection = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            Button("Install SteamCMD…") { showingInstallConsent = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var steamCMDState: WorkshopStepState {
        if isSteamCMDBusy { return .working }
        if isSteamCMDReady { return .ready }
        if case .failed = installer.status { return .attention }
        return .notStarted
    }

    private var isSteamCMDReady: Bool {
        doctor.hasBoundBinary && doctor.isGreen(.binaryIdentity)
    }

    private var isSteamCMDBusy: Bool {
        if isVerifyingInstall { return true }
        switch installer.status {
        case .installing, .removing: return true
        case .idle, .installed, .failed: return false
        }
    }

    private var steamCMDDetail: String {
        switch installer.status {
        case .installing:
            return String(localized: "Setting up SteamCMD…", comment: "SteamCMD step detail while the connector unpacks and verifies the install.")
        case .removing:
            return String(localized: "Removing SteamCMD…", comment: "SteamCMD step detail while the connector deletes the managed install.")
        case .idle, .installed, .failed:
            if isVerifyingInstall {
                return String(localized: "Checking that SteamCMD runs…", comment: "SteamCMD step detail while the connector launches the freshly installed binary to confirm it works.")
            }
            return doctor.binaryDisplayPath
                ?? String(localized: "Not selected", comment: "SteamCMD step detail when no binary is bound.")
        }
    }

    private func runManagedInstall() {
        setupError = nil
        Task {
            switch await installer.install() {
            case .installed:
                isVerifyingInstall = true
                let bound = await doctor.autoDetectBinary()
                isVerifyingInstall = false
                if !bound {
                    setupError = String(
                        localized: "SteamCMD was installed but could not be started.",
                        comment: "Workshop setup error after a managed SteamCMD install that will not launch."
                    )
                }
            case .failed(let reason):
                setupError = reason
            case .idle, .installing, .removing:
                break
            }
        }
    }

    private func linkEngineAssetsFolder() async {
        setupError = nil
        if await engineAssets.requestAccess() {
            engineInstaller.refreshManagedInstallState()
            engineInstaller.clearTransientStatus()
        }
    }
}

// MARK: - Tree furniture

/// Capability name + one status badge. The badge lives here rather than on the
/// rows: a group is done when its capability works, however many paths lead in.
private struct TreeGroupHeader: View {
    let title: LocalizedStringKey
    let state: WorkshopStepState

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title, bundle: .main)
                .font(DesignTokens.Typography.bodyEmphasized)
            WorkshopStateBadge(state: state)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One setup step inside a group: connector, icon, title/detail, control.
/// Compact on purpose — five of these plus three headers share a 540pt window.
private struct TreeRow<Control: View>: View {
    let isLast: Bool
    let icon: String
    let title: LocalizedStringKey
    let detail: String?
    /// Set on rows that carry their own signal. The group header answers "does
    /// this capability work"; a row badge answers "is this step done", which
    /// only differs where a group has several ordered steps.
    var state: WorkshopStepState?
    var info: String.LocalizationValue?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            TreeConnector(isLast: isLast)
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(title, bundle: .main)
                        .font(DesignTokens.Typography.body)
                    if let state {
                        Circle()
                            .fill(state.tint)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel(Text(state.statusText, bundle: .main))
                    }
                    if let info {
                        InfoTooltipButton(text: info)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            control()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// File-tree guide: a vertical rail with a stub into the row. `isLast` ends the
/// rail at the stub (└) instead of running through (├).
private struct TreeConnector: View {
    let isLast: Bool

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let x: CGFloat = 5
                let midY = geo.size.height / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: isLast ? midY : geo.size.height))
                path.move(to: CGPoint(x: x, y: midY))
                path.addLine(to: CGPoint(x: geo.size.width, y: midY))
            }
            .stroke(DesignTokens.Colors.separator, lineWidth: 1)
        }
        .frame(width: 14)
        .accessibilityHidden(true)
    }
}
#endif
