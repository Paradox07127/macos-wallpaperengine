#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

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
        VStack(spacing: DesignTokens.Spacing.xl) {
            VStack(spacing: DesignTokens.Spacing.md) {
                Text("Set Up Steam Workshop")
                    .font(DesignTokens.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Setup can be completed later in Settings.")
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

            // Both slots: the scene-resources preflight writes its own, and rendering only the
            // connection one would leave a failed download looking like a click that did nothing.
            if let message = controller.setupError ?? controller.engineAssetsError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
        .infoOverlay(isPresented: $showingPrivacy) { dismiss in
            AppLanguageScope(defaults: .appScoped()) {
                WorkshopPrivacySheet(onDismiss: dismiss)
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
            attention: doctor.attentionMessage(for: .binaryIdentity),
            state: controller.steamCMDState,
            info: "Required to download Workshop wallpapers. Install SteamCMD or use an existing installation."
        ) {
            WorkshopSetupRoutes(
                // "Change" must NOT open the install sheet: its primary action downloads a second managed
                // copy, displacing the one already in use. Same split as the settings page.
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
            attention: doctor.attentionMessage(for: .workingDirectory),
            state: doctor.libraryStepState,
            info: "Authorize access to installed Workshop wallpapers in the Steam library."
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
            attention: doctor.attentionMessage(for: .cachedLogin),
            state: doctor.accountStepState,
            info: "Downloads use your Steam account. Loomscreen does not store the password."
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
            info: "Shared assets required by some scenes. Linked files are read-only."
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

    private var sceneResourcesDetail: String? {
        if controller.engineInstaller.isBusy {
            return String(localized: "Downloading from Steam…", bundle: .appLanguage, comment: "Onboarding engine-assets step detail while the download runs.")
        }
        if controller.hasEngineAssets {
            return controller.engineAssets.engineRootDisplayName
                ?? String(localized: "Ready", bundle: .appLanguage, comment: "Onboarding engine-assets step detail when the assets are available.")
        }
        if let reason = controller.engineAssetsDownloadBlockReason {
            return reason
        }
        return nil
    }

    // MARK: - Steam Web API key

    @ViewBuilder
    private var apiKeyGroup: some View {
        TreeGroupHeader(title: "Steam Web API key", state: apiKeyState, isOptional: true)
            .padding(.top, DesignTokens.Spacing.xs)

        TreeRow(
            isLast: true,
            icon: "key",
            title: "Steam Web API key",
            detail: apiKeyDetail,
            info: "Optional. Adds ratings, authors, and faster search. Stored only on this Mac; requests go directly to Steam."
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

    private var apiKeyDetail: String? {
        guard services.hasWebAPIKey else { return nil }
        if services.apiKeyRejected {
            return String(localized: "Steam rejected this key — paste a new one", bundle: .appLanguage, comment: "Workshop setup status when Valve rejected the stored Steam Web API key.")
        }
        return String(localized: "Ready", bundle: .appLanguage, comment: "Workshop setup status when a Steam Web API key exists.")
    }
}

// MARK: - Tree furniture

private struct TreeGroupHeader: View {
    let title: LocalizedStringKey
    let state: WorkshopStepState
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

/// Compact on purpose — five of these plus three headers share a 540pt window.
private struct TreeRow<Control: View>: View {
    let isLast: Bool
    let icon: String
    let title: LocalizedStringKey
    let detail: String?
    /// The probe's reason for an attention state.
    var attention: String?
    /// Set only on rows that carry their own signal; otherwise the group header answers.
    var state: WorkshopStepState?
    var info: String.LocalizationValue?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            TreeConnector(isLast: isLast)
            Image(systemName: icon)
                .font(DesignTokens.Typography.body)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text(verbatim: detail))
                }
                if let attention {
                    Text(attention)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            control()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `isLast` ends the rail at the stub (└) instead of running through (├).
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
