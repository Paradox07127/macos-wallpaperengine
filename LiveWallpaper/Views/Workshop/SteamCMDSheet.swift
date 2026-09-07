#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Presents install location, size and verification before installing SteamCMD.
struct SteamCMDSetupSheet: View {
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
                    title: "Set up SteamCMD"
                )

                Picker("How to install", selection: $route) {
                    Text("Install with Loomscreen").tag(Route.managed)
                    Text("Install with Homebrew").tag(Route.homebrew)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel(Text("How to install SteamCMD"))

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
            Text("Run in Terminal to install system-wide. Then choose Locate automatically.")
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
