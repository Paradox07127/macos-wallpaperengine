#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Shared chrome for Workshop setup (Steam connection sheet, settings, onboarding).

// MARK: - Step state

enum WorkshopStepState: Equatable {
    case notStarted
    case working
    case attention
    case ready

    var tint: Color {
        switch self {
        case .notStarted: return DesignTokens.Colors.textTertiary
        case .working: return DesignTokens.Colors.textSecondary
        case .attention: return DesignTokens.Colors.Status.warning
        case .ready: return DesignTokens.Colors.Status.active
        }
    }

    /// Named `statusText`, not `label`: the i18n guard forbids rendering a
    /// `.label` member directly, because on most types that is a raw enum name.
    /// This one is already a `LocalizedStringKey`, so the rule is a false
    /// positive here — renaming is cheaper than an escape hatch, and `label`
    /// was overloaded against SwiftUI's own meaning anyway.
    var statusText: LocalizedStringKey {
        switch self {
        case .notStarted: return "Not set"
        case .working: return "Checking"
        case .attention: return "Action needed"
        case .ready: return "Ready"
        }
    }
}

extension WorkshopStepState {
    /// One reading of the Wallpaper Engine assets step, shared by the settings
    /// status bar, the onboarding checklist and the Scene warning banner — the
    /// same reason `connectionStepState` exists for the Steam steps.
    @MainActor
    static func engineAssets(
        library: WPEEngineAssetsLibrary,
        installer: WPEEngineAssetsInstaller
    ) -> WorkshopStepState {
        if installer.isBusy { return .working }
        if installer.updateAvailable { return .attention }
        if installer.hasManagedInstall || library.isAuthorized { return .ready }
        return .notStarted
    }

    /// Whether the shared `assets/` are actually reachable right now. Narrower
    /// than `== .ready`: an install with an update pending still renders.
    @MainActor
    static func hasEngineAssets(
        library: WPEEngineAssetsLibrary,
        installer: WPEEngineAssetsInstaller
    ) -> Bool {
        installer.hasManagedInstall || library.isAuthorized
    }
}

/// One setup step: name, state badge, optional detail, and the control that advances it.
struct WorkshopSetupRow<Control: View>: View {
    let icon: String
    let title: LocalizedStringKey
    /// Path / account / short reason — one line.
    let detail: String?
    let state: WorkshopStepState
    let info: String.LocalizationValue
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(state.tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(title, bundle: .main)
                        .font(DesignTokens.Typography.bodyEmphasized)
                    WorkshopStateBadge(state: state)
                    InfoTooltipButton(text: info)
                }
                if let detail {
                    Text(detail)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .marqueeOnHover()
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            control()
                .fixedSize()
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dot + word status (not a filled chip — three stack without looking like alerts).
struct WorkshopStateBadge: View {
    let state: WorkshopStepState

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Circle()
                .fill(state.tint)
                .frame(width: 6, height: 6)
            Text(state.statusText, bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Opens the shared Workshop privacy sheet (what leaves this Mac).
struct WorkshopPrivacyLink: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label {
                Text("Privacy & data", bundle: .main)
            } icon: {
                Image(systemName: "hand.raised")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .sheet(isPresented: $isPresented) {
            WorkshopPrivacySheet()
        }
    }
}

/// Sheet (not popover): CJK privacy copy runs ~1.5–2× English and would clip in a tooltip.
private struct WorkshopPrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SteamSheetHeader(
                icon: "hand.raised",
                title: "Privacy & data"
            )
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    point(
                        title: "File access",
                        body: "Loomscreen never asks for Full Disk Access. Library access comes from one folder you pick, stored as a security-scoped bookmark."
                    )
                    point(
                        title: "Steam sign-in",
                        body: "Your Steam password and Steam Guard codes go to SteamCMD only — sign in from Terminal, or reuse the session Steam already cached."
                    )
                    point(
                        title: "Web API key",
                        body: "The Web API key is stored privately on this Mac and is never synced. Forgetting it here does not revoke it; do that at steamcommunity.com/dev/apikey."
                    )
                    point(
                        title: "Where requests go",
                        body: "Workshop requests go straight to Valve over HTTPS. Nothing is sent to Loomscreen."
                    )
                }
                .padding(DesignTokens.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SheetFooterBar(
                primaryTitle: "Done",
                primaryAction: { dismiss() }
            )
        }
        .frame(width: SteamSheetWidth.form, height: 420)
    }

    private func point(title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title, bundle: .main)
                .font(DesignTokens.Typography.bodyEmphasized)
            Text(body, bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
