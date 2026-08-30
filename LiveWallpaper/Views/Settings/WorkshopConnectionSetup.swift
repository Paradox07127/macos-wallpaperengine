#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// The three Steam connection steps as one settings section.
///
/// Each step offers the same shape: the route most people want as a button,
/// the other ways beside it. The actions themselves live in
/// `WorkshopSetupController`, which the onboarding step renders from too — two
/// copies of `runManagedInstall` is what used to let the two surfaces disagree
/// about whether SteamCMD was ready.
struct WorkshopConnectionSetup: View {
    @Environment(SteamCMDDoctorService.self) private var service
    @Environment(WorkshopSetupController.self) private var controller

    @State private var showingSetupSheet = false
    @State private var showingSignIn = false

    var body: some View {
        Section {
            libraryRow
            binaryRow
            accountRow

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
            info: "Pick Steam's own folder — the one containing config/config.vdf — once. Loomscreen keeps a security-scoped bookmark to it and never creates a second Workshop repository. macOS only grants that bookmark through a panel you confirm, so even the located folder needs one click."
        ) {
            WorkshopSetupRoutes(
                primary: libraryPrimaryRoute,
                secondary: librarySecondaryRoutes,
                emphasizesPrimary: !service.isLibraryReady
            )
        }
        // The sheets and the initial probe hang off the first row rather than
        // the section: a modified `Section` stops being a section to `Form`,
        // and a presenter only has to be somewhere in the hierarchy.
        .sheet(isPresented: $showingSetupSheet) {
            SteamCMDSetupSheet(onConfirmManagedInstall: { controller.runManagedInstall() })
        }
        .sheet(isPresented: $showingSignIn) {
            SteamSignInSheet { accountName in
                controller.adoptSignedInAccount(accountName)
            }
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
            // Named after the folder shown in the subtitle, not after the act
            // of scanning: the scan already happened, and what is left is the
            // authorization only the user can give.
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
            info: "Valve's command-line downloader. Loomscreen can install its own copy, or locate an existing verified Homebrew or tarball install."
        ) {
            WorkshopSetupRoutes(
                primary: binaryPrimaryRoute,
                secondary: binarySecondaryRoutes,
                isBusy: controller.isSteamCMDBusy,
                emphasizesPrimary: !service.isBinaryPresumedReady
            )
        }
    }

    /// Most Macs have no SteamCMD, so for them the setup sheet is the whole
    /// point of this row and belongs in a primary button. Once one is bound,
    /// the common act is pointing at a different one instead.
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
        var routes: [WorkshopSetupRoute] = []
        if service.isBinaryPresumedReady {
            routes.append(WorkshopSetupRoute(id: "steamcmd.reinstall", title: "Set up SteamCMD") {
                showingSetupSheet = true
            })
        } else {
            routes.append(WorkshopSetupRoute(id: "steamcmd.choose", title: "Choose SteamCMD") {
                Task { await controller.pickBinaryManually() }
            })
        }
        routes.append(WorkshopSetupRoute(id: "steamcmd.locate", title: "Locate automatically") {
            controller.autoDetectBinary()
        })
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
            info: "Downloads sign in as your own Steam account through SteamCMD. Loomscreen lists the accounts Steam has already signed in on this Mac; it never stores your password."
        ) {
            accountControl
                .fixedSize()
        }
    }

    /// The switcher stays a menu rather than a `WorkshopSetupRoute`: picking
    /// among accounts is a choice, and a button that opens a list of names is
    /// what a menu is for.
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
                        onRescan: { Task { await controller.loadAccounts() } }
                    )
                } label: {
                    Text(service.username == nil ? "Choose account" : "Switch account", bundle: .main)
                }
                .menuStyle(.borderlessButton)
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

    // MARK: - Derived row state

    /// Only failures get a title badge. The page-top status bar carries the
    /// "everything is fine" reading now, and a green seal on every row was the
    /// noise it replaced — but a step whose probe came back red has to say so
    /// where the step is.
    private func attentionBadge(for state: WorkshopStepState) -> SettingRowTitleBadge? {
        guard state == .attention else { return nil }
        return SettingRowTitleBadge(
            systemImage: "exclamationmark.triangle.fill",
            tint: DesignTokens.Colors.Status.warning,
            accessibilityLabel: Text(state.statusText, bundle: .main)
        )
    }
}

// MARK: - Shared step readiness

/// One reading of each step, so the status bar, the settings rows and the
/// onboarding tree can't disagree about what is set up.
extension SteamCMDDoctorService {
    var isLibraryReady: Bool {
        guard workdirBookmarkData != nil, !workdirResolutionFailed else { return false }
        if case .red? = probes[.workingDirectory]?.status { return false }
        return true
    }

    var isBinaryReady: Bool {
        hasBoundBinary && isGreen(.binaryIdentity)
    }

    /// What the UI should offer as the next action, which is looser than
    /// `isBinaryReady` on purpose.
    ///
    /// Probe results are not persisted, so every relaunch starts at `.notRun`
    /// and a perfectly good binding reads as unverified. Gating the prominent
    /// button on the strict flag put "Set up SteamCMD" in front of users who
    /// already had one bound. Matches `binaryStepState`, which already treats
    /// bound-but-unprobed as working.
    var isBinaryPresumedReady: Bool {
        guard hasBoundBinary else { return false }
        if case .red? = probes[.binaryIdentity]?.status { return false }
        return true
    }

    var libraryStepState: WorkshopStepState {
        guard workdirBookmarkData != nil else { return .notStarted }
        // Bytes are not access: when the bookmark no longer resolves, the row
        // subtitle already says "Not authorized", so the badge must not say
        // Ready next to it.
        if workdirResolutionFailed || workdirDisplayPath == nil { return .attention }
        if case .red? = probes[.workingDirectory]?.status { return .attention }
        return .ready
    }

    /// `.working` covers "bound, not yet checked" as well as "checking right
    /// now": a binary we have never probed is unverified, not broken.
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

    /// Library authorization + account, which are one errand from the reader's
    /// side: both are "point Loomscreen at the Steam you already have".
    /// SteamCMD is reported separately because installing it is a different act.
    var steamLibraryAndAccountState: WorkshopStepState {
        let steps = [libraryStepState, accountStepState]
        if steps.contains(.attention) { return .attention }
        if steps.allSatisfy({ $0 == .ready }) { return .ready }
        if steps.contains(.working) { return .working }
        return .notStarted
    }

    /// The three steps as one reading, for the Workshop page's status bar.
    ///
    /// Amber means a probe came back failing — never "we haven't checked yet".
    /// Treating unchecked as failing is what used to leave the bar amber after
    /// a successful Locate: `cachedLogin` had simply never run, and only Run
    /// all checks cleared it.
    var connectionStepState: WorkshopStepState {
        let steps = [libraryStepState, binaryStepState, accountStepState]
        if steps.contains(.attention) { return .attention }
        if steps.allSatisfy({ $0 == .ready }) { return .ready }
        if steps.contains(.working) { return .working }
        return .notStarted
    }
}
#endif
