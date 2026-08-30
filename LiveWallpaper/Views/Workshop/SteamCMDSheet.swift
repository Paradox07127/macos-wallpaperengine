#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// The two ways to get SteamCMD, as one choice.
///
/// These were two separate sheets reached from two different places — the
/// managed install from a prominent button, Homebrew from an item buried in an
/// `⋯` menu — which presented one decision as a default plus a secret. Both
/// routes need their terms stated before anything happens (where the bytes
/// come from, how large they get, where they land, that it can be undone), so
/// they belong on one screen where they can be compared.
struct SteamCMDSetupSheet: View {
    /// Called when the user picks the managed install and confirms it.
    let onConfirmManagedInstall: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var route: Route = .managed
    @State private var didCopy = false

    private enum Route: String, CaseIterable, Identifiable {
        case managed
        case homebrew

        var id: String { rawValue }
    }

    private static let brewCommand = "brew install --cask steamcmd"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "terminal",
                    title: "Set up SteamCMD",
                    subtitle: "Valve's command-line downloader. Loomscreen can install its own copy, or you can install one system-wide with Homebrew."
                )

                Picker("How to install", selection: $route) {
                    Text("Let Loomscreen install it", bundle: .main).tag(Route.managed)
                    Text("Install with Homebrew", bundle: .main).tag(Route.homebrew)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel(Text("How to install SteamCMD", bundle: .main))

                switch route {
                case .managed: managedDetail
                case .homebrew: homebrewDetail
                }
            }
            .padding(DesignTokens.Spacing.xl)

            footer
        }
        .frame(width: SteamSheetWidth.form)
    }

    private var footer: some View {
        SheetFooterBar(
            primaryTitle: route == .managed ? "Download and install" : "Done",
            primaryAction: {
                dismiss()
                if route == .managed { onConfirmManagedInstall() }
            },
            primaryDisabled: false,
            primaryHelp: route == .managed
                ? "Download Valve's SteamCMD and set it up"
                : "Close these instructions",
            cancelTitle: "Cancel",
            cancelAction: { dismiss() },
            cancelHelp: "Set up SteamCMD later"
        )
    }

    // MARK: - Managed install

    private var managedDetail: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            fact(
                label: Text("Download size", bundle: .main),
                value: Text(verbatim: String(
                    localized: "About \(formatted(SteamCMDManifest.approximateDownloadBytes)) from Valve's server at \(SteamCMDManifest.url.host() ?? "media.steampowered.com")",
                    comment: "Managed SteamCMD install consent sheet; first %@ is an approximate download size, second is a hostname."
                ))
            )
            fact(
                label: Text("Size once ready", bundle: .main),
                value: Text(verbatim: String(
                    localized: "About \(formatted(SteamCMDManifest.approximateInstalledBytes))",
                    comment: "Managed SteamCMD install consent sheet; %@ is the approximate installed size."
                ))
            )
            fact(
                label: Text("Location", bundle: .main),
                value: Text(verbatim: installLocationDisplayPath)
            )
            fact(
                label: Text("Checks", bundle: .main),
                value: Text("Every download must match Valve's published checksum, and the program must carry Valve's signature, before it is ever run.", bundle: .main)
            )

            Text("This installs SteamCMD only. It does not sign you in to Steam, and you can remove it again from Settings.", bundle: .main)
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

    // MARK: - Homebrew

    /// We only show the command — running Homebrew from inside a sandboxed app
    /// is not something to automate.
    private var homebrewDetail: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Installs system-wide, where other tools can find it too. Run this in Terminal:", bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(verbatim: Self.brewCommand)
                    .font(DesignTokens.Typography.code)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.brewCommand, forType: .string)
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

            Text("When it finishes, use Locate automatically and Loomscreen will pick it up.", bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
