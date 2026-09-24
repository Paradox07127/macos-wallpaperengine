#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

enum SteamWizardMetrics {
    /// SCREENS S9. R-30: a plain sheet, because the Edit Desk modal chrome is pinned to 880×560.
    static let size = CGSize(width: 446, height: 526)
    static let progressBarHeight: CGFloat = 3
    static let fieldRowHeight: CGFloat = 26
}

/// The wizard's primary action: the first step a download still lacks.
enum SteamWizardStep: Equatable {
    case installSteamCMD
    case chooseLibrary
    case signIn
    case done

    static func make(blocker: SteamCMDDoctorService.DownloadBlocker?, isConfirmed: Bool) -> SteamWizardStep {
        switch blocker {
        case .steamCMD: .installSteamCMD
        case .library: .chooseLibrary
        case .account, .session: .signIn
        case nil: isConfirmed ? .done : .signIn
        }
    }
}

/// SCREENS S9's Steam wizard. Owns no Steam logic of its own: the status rows read
/// `WorkshopSetupController`, signing in is `SteamSignInSheet`'s state machine (Steam Guard
/// included), and the local library goes through `WorkshopFolderImportCoordinator`.
struct SteamWizard: View {
    let progress: OnboardingProgress?

    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var setupController
    @State private var isShowingSignIn = false
    /// The step this wizard last acted on; its `setupError` shows only while that step is current.
    @State private var lastAction: SteamWizardStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if let progress {
                    steps(progress)
                }
                Text("Download Workshop wallpapers with your own Steam account")
                    .font(DesignTokens.EditDesk.Typography.wizardTitle)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Loomscreen downloads through SteamCMD, never through a third-party server. You need to own Wallpaper Engine.")
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusCard
                Text("Already have a Wallpaper Engine library? Choose Import a Local Folder instead — no sign-in needed.")
                    .font(DesignTokens.EditDesk.Typography.footnote)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.xl)
            footer
        }
        .frame(width: SteamWizardMetrics.size.width, height: SteamWizardMetrics.size.height)
        .background(DesignTokens.EditDesk.Colors.console)
        .task { await setupController.prepare() }
        .sheet(isPresented: $isShowingSignIn) {
            AppLanguageScope(defaults: .appScoped()) {
                SteamSignInSheet { accountName in
                    setupController.adoptSignedInAccount(accountName)
                }
            }
        }
    }

    // MARK: Header

    private func steps(_ progress: OnboardingProgress) -> some View {
        let dots = OnboardingCapsuleModel.dots(visible: progress.visiblePages, handled: progress.handled)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(dots.enumerated()), id: \.offset) { _, isHandled in
                    Capsule()
                        .fill(
                            isHandled
                                ? DesignTokens.EditDesk.Colors.textPrimary
                                : DesignTokens.EditDesk.Colors.fillSelectedChip
                        )
                        .frame(height: SteamWizardMetrics.progressBarHeight)
                }
            }
            HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                Text("Connect Steam")
                Text(verbatim: "·")
                Text(verbatim: OnboardingCardContent.stepText(
                    step: progress.stepNumber(of: .workshop), total: dots.count
                ))
                .accessibilityLabel(Text("Step \(progress.stepNumber(of: .workshop)) of \(dots.count)"))
                Spacer(minLength: 0)
                Button("Later") {
                    progress.dismiss(.workshop)
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textCapsule)
            }
            .font(DesignTokens.EditDesk.Typography.badgeMono)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
        }
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(spacing: 0) {
            statusRow(title: "SteamCMD", state: setupController.steamCMDState, detail: steamCMDDetail)
            stepNote(under: .installSteamCMD)
            statusRow(title: "Steam Library access", state: doctor.libraryStepState, detail: libraryDetail)
            stepNote(under: .chooseLibrary)
            statusRow(title: "Steam Account", state: accountState, detail: accountDetail)
            statusRow(title: "Steam Token (2FA)", state: doctor.accountStepState, detail: tokenDetail)
            stepNote(under: .signIn)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panel, style: .continuous)
                .fill(DesignTokens.EditDesk.Colors.fillShell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panel, style: .continuous)
                .strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
        )
    }

    private func statusRow(title: LocalizedStringKey, state: WorkshopStepState, detail: Text) -> some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            Text(title)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
            Spacer(minLength: 0)
            SteamStatusGlyph(state: state, size: 12)
            detail
                .foregroundStyle(state.tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(DesignTokens.EditDesk.Typography.body)
        .frame(height: SteamWizardMetrics.fieldRowHeight + DesignTokens.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    /// At most one note fits the 526pt sheet: under the current step's row, its own error, else its probe message.
    @ViewBuilder
    private func stepNote(under row: SteamWizardStep) -> some View {
        if row == step, let note {
            Text(verbatim: note.text)
                .font(DesignTokens.EditDesk.Typography.footnote)
                .foregroundStyle(note.isError ? DesignTokens.EditDesk.Colors.danger : DesignTokens.EditDesk.Colors.warning)
                .lineLimit(2)
                .help(note.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DesignTokens.Spacing.sm)
        }
    }

    private var note: (text: String, isError: Bool)? {
        if lastAction == step, let error = setupController.setupError {
            return (error, true)
        }
        let probe: DoctorProbeKind
        switch step {
        case .installSteamCMD: probe = .binaryIdentity
        case .chooseLibrary: probe = .workingDirectory
        case .signIn: probe = .cachedLogin
        case .done: return nil
        }
        return doctor.attentionMessage(for: probe).map { ($0, false) }
    }

    private var steamCMDDetail: Text {
        if setupController.installer.status == .installing {
            return Text("Installing…")
        }
        return setupController.hasManagedInstall
            ? Text("Installed (managed)")
            : Text(setupController.steamCMDState.statusText)
    }

    private var libraryDetail: Text {
        doctor.workdirDisplayPath.map { Text(verbatim: $0) } ?? Text("Not authorized")
    }

    private var accountState: WorkshopStepState {
        doctor.username == nil ? .attention : .ready
    }

    private var accountDetail: Text {
        doctor.username.map { Text(verbatim: $0) } ?? Text("Waiting for sign-in")
    }

    private var tokenDetail: Text {
        doctor.accountStepState == .notStarted
            ? Text(verbatim: "—")
            : Text(doctor.accountStepState.statusText)
    }

    // MARK: Footer

    /// Built here rather than with `SheetFooterBar`: that bar's secondary slot owns Escape, and
    /// Escape must close the wizard, not open a folder picker.
    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button("← Back", action: dismiss.callAsFunction)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            Button("Import a Local Folder", action: importLocalFolder)
                .buttonStyle(.bordered)
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(setupController.isSteamCMDBusy || doctor.accountStepState == .working)
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private var step: SteamWizardStep {
        .make(blocker: doctor.downloadBlocker, isConfirmed: doctor.isDownloadConfirmed)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .installSteamCMD: "Install SteamCMD"
        case .chooseLibrary: "Choose folder"
        case .signIn: "Sign In →"
        case .done: "Done"
        }
    }

    private func primaryAction() {
        let current = step
        lastAction = current
        switch current {
        case .installSteamCMD:
            setupController.runManagedInstall()
        case .chooseLibrary:
            Task { await setupController.authorizeSteamLibrary(startingAtScannedPath: true) }
        case .signIn:
            isShowingSignIn = true
        case .done:
            // Recorded here too: a replayed tour whose session is already confirmed never sees false → true.
            progress?.record(.workshop)
            dismiss()
        }
    }

    private func importLocalFolder() {
        if Self.importLocalFolder() {
            dismiss()
        }
    }

    /// Also the Workshop card's "Import a Local Folder" button, so the picker exists once.
    @discardableResult
    static func importLocalFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(
            localized: "Choose the folder that holds your Wallpaper Engine projects.",
            bundle: .appLanguage, comment: "Open-panel message for importing an existing Wallpaper Engine library."
        )
        panel.prompt = String(
            localized: "Import Projects",
            bundle: .appLanguage, comment: "Open-panel confirm button for importing an existing Wallpaper Engine library."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        WorkshopFolderImportCoordinator.shared.importProjects(from: url)
        return true
    }
}
#endif
