#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// SCREENS S8's "◉ Steam ▾": every Workshop account and setup entry point as menu rows. It only
/// raises the page's sheets — the page owns their state.
struct WorkshopSteamMenu: View {
    let accounts: [SteamAccountSummary]
    /// The account downloads currently run as; nil when none is bound.
    let currentAccount: String?
    let onSelectAccount: (SteamAccountSummary) -> Void
    let onSignIn: () -> Void
    let onRescan: () -> Void
    let onRemoveSession: () -> Void
    let onSyncSubscriptions: () -> Void
    let onDownloadByLink: () -> Void
    let onEnterAPIKey: () -> Void
    let onInstallSteamCMD: () -> Void
    let onLocateSteamCMD: () -> Void
    let onImportLocalFolder: () -> Void
    let steamCMDReady: Bool
    /// Installing, removing or locating SteamCMD: a locate that finishes mid-install reports it missing.
    let steamCMDBusy: Bool
    /// S8 has no banner strip, so the old private-session notice rides here as a section; its
    /// Hide This Notice row is the old banner's Dismiss.
    var showsPrivateSessionNotice = false
    var onDismissPrivateSessionNotice: () -> Void = {}

    var body: some View {
        Menu {
            if showsPrivateSessionNotice {
                Section {
                    Button("Hide This Notice", action: onDismissPrivateSessionNotice)
                } header: {
                    Text("Steam downloads now sign in separately")
                }
            }
            // An empty list can only offer sign-in; "another account" would name nothing.
            if accounts.isEmpty {
                Button("Sign In", action: onSignIn)
            } else {
                steamAccountMenuItems(
                    accounts: accounts,
                    current: currentAccount,
                    onSelect: onSelectAccount,
                    onSignIn: onSignIn,
                    onRescan: onRescan,
                    onRemoveSession: onRemoveSession
                )
            }
            Divider()
            Button("Sync subscribed wallpapers", action: onSyncSubscriptions)
            Button("Add from Workshop URL or ID", action: onDownloadByLink)
            Button("Import a Local Folder", action: onImportLocalFolder)
            Button("Set Web API key", action: onEnterAPIKey)
            if !steamCMDReady {
                Divider()
                Button("Install SteamCMD", action: onInstallSteamCMD)
                    .disabled(steamCMDBusy)
                Button("Locate automatically", action: onLocateSteamCMD)
                    .disabled(steamCMDBusy)
            }
        } label: {
            capsuleLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .font(DesignTokens.EditDesk.Typography.chip)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        .fixedSize()
        .accessibilityLabel(Text("Steam account"))
    }

    private var capsuleLabel: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: currentAccount == nil ? "circle" : "circle.fill")
                .foregroundStyle(
                    currentAccount == nil
                        ? DesignTokens.EditDesk.Colors.textTertiary
                        : DesignTokens.EditDesk.Colors.success
                )
                .accessibilityHidden(true)
            Text(verbatim: "Steam")
            Text(verbatim: "▾")
        }
    }
}
#endif
