#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Direct-Pro first-run Workshop setup, drawn as a dependency tree — capabilities
/// are folders, setup steps are files inside, indent = parallel groups.
///   Download wallpapers ← SteamCMD → library folder → sign-in
///   Scene resources     ← link a folder, or download (needs the group above + an account owning Wallpaper Engine)
///   Steam Web API key   ← optional, last: only improves browsing
/// Scenes PLAY without any of this (a missing install just skips layers), so nothing gates Continue. Every row acts
/// in place; replaced a "Steam connection" sheet that stacked modal-on-modal and let its duplicate of these three steps drift.
struct OnboardingWorkshopSetupView: View {
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var controller

    let continueAction: () -> Void

    @State private var showingKeyEntry = false
    @State private var showingSetupSheet = false
    @State private var showingSignIn = false
    @State private var showingPrivacy = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            VStack(spacing: DesignTokens.Spacing.md) {
                Text("Set Up Steam Workshop")
                    .font(DesignTokens.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("None of this is required to start. Set up only the parts you want — the rest can wait until Settings.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                downloadGroup
                sceneResourcesGroup
                apiKeyGroup
            }
            .padding(DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            )

            // Both slots: the scene-resources preflight writes its own, and
            // rendering only the connection one left a failed download looking
            // like a click that never happened.
            if let message = controller.setupError ?? controller.engineAssetsError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The settings page lists these statements as a section; onboarding
            // cannot reach Settings, so the same words get a presenter here.
            Button { showingPrivacy = true } label: {
                Label {
                    Text("Privacy & terms")
                } icon: {
                    Image(systemName: "hand.raised")
                }
                .font(DesignTokens.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button(action: continueAction) {
                Text("Continue")
                    .frame(minWidth: 140)
            }
            .buttonStyle(CapsuleButtonStyle(preset: .large))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .sheet(isPresented: $showingKeyEntry) {
            AppLanguageScope(defaults: .appScoped()) {
                SteamWebAPIKeyEntrySheet(services: services) {
                    Task { await services.refreshAPIKeyStatus() }
                }
            }
        }
        .sheet(isPresented: $showingSetupSheet) {
            AppLanguageScope(defaults: .appScoped()) {
                SteamCMDSetupSheet(onConfirmManagedInstall: { controller.runManagedInstall() })
            }
        }
        .sheet(isPresented: $showingSignIn) {
            AppLanguageScope(defaults: .appScoped()) {
                SteamSignInSheet { accountName in
                    controller.adoptSignedInAccount(accountName)
                }
            }
        }
        .sheet(isPresented: $showingPrivacy) {
            AppLanguageScope(defaults: .appScoped()) {
                WorkshopPrivacySheet()
            }
        }
        .task {
            await services.refreshAPIKeyStatus()
            await controller.prepare()
        }
    }

    // MARK: - Download wallpapers

    @ViewBuilder
    private var downloadGroup: some View {
        TreeGroupHeader(title: "Download wallpapers", state: downloadGroupState)

        TreeRow(
            isLast: false,
            icon: "terminal",
            title: "SteamCMD",
            detail: controller.steamCMDDetail,
            state: controller.steamCMDState,
            info: "Valve's command-line downloader. Loomscreen can install its own copy, or locate an existing verified Homebrew or tarball install."
        ) {
            WorkshopSetupRoutes(
                // "Change" points at a different SteamCMD; it must NOT open the
                // install sheet, whose primary action downloads a second managed
                // copy and displaces the Homebrew or hand-picked one already in
                // use. Same split as the settings page.
                primary: doctor.isBinaryPresumedReady
                    ? WorkshopSetupRoute(id: "steamcmd.change", title: "Change") {
                        Task { await controller.pickBinaryManually() }
                    }
                    : WorkshopSetupRoute(id: "steamcmd.setup", title: "Set up SteamCMD") {
                        showingSetupSheet = true
                    },
                secondary: doctor.isBinaryPresumedReady ? [] : [
                    WorkshopSetupRoute(id: "steamcmd.locate", title: "Locate automatically") {
                        controller.autoDetectBinary()
                    }
                ],
                isBusy: controller.isSteamCMDBusy,
                emphasizesPrimary: !doctor.isBinaryPresumedReady
            )
            .controlSize(.small)
        }

        TreeRow(
            isLast: false,
            icon: "externaldrive",
            title: "Steam library",
            detail: controller.libraryDetail,
            state: doctor.libraryStepState,
            info: "Loomscreen reads installed Workshop items directly from the official Steam library after one folder authorization. macOS only grants that through a panel you confirm, so even a folder Loomscreen already located needs one click."
        ) {
            WorkshopSetupRoutes(
                primary: libraryRoute,
                secondary: librarySecondaryRoutes,
                emphasizesPrimary: !doctor.isLibraryReady
            )
            .controlSize(.small)
        }

        TreeRow(
            isLast: true,
            icon: "person.badge.key",
            title: "Steam account",
            detail: controller.accountDetail,
            state: doctor.accountStepState,
            info: "Downloads sign in as your own Steam account through SteamCMD. Loomscreen lists the accounts Steam has already signed in on this Mac; it never stores your password."
        ) {
            accountControl
        }
    }

    private var libraryRoute: WorkshopSetupRoute {
        if doctor.isLibraryReady {
            return WorkshopSetupRoute(id: "library.change", title: "Change") {
                Task { await controller.authorizeSteamLibrary(startingAtScannedPath: false) }
            }
        }
        if controller.hasScannedLibrary {
            return WorkshopSetupRoute(id: "library.authorize", title: "Authorize this location") {
                Task { await controller.authorizeSteamLibrary(startingAtScannedPath: true) }
            }
        }
        return WorkshopSetupRoute(id: "library.choose", title: "Choose folder…") {
            Task { await controller.authorizeSteamLibrary(startingAtScannedPath: false) }
        }
    }

    /// The located folder can be the wrong one — a second Steam library, or a
    /// leftover profile — so the manual route stays reachable here too.
    private var librarySecondaryRoutes: [WorkshopSetupRoute] {
        guard !doctor.isLibraryReady, controller.hasScannedLibrary else { return [] }
        return [
            WorkshopSetupRoute(id: "library.other", title: "Choose another folder…") {
                Task { await controller.authorizeSteamLibrary(startingAtScannedPath: false) }
            }
        ]
    }

    /// A chooser is a menu, so switching accounts stays one even here; signing
    /// in to a new one is the button beside it.
    @ViewBuilder
    private var accountControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if !controller.discoveredAccounts.isEmpty {
                Menu {
                    steamAccountMenuItems(
                        accounts: controller.discoveredAccounts,
                        current: doctor.username,
                        onSelect: controller.selectAccount,
                        onSignIn: { showingSignIn = true },
                        onRescan: { Task { await controller.loadAccounts() } }
                    )
                } label: {
                    Text(doctor.username == nil ? "Choose account" : "Switch account")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }

            Button("Sign in to a new account") { showingSignIn = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
        }
    }

    private var downloadGroupState: WorkshopStepState {
        controller.isSteamCMDBusy ? .working : doctor.connectionStepState
    }

    // MARK: - Scene resources

    @ViewBuilder
    private var sceneResourcesGroup: some View {
        TreeGroupHeader(title: "Scene resources", state: controller.engineAssetsState)
            .padding(.top, DesignTokens.Spacing.xs)

        TreeRow(
            isLast: true,
            icon: "shippingbox",
            title: "Wallpaper Engine assets",
            detail: sceneResourcesDetail,
            info: "Scenes reference textures, shaders and models that ship with Wallpaper Engine rather than with the scene. Loomscreen bundles clean-room equivalents of the most common ones, but the rest are skipped without an install — the scene still renders, so the loss is silent. Read-only access; no files are modified."
        ) {
            WorkshopSetupRoutes(
                primary: sceneResourcesPrimaryRoute,
                secondary: sceneResourcesSecondaryRoutes,
                isBusy: controller.engineInstaller.isBusy || controller.isPreflightingDownload,
                emphasizesPrimary: !controller.hasEngineAssets
            )
            .controlSize(.small)
        }
    }

    private var sceneResourcesPrimaryRoute: WorkshopSetupRoute {
        if controller.hasEngineAssets {
            return WorkshopSetupRoute(id: "assets.change", title: "Change") {
                Task { await controller.linkEngineAssetsFolder() }
            }
        }
        return WorkshopSetupRoute(
            id: "assets.download",
            title: "Download automatically",
            unavailableReason: controller.engineAssetsDownloadBlockReason
        ) {
            controller.downloadEngineAssets()
        }
    }

    private var sceneResourcesSecondaryRoutes: [WorkshopSetupRoute] {
        guard !controller.hasEngineAssets else { return [] }
        return [
            WorkshopSetupRoute(id: "assets.link", title: "Link manually") {
                Task { await controller.linkEngineAssetsFolder() }
            }
        ]
    }

    private var sceneResourcesDetail: String {
        if controller.engineInstaller.isBusy {
            return String(localized: "Downloading from Steam…", bundle: .appLanguage, comment: "Onboarding engine-assets step detail while the download runs.")
        }
        if controller.hasEngineAssets {
            return controller.engineAssets.engineRootDisplayName
                ?? String(localized: "Ready", bundle: .appLanguage, comment: "Onboarding engine-assets step detail when the assets are available.")
        }
        // The blocked reason belongs on the line, not only in the disabled
        // button's tooltip: a dimmed control is exactly what a pointer skips.
        if let reason = controller.engineAssetsDownloadBlockReason {
            return reason
        }
        return String(
            localized: "Download the copy you own, or link an install you already have",
            bundle: .appLanguage, comment: "Onboarding scene-resources detail naming the two routes."
        )
    }

    // MARK: - Steam Web API key

    /// Last, and without a group badge: this one is genuinely optional, and a
    /// "Not set" seal beside it read as a third thing left undone.
    @ViewBuilder
    private var apiKeyGroup: some View {
        TreeGroupHeader(title: "Steam Web API key", state: apiKeyState, isOptional: true)
            .padding(.top, DesignTokens.Spacing.xs)

        TreeRow(
            isLast: true,
            icon: "key",
            title: "Steam Web API key",
            detail: apiKeyDetail,
            info: "The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS, and the key is stored only on this Mac (no iCloud sync). Browsing works without it; adding one brings ratings, authors and faster search."
        ) {
            WorkshopSetupRoutes(
                primary: WorkshopSetupRoute(
                    id: "apiKey.set",
                    title: services.hasWebAPIKey ? "Replace" : "Set key"
                ) { showingKeyEntry = true }
            )
            .controlSize(.small)
        }
    }

    private var apiKeyState: WorkshopStepState {
        guard services.hasWebAPIKey else { return .notStarted }
        return services.apiKeyRejected ? .attention : .ready
    }

    private var apiKeyDetail: String {
        services.hasWebAPIKey
            ? String(localized: "Ready", bundle: .appLanguage, comment: "Workshop setup status when a Steam Web API key exists.")
            : String(localized: "Optional — adds ratings, authors and faster search", bundle: .appLanguage, comment: "Workshop settings subtitle for Steam Web API key.")
    }
}

// MARK: - Tree furniture

/// Capability name + one status badge. The badge lives here rather than on the
/// rows: a group is done when its capability works, however many paths lead in.
private struct TreeGroupHeader: View {
    let title: LocalizedStringKey
    let state: WorkshopStepState
    /// Optional groups say so instead of showing "Not set", which reads as a
    /// chore left undone.
    var isOptional = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.bodyEmphasized)
            if isOptional, state == .notStarted {
                Text("Optional")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                WorkshopStateBadge(state: state)
            }
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
                    Text(title)
                        .font(DesignTokens.Typography.body)
                    if let state {
                        Circle()
                            .fill(state.tint)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel(Text(state.statusText))
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
