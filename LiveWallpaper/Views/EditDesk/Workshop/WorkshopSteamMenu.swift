#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The Workshop page's "◉ Steam ▾": content tasks, the account picker, and a jump to Steam settings.
/// It only raises the page's sheets — the page owns their state.
struct WorkshopSteamMenu: View {
    let accounts: [SteamAccountSummary]
    /// The account downloads currently run as; nil when none is bound.
    let currentAccount: String?
    let onSelectAccount: (SteamAccountSummary) -> Void
    let onSignIn: () -> Void
    let onSyncSubscriptions: () -> Void
    let onDownloadByLink: () -> Void
    let onImportLocalFolder: () -> Void
    let onOpenSteamSettings: () -> Void
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
            Section {
                Button("Sync subscribed wallpapers", action: onSyncSubscriptions)
                Button("Add from Workshop URL or ID", action: onDownloadByLink)
                Button("Import a Local Folder", action: onImportLocalFolder)
            }
            Section {
                Menu("Steam Account") {
                    // An empty list can only offer sign-in; "another account" would name nothing.
                    if accounts.isEmpty {
                        Button("Sign In", action: onSignIn)
                    } else {
                        steamAccountMenuItems(
                            accounts: accounts,
                            current: currentAccount,
                            onSelect: onSelectAccount,
                            onSignIn: onSignIn
                        )
                    }
                }
            }
            Section {
                Button("Steam Settings", action: onOpenSteamSettings)
            }
        } label: {
            capsuleLabel
        }
        // `.borderlessButton` draws its own chrome over the label's glass; a plain button menu draws the label as written.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .frame(height: DesignTokens.LibraryFilterBar.controlHeight)
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
        }
        .font(DesignTokens.EditDesk.Typography.chip)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
        .padding(.horizontal, 10)
        .frame(height: DesignTokens.LibraryFilterBar.controlHeight)
        .adaptiveGlassSurface(.capsule, interactive: true)
        .contentShape(Capsule())
    }
}
#endif
