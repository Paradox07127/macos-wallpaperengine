#if !LITE_BUILD
import SwiftUI

/// The Steam account menu's items, shared by the Workshop page header and the
/// Steam connection section in Settings. One list and one set of verbs: spelled
/// twice, the two menus drift the first time an action is added to either.
@MainActor
@ViewBuilder
func steamAccountMenuItems(
    accounts: [SteamAccountSummary],
    current: String?,
    onSelect: @escaping (SteamAccountSummary) -> Void,
    onSignIn: @escaping () -> Void,
    onRescan: @escaping () -> Void
) -> some View {
    ForEach(accounts) { account in
        Button {
            onSelect(account)
        } label: {
            if account.accountName == current {
                Label(account.accountName, systemImage: "checkmark")
            } else {
                Text(account.accountName)
            }
        }
    }
    Divider()
    Button("Sign in to another account", action: onSignIn)
    Button("Rescan", action: onRescan)
}

extension SteamCMDDoctorService {
    /// Binds the account and immediately re-checks the cached login, so whichever
    /// menu made the choice shows the result without a manual diagnostics run.
    func adoptAccount(_ account: SteamAccountSummary) throws {
        try setUsername(account.accountName)
        Task { await runProbe(.cachedLogin) }
    }
}
#endif
