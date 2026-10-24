#if !LITE_BUILD
import SwiftUI

@MainActor
@ViewBuilder
func steamAccountMenuItems(
    accounts: [SteamAccountSummary],
    current: String?,
    onSelect: @escaping (SteamAccountSummary) -> Void,
    onSignIn: @escaping () -> Void
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
}

extension SteamCMDDoctorService {
    /// Binds the account only; the next download validates its session.
    func adoptAccount(_ account: SteamAccountSummary) throws {
        try setUsername(account.accountName)
    }
}
#endif
