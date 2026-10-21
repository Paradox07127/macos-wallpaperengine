#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct SteamCMDSetupSheet: View {
    let onConfirmManagedInstall: () -> Void
    var isRecovery = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "terminal",
                    title: "Set up SteamCMD"
                )

                if isRecovery {
                    Text("Loomscreen will download and prepare SteamCMD for this Mac. Your existing installation stays in place. No Terminal commands are needed.")
                        .font(DesignTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Loomscreen downloads SteamCMD directly from Valve, with native support for Apple Silicon. No Rosetta is needed.")
                        .font(DesignTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                managedDetail

                DisclosureGroup("Already installed with Homebrew?") {
                    Text("Loomscreen can use existing Homebrew installations. On Apple Silicon, Homebrew's initial SteamCMD download requires Rosetta: manually run steamcmd +quit in Terminal to let SteamCMD update itself, then choose Locate automatically.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignTokens.Spacing.xl)

            footer
        }
        .frame(width: SteamSheetWidth.form)
    }

    private var footer: some View {
        SheetFooterBar(
            primaryTitle: "Download and install",
            primaryAction: {
                dismiss()
                onConfirmManagedInstall()
            },
            primaryDisabled: false,
            cancelTitle: "Cancel",
            cancelAction: { dismiss() }
        )
    }

    // MARK: - Managed install

    private var managedDetail: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            fact(
                label: Text("Download size"),
                value: Text(verbatim: String(
                    localized: "About \(formatted(SteamCMDManifest.approximateDownloadBytes)) from Valve's server at \(SteamCMDManifest.url.host() ?? "media.steampowered.com")",
                    bundle: .appLanguage, comment: "Managed SteamCMD install consent sheet; first %@ is an approximate download size, second is a hostname."
                ))
            )
            fact(
                label: Text("Size once ready"),
                value: Text(verbatim: String(
                    localized: "About \(formatted(SteamCMDManifest.approximateInstalledBytes))",
                    bundle: .appLanguage, comment: "Managed SteamCMD install consent sheet; %@ is the approximate installed size."
                ))
            )
            fact(
                label: Text("Location"),
                value: Text(verbatim: installLocationDisplayPath)
            )
            fact(
                label: Text("Checks"),
                value: Text("Verifies Valve's checksum and signature before running.")
            )

            Text("Installs SteamCMD only. Sign in separately; remove it from Settings.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(label: Text, value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            label
                .font(DesignTokens.Typography.caption.weight(.bold))
                .frame(width: 104, alignment: .leading)
            value
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// `NSHomeDirectory()` is the sandbox container here; the install lands under the
    /// real home, so the displayed path must be built from `realHomeDirectory()`.
    private var installLocationDisplayPath: String {
        let root = SteamCMDManagedInstaller.canonicalInstallRoot(
            home: AppleAerialsLibrary.realHomeDirectory()
        ).path(percentEncoded: false)
        return (root as NSString).abbreviatingWithTildeInPath
    }

    private func formatted(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}

#endif
