#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Steam setup uses the same actions and readiness model as onboarding.
struct WorkshopConnectionSetup: View {
    @Environment(SteamCMDDoctorService.self) private var service
    @Environment(WorkshopSetupController.self) private var controller

    @State private var showingSetupSheet = false
    @State private var showingSignIn = false
    @State private var showingRemoveSessionConfirm = false
    @State private var showingSubscriptionSync = false

    var body: some View {
        Section {
            libraryRow
            attentionNote(service.attentionMessage(for: .workingDirectory))
            binaryRow
            attentionNote(service.attentionMessage(for: .binaryIdentity))
            accountRow
            attentionNote(service.attentionMessage(for: .cachedLogin))
            subscriptionsRow

            if let setupError = controller.setupError {
                Label(setupError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .font(DesignTokens.Typography.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Setup error: \(setupError)"))
            }
        } header: {
            SettingsSearchSectionHeader("Steam connection", anchor: .workshopConnection)
        }
    }

    // MARK: - Steam library

    private var libraryRow: some View {
        SettingRow(
            icon: "folder",
            iconColor: .teal,
            title: "Steam library",
            valueSubtitle: controller.libraryDetail,
            titleBadge: attentionBadge(for: service.libraryStepState),
            info: "Authorize access to installed Workshop wallpapers in the Steam library."
        ) {
            WorkshopSetupRoutes(
                primary: libraryPrimaryRoute,
                secondary: librarySecondaryRoutes,
                emphasizesPrimary: !service.isLibraryReady
            )
        }
        // Keep presenters on the row so Form recognizes the Section.
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
        .sheet(isPresented: $showingSubscriptionSync) {
            AppLanguageScope(defaults: .appScoped()) {
                SubscriptionSyncSheet()
            }
        }
        .confirmationDialog(
            Text("Remove the saved Steam session?"),
            isPresented: $showingRemoveSessionConfirm,
            titleVisibility: .visible
        ) {
            // No destructive role on the confirm button: the user already
            // pressed a control labelled Remove (rules/ui-design.md).
            Button("Remove") {
                Task { await service.removeSignedInSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this account's Loomscreen download session. Reconnect before downloading again. Steam app sign-in is unaffected.")
        }
        .task { await controller.prepare() }
    }

    private var libraryPrimaryRoute: WorkshopSetupRoute {
        if service.isLibraryReady {
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

    private var librarySecondaryRoutes: [WorkshopSetupRoute] {
        guard !service.isLibraryReady, controller.hasScannedLibrary else { return [] }
        return [
            WorkshopSetupRoute(id: "library.other", title: "Choose another folder…") {
                Task { await controller.authorizeSteamLibrary(startingAtScannedPath: false) }
            }
        ]
    }

    // MARK: - SteamCMD

    private var binaryRow: some View {
        SettingRow(
            icon: "terminal",
            iconColor: .purple,
            title: "SteamCMD",
            valueSubtitle: controller.steamCMDDetail,
            titleBadge: attentionBadge(for: controller.steamCMDState),
            info: "Required to download Workshop wallpapers. Install SteamCMD or use an existing installation."
        ) {
            WorkshopSetupRoutes(
                primary: binaryPrimaryRoute,
                secondary: binarySecondaryRoutes,
                overflow: binaryOverflowRoutes,
                isBusy: controller.isSteamCMDBusy,
                emphasizesPrimary: !service.isBinaryPresumedReady
            )
        }
    }

    /// Offer setup when unbound, or replacement when an installation is already bound.
    private var binaryPrimaryRoute: WorkshopSetupRoute {
        if service.isBinaryPresumedReady {
            return WorkshopSetupRoute(id: "steamcmd.change", title: "Change") {
                Task { await controller.pickBinaryManually() }
            }
        }
        return WorkshopSetupRoute(id: "steamcmd.setup", title: "Set up SteamCMD") {
            showingSetupSheet = true
        }
    }

    private var binarySecondaryRoutes: [WorkshopSetupRoute] {
        var routes = [
            WorkshopSetupRoute(id: "steamcmd.locate", title: "Locate automatically") {
                controller.autoDetectBinary()
            }
        ]
        if service.isBinaryPresumedReady {
            routes.append(WorkshopSetupRoute(id: "steamcmd.reinstall", title: "Set up SteamCMD") {
                showingSetupSheet = true
            })
        } else {
            routes.append(WorkshopSetupRoute(id: "steamcmd.choose", title: "Choose SteamCMD") {
                Task { await controller.pickBinaryManually() }
            })
        }
        return routes
    }

    private var binaryOverflowRoutes: [WorkshopSetupRoute] {
        var routes: [WorkshopSetupRoute] = []
        if controller.hasManualBinding {
            routes.append(WorkshopSetupRoute(id: "steamcmd.forget", title: "Forget the SteamCMD I chose") {
                Task { await controller.forgetManualBinary() }
            })
        }
        if controller.hasManagedInstall {
            routes.append(WorkshopSetupRoute(
                id: "steamcmd.remove",
                title: "Remove the copy Loomscreen installed",
                role: .destructive
            ) {
                controller.removeManagedInstall()
            })
        }
        return routes
    }

    // MARK: - Steam account

    private var accountRow: some View {
        SettingRow(
            icon: "person.crop.circle",
            iconColor: .blue,
            title: "Steam account",
            valueSubtitle: controller.accountDetail,
            titleBadge: attentionBadge(for: service.accountStepState),
            info: "Downloads use your Steam account. Loomscreen does not store the password."
        ) {
            accountControl
                .fixedSize()
        }
    }

    @ViewBuilder
    private var accountControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if !controller.discoveredAccounts.isEmpty {
                Menu {
                    steamAccountMenuItems(
                        accounts: controller.discoveredAccounts,
                        current: service.username,
                        onSelect: controller.selectAccount,
                        onSignIn: { showingSignIn = true },
                        onRescan: { Task { await controller.loadAccounts() } },
                        onRemoveSession: { showingRemoveSessionConfirm = true }
                    )
                } label: {
                    Text(service.username == nil ? "Choose account" : "Switch account")
                }
                .menuStyle(.button)
                .fixedSize()
            }

            if controller.discoveredAccounts.isEmpty {
                Button("Sign in to a new account") { showingSignIn = true }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            } else {
                Button("Sign in to a new account") { showingSignIn = true }
                    .fixedSize()
            }
        }
    }

    // MARK: - Subscribed wallpapers

    private var subscriptionsRow: some View {
        SettingRow(
            icon: "arrow.down.circle",
            iconColor: .green,
            title: "Subscribed wallpapers",
            info: "Downloads missing subscribed wallpapers without deleting files or changing Steam subscriptions."
        ) {
            Button("Check subscriptions") { showingSubscriptionSync = true }
                .fixedSize()
        }
    }

    // MARK: - Derived row state

    /// Show each failing probe’s reason next to the affected setup step.
    @ViewBuilder
    private func attentionNote(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .font(DesignTokens.Typography.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Only failures get an inline badge; overall readiness appears in the overview.
    private func attentionBadge(for state: WorkshopStepState) -> SettingRowTitleBadge? {
        guard state == .attention else { return nil }
        return SettingRowTitleBadge(
            systemImage: "exclamationmark.triangle.fill",
            tint: DesignTokens.Colors.Status.warning,
            accessibilityLabel: Text(state.statusText)
        )
    }
}

// MARK: - Shared step readiness

/// Shared readiness for settings, overview, and onboarding.
extension SteamCMDDoctorService {
    var isLibraryReady: Bool {
        guard workdirBookmarkData != nil, !workdirResolutionFailed else { return false }
        if case .red? = probes[.workingDirectory]?.status { return false }
        return true
    }

    var isBinaryReady: Bool {
        hasBoundBinary && isGreen(.binaryIdentity)
    }

    /// Bindings persist across launches, probe results do not; bound-but-unprobed offers replacement, not setup.
    var isBinaryPresumedReady: Bool {
        guard hasBoundBinary else { return false }
        if case .red? = probes[.binaryIdentity]?.status { return false }
        return true
    }

    var libraryStepState: WorkshopStepState {
        guard workdirBookmarkData != nil else { return .notStarted }
        // A stored bookmark is ready only if it currently resolves.
        if workdirResolutionFailed || workdirDisplayPath == nil { return .attention }
        if case .red? = probes[.workingDirectory]?.status { return .attention }
        return .ready
    }

    /// Bound but unprobed binaries remain pending until verification.
    var binaryStepState: WorkshopStepState {
        guard hasBoundBinary else { return .notStarted }
        switch probes[.binaryIdentity]?.status {
        case .green: return .ready
        case .red: return .attention
        default: return .working
        }
    }

    /// Driven by the cached-login probe only (single source of truth).
    var accountStepState: WorkshopStepState {
        guard username != nil else { return .notStarted }
        switch probes[.cachedLogin]?.status {
        case .green: return .ready
        case .running: return .working
        case .notRun, .none: return .notStarted
        default: return .attention
        }
    }

    /// Groups library authorization and account readiness; SteamCMD is reported separately.
    var steamLibraryAndAccountState: WorkshopStepState {
        let steps = [libraryStepState, accountStepState]
        if steps.contains(.attention) { return .attention }
        if steps.allSatisfy({ $0 == .ready }) { return .ready }
        if steps.contains(.working) { return .working }
        return .notStarted
    }

    /// Only attention states expose a probe failure beside the setup row.
    func attentionMessage(for kind: DoctorProbeKind) -> String? {
        let state: WorkshopStepState
        switch kind {
        case .workingDirectory: state = libraryStepState
        case .binaryIdentity: state = binaryStepState
        case .cachedLogin: state = accountStepState
        default: return nil
        }
        guard state == .attention else { return nil }
        switch probes[kind]?.status {
        case let .yellow(message, _)?, let .red(message, _)?: return message
        default: return nil
        }
    }

    /// Unchecked steps stay pending; configuration and probe failures retain attention status.
    var connectionStepState: WorkshopStepState {
        let steps = [libraryStepState, binaryStepState, accountStepState]
        if steps.contains(.attention) { return .attention }
        if steps.allSatisfy({ $0 == .ready }) { return .ready }
        if steps.contains(.working) { return .working }
        return .notStarted
    }
}
#endif
