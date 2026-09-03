#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// In-app Steam sign-in for SteamCMD downloads.
/// The password field's contents go to the connector once per attempt and end at steamcmd's
/// own prompt; the sheet keeps them only in `@State` for the attempt's lifetime (a Guard retry
/// reuses them, so they aren't cleared between rounds), and the window's teardown drops them. Nothing here or downstream writes them anywhere.
struct SteamSignInSheet: View {
    /// Called with the signed-in account name so the caller can select it.
    let onSignedIn: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var accountName = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var phase: Phase = .form
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    private enum Phase: Equatable {
        case form
        /// In flight. Steam Guard's mobile confirmation happens inside this
        /// phase — the call simply stays open until the user approves.
        case submitting
        case guardCode(email: Bool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "person.badge.key",
                    title: "Sign in to Steam",
                    subtitle: "Lets SteamCMD download Workshop items as your account."
                )
                fields
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if phase == .submitting {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Signing in — approve on your phone if Steam asks.")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Your password goes only to Valve's SteamCMD on this Mac and is never stored.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.xl)

            SheetFooterBar(
                primaryTitle: "Sign In",
                primaryAction: submit,
                primaryDisabled: !canSubmit,
                primaryHelp: "Sign in to Steam through SteamCMD",
                cancelTitle: "Cancel",
                cancelAction: {
                    task?.cancel()
                    dismiss()
                },
                cancelHelp: "Close without signing in"
            )
        }
        .frame(width: SteamSheetWidth.form)
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            TextField("Steam account name", text: $accountName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(phase != .form)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(phase != .form)
            if case .guardCode(let email) = phase {
                TextField(
                    email ? "Code from your email" : "Code from your authenticator app",
                    text: $guardCode
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { if canSubmit { submit() } }
            }
        }
    }

    private var canSubmit: Bool {
        guard phase != .submitting else { return false }
        guard SteamCMDScriptWriter.validateUsername(accountName), !password.isEmpty else {
            return false
        }
        if case .guardCode = phase { return !guardCode.isEmpty }
        return true
    }

    private func submit() {
        errorText = nil
        let wantsCode: String? = {
            if case .guardCode = phase { return guardCode }
            return nil
        }()
        phase = .submitting
        task = Task {
            let result = await SteamConnectorClient.signInSteamAccount(
                accountName: accountName,
                password: password,
                guardCode: wantsCode
            )
            guard !Task.isCancelled else { return }
            handle(result)
        }
    }

    private func handle(_ result: SteamCMDLoginResult?) {
        switch result?.outcome {
        case .success:
            password = ""
            guardCode = ""
            onSignedIn(accountName)
            dismiss()
        case .guardCodeEmailRequired:
            phase = .guardCode(email: true)
        case .guardCodeTotpRequired:
            phase = .guardCode(email: false)
        case .invalidPassword:
            phase = .form
            errorText = String(localized: "Steam rejected that account name or password.", bundle: .appLanguage, comment: "In-app Steam sign-in failure.")
        case .invalidGuardCode:
            phase = .guardCode(email: true)
            errorText = String(localized: "That Steam Guard code wasn't accepted.", bundle: .appLanguage, comment: "In-app Steam sign-in failure.")
        case .rateLimited:
            phase = .form
            errorText = String(localized: "Steam is rate-limiting sign-ins from this Mac. Wait a few minutes and try again.", bundle: .appLanguage, comment: "In-app Steam sign-in failure.")
        case .noConnection:
            phase = .form
            errorText = SteamCMDDoctorService.steamUnreachableMessage
        case .timedOut:
            phase = .form
            errorText = String(localized: "Steam didn't confirm the sign-in in time. If Steam Guard asked on your phone, approve it and try again.", bundle: .appLanguage, comment: "In-app Steam sign-in failure.")
        case nil:
            // No reply at all: the connector is what failed, not the sign-in,
            // and telling the reader to check their connection sent them to
            // look at the wrong thing entirely.
            phase = .form
            errorText = String(
                localized: "Loomscreen's Steam connector did not respond.",
                bundle: .appLanguage, comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
            )
        case .unavailable:
            phase = .form
            errorText = String(
                localized: "SteamCMD could not be launched. Re-select it in the setup list.",
                bundle: .appLanguage, comment: "Steam sign-in diagnostic when the bound SteamCMD binary could not run."
            )
        case .failed:
            phase = .form
            // Steam usually says why it refused; only when it does not does
            // "check the connection" become the honest guess.
            errorText = result?.failureReason.map {
                String(
                    localized: "Steam refused the sign-in: \($0)",
                    bundle: .appLanguage, comment: "In-app Steam sign-in failure; the placeholder is Steam's own stated reason."
                )
            } ?? String(localized: "Sign-in didn't complete. Check the connection and try again.", bundle: .appLanguage, comment: "In-app Steam sign-in failure.")
        }
    }
}
#endif
