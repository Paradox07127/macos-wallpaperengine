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

/// SCREENS S9's Steam wizard. Owns no Steam logic of its own: the status rows read
/// `WorkshopSetupController`, signing in is `SteamSignInSheet`'s state machine (Steam Guard
/// included), and the local library goes through `WorkshopFolderImportCoordinator`.
struct SteamWizard: View {
    let progress: OnboardingProgress?

    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var setupController
    @State private var isShowingSignIn = false

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
        .task { await setupController.loadAccounts() }
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
            statusRow(title: "Steam Account", state: accountState, detail: accountDetail)
            statusRow(title: "Steam Token (2FA)", state: doctor.accountStepState, detail: tokenDetail)
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

    private var steamCMDDetail: Text {
        setupController.hasManagedInstall
            ? Text("Installed (managed)")
            : Text(setupController.steamCMDState.statusText)
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
                .disabled(setupController.isSteamCMDBusy)
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private var primaryTitle: LocalizedStringKey {
        doctor.hasBoundBinary ? "Sign In →" : "Install SteamCMD"
    }

    private func primaryAction() {
        if doctor.hasBoundBinary {
            isShowingSignIn = true
        } else {
            setupController.runManagedInstall()
        }
    }

    private func importLocalFolder() {
        if Self.importLocalFolder() {
            dismiss()
        }
    }

    /// Also the Workshop card's "Import a local WE library" button, so the picker exists once.
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
