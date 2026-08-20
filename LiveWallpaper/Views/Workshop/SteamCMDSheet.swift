#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Consent gate for the managed SteamCMD install.
///
/// Everything the user is agreeing to has to be on screen *before* the download
/// starts: where the bytes come from, how large they really get, where they
/// land, and that we can undo it.
struct SteamCMDManagedInstallSheet: View {
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "arrow.down.circle",
                    title: "Install SteamCMD for me",
                    subtitle: "Loomscreen can fetch Valve's official command-line downloader and set it up, so you don't have to install it yourself."
                )
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
        .frame(width: SteamSheetWidth.form)
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            fact(
                label: Text("Download size"),
                value: Text(verbatim: String(
                    localized: "About \(formatted(SteamCMDManifest.approximateDownloadBytes)) from Valve's server at \(SteamCMDManifest.url.host() ?? "media.steampowered.com")",
                    comment: "Managed SteamCMD install consent sheet; first %@ is an approximate download size, second is a hostname."
                ))
            )
            fact(
                label: Text("Size once ready"),
                value: Text(verbatim: String(
                    localized: "About \(formatted(SteamCMDManifest.approximateInstalledBytes))",
                    comment: "Managed SteamCMD install consent sheet; %@ is the approximate installed size."
                ))
            )
            fact(
                label: Text("Location"),
                value: Text(verbatim: installLocationDisplayPath)
            )
            fact(
                label: Text("Checks"),
                value: Text("Every download must match Valve's published checksum, and the program must carry Valve's signature, before it is ever run.")
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

/// The self-serve alternative to the managed install, for users who want a
/// system-wide SteamCMD other tools can find. We only show the command —
/// running Homebrew from inside an app is not something to automate.
struct SteamCMDSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    private static let command = "brew install --cask steamcmd"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "terminal",
                    title: "Install with Homebrew",
                    subtitle: "Installs system-wide, where other tools can find it too. Run this in Terminal:"
                )

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(verbatim: Self.command)
                        .font(DesignTokens.Typography.code)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(didCopy ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.command, forType: .string)
                        didCopy = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(DesignTokens.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
                )

                Text("When it finishes, use Locate automatically and Loomscreen will pick it up.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.xl)

            SheetFooterBar(
                primaryTitle: "Done",
                primaryAction: { dismiss() },
                primaryDisabled: false,
                primaryHelp: "Close these instructions"
            )
        }
        .frame(width: SteamSheetWidth.form)
    }
}
#endif
