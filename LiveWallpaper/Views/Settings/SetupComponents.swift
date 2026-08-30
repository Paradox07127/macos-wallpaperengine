#if !LITE_BUILD
import AppKit
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

    /// Named `statusText`, not `label`: the i18n guard forbids rendering a `.label` member
    /// directly (on most types that's a raw enum name) — a false positive here since this is
    /// already a `LocalizedStringKey`. Renaming was cheaper than an escape hatch, and `label` was overloaded against SwiftUI's own meaning anyway.
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

/// Dot + word status (not a filled chip — three stack without looking like alerts).
struct WorkshopStateBadge: View {
    let state: WorkshopStepState

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Circle()
                .fill(state.tint)
                .frame(width: 6, height: 6)
            Text(state.statusText)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sheet (not popover): CJK privacy copy runs ~1.5–2× English and would clip
/// in a tooltip. Renders `WorkshopLegalContent`, the same statements the
/// settings page lists — onboarding has no way to reach Settings, so it needs
/// its own presenter, not its own copy of the words.
struct WorkshopPrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SteamSheetHeader(
                icon: "hand.raised",
                title: "Privacy & terms"
            )
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    ForEach(WorkshopLegalContent.points) { point in
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            Text(point.title)
                                .font(DesignTokens.Typography.bodyEmphasized)
                            Text(point.body)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: DesignTokens.Spacing.md) {
                        ForEach(WorkshopLegalContent.references) { reference in
                            Button {
                                NSWorkspace.shared.open(reference.url)
                            } label: {
                                Text(reference.title)
                            }
                            .buttonStyle(.link)
                            .fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(DesignTokens.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SheetFooterBar(
                primaryTitle: "Done",
                primaryAction: { dismiss() }
            )
        }
        .frame(width: SteamSheetWidth.form, height: 460)
    }
}
#endif
