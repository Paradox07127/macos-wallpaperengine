#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Consent gate for the managed SteamCMD install.
///
/// Everything the user is agreeing to has to be on screen *before* the download
/// starts: where the bytes come from, how large they really get, where they
/// land, and that we can undo it. The archive is a bootstrapper, so quoting only
/// its 2.4 MB would understate the download by a factor of ~35.
struct SteamCMDManagedInstallSheet: View {
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let terms = SteamCMDBootstrapDownloader.DownloadTerms.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                header
                factsCard
                Text("This installs SteamCMD only. It does not sign you in to Steam, and you can remove it again from this screen.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.xl)

            SheetFooterBar(
                primaryTitle: "Download and install",
                primaryAction: {
                    dismiss()
                    onConfirm()
                },
                primaryDisabled: false,
                primaryHelp: "Download Valve's SteamCMD and set it up",
                cancelTitle: "Cancel",
                cancelAction: { dismiss() },
                cancelHelp: "Set up SteamCMD yourself instead"
            )
        }
        .frame(minWidth: 460, idealWidth: 480, maxWidth: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 22))
                .foregroundStyle(DesignTokens.Colors.Status.active)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install SteamCMD for me")
                    .font(.headline)
                Text("Loomscreen can fetch Valve's official command-line downloader and set it up, so you don't have to install it yourself.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            fact(
                label: Text("Download size"),
                value: Text(verbatim: String(
                    localized: "\(formatted(terms.archiveBytes)) from Valve's server at \(terms.sourceHost)",
                    comment: "Managed SteamCMD install consent sheet; first %@ is a file size, second is a hostname."
                ))
            )
            fact(
                label: Text("Size once ready"),
                value: Text(verbatim: String(
                    localized: "About \(formatted(terms.installedBytesApproximate)) — SteamCMD downloads the rest itself the first time it runs.",
                    comment: "Managed SteamCMD install consent sheet; %@ is the approximate installed size."
                ))
            )
            fact(
                label: Text("Location"),
                value: Text(verbatim: installLocationDisplayPath)
            )
            fact(
                label: Text("Checks"),
                value: Text("The archive must match a pinned checksum, and the program inside it must carry Valve's signature, before it is ever run.")
            )
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: DesignTokens.Card.strokeWidth)
        )
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

    /// The connector derives the real install root from its own home directory;
    /// this process's `NSHomeDirectory()` is the container, so asking for the
    /// real one is what makes the displayed path match where it lands.
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
