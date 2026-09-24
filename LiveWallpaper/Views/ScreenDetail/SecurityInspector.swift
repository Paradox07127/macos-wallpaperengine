import SwiftUI
import AppKit
import LiveWallpaperCore

struct SecurityInspector: View {
    var screen: Screen
    var source: HTMLSource?
    @Binding var htmlConfig: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @State private var trustStore = TrustedHostStore.shared
    @State private var pendingTrustOrigin: TrustedHTMLOrigin?
    @AppStorage("Inspector.ContentSecurityExpanded") private var isExpanded = false

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Content Security",
                systemImage: "lock.shield",
                isExpanded: $isExpanded
            ) {
                VStack(spacing: 8) {
                    ephemeralStorageRow
                    Divider()
                    trackerBlockingRow
                    Divider()
                    cspEnforcementRow
                    Divider()
                    aggressiveSuspendRow
                    if let origin = remoteOrigin {
                        Divider()
                        originTrustRow(for: origin)
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var ephemeralStorageRow: some View {
        SettingRow(
            icon: "archivebox",
            iconColor: .purple,
            title: "Temporary Website Data",
            info: "Cookies, website data and cache are not saved between sessions."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.useEphemeralStorage))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Temporary Website Data"))
        }
    }

    private var trackerBlockingRow: some View {
        SettingRow(
            icon: "shield",
            iconColor: .red,
            title: "Block Trackers"
        ) {
            Toggle("", isOn: htmlConfigBinding(\.blockTrackers))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Block trackers"))
        }
    }

    private var cspEnforcementRow: some View {
        SettingRow(
            icon: "lock.shield.fill",
            iconColor: .indigo,
            title: "Content Security Policy",
            info: "Limits web content. Changes reload the page and may affect compatibility."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.cspEnforcementEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Content Security Policy"))
        }
    }

    private var aggressiveSuspendRow: some View {
        SettingRow(
            icon: "bolt.slash.fill",
            iconColor: .yellow,
            title: "Aggressive Suspend",
            info: "Frees graphics resources while paused. Some pages may resume blank."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.aggressiveSuspend))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Aggressive suspend"))
        }
    }

    private var remoteOrigin: TrustedHTMLOrigin? {
        guard let source else { return nil }
        switch HTMLTrust.evaluate(source: source, trustedOrigins: trustStore.originSet) {
        case .trustedRemote(let origin), .untrustedRemote(let origin):
            return origin
        case .localContent:
            return nil
        }
    }

    @ViewBuilder
    private func originTrustRow(for origin: TrustedHTMLOrigin) -> some View {
        let isTrusted = trustStore.originSet.contains(origin) || origin.isLoopback
        SettingRow(
            icon: isTrusted ? "checkmark.shield.fill" : "exclamationmark.shield",
            iconColor: isTrusted ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.warning,
            title: "Origin Access",
            subtitle: LocalizedStringKey(origin.displayName),
            info: trustRowInfo(for: origin, isTrusted: isTrusted)
        ) {
            trustRowAction(for: origin, isTrusted: isTrusted)
        }
    }

    private func trustRowInfo(for origin: TrustedHTMLOrigin, isTrusted: Bool) -> String.LocalizationValue {
        if trustStore.isBuiltInTrusted(origin) {
            return "Built-in trust for the platform's official embed surface — cannot be revoked."
        }
        if origin.isLoopback {
            return "Local development server. Loopback addresses never leave this Mac, so they run JavaScript automatically — there is nothing to revoke."
        }
        if isTrusted {
            return "JavaScript runs on this origin. Revoke to disable script execution."
        }
        if origin.isSecure {
            return "Scripts disabled. Trust this origin to allow JavaScript execution."
        }
        if origin.isPrivateNetwork {
            return "Scripts disabled. This is a plain HTTP address on your local network — anyone else on the same network could alter what it sends. Trust it only if you control this machine."
        }
        return "Scripts disabled. Only HTTPS, loopback, and local-network origins can run JavaScript."
    }

    @ViewBuilder
    private func trustRowAction(for origin: TrustedHTMLOrigin, isTrusted: Bool) -> some View {
        if trustStore.isBuiltInTrusted(origin) {
            StatusChip("Built-in", tint: .secondary)
        } else if origin.isLoopback {
            StatusChip("Local", tint: .secondary)
        } else if isTrusted {
            Button("Revoke", role: .destructive) {
                guard let source else { return }
                _ = trustStore.revoke(origin)
                screenManager.setHTMLWallpaper(
                    source: source,
                    config: htmlConfig,
                    forceReload: true,
                    for: screen
                )
            }
            .tint(DesignTokens.Colors.Status.danger)
            .fixedSize()
        } else if origin.canBeTrusted {
            Button("Trust") {
                pendingTrustOrigin = origin
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .htmlOriginTrustDialog(pending: $pendingTrustOrigin, screen: screen, source: source, config: htmlConfig)
        }
    }

    private func htmlConfigBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<HTMLConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { htmlConfig[keyPath: keyPath] },
            set: { newValue in
                guard htmlConfig[keyPath: keyPath] != newValue else { return }
                var next = htmlConfig
                next[keyPath: keyPath] = newValue
                htmlConfig = next
                screenManager.updateHTMLConfig(next, for: screen)
            }
        )
    }
}

extension View {
    /// The one confirmation for trusting a web page's origin, shared by this row and the preview HUD.
    func htmlOriginTrustDialog(
        pending: Binding<TrustedHTMLOrigin?>, screen: Screen, source: HTMLSource?, config: HTMLConfig
    ) -> some View {
        modifier(HTMLOriginTrustDialog(pending: pending, screen: screen, source: source, config: config))
    }
}

private struct HTMLOriginTrustDialog: ViewModifier {
    @Binding var pending: TrustedHTMLOrigin?
    let screen: Screen
    let source: HTMLSource?
    let config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text("Trust \(pending?.displayName ?? "") for JavaScript?"),
            isPresented: Binding(
                get: { pending != nil },
                set: { presented in
                    if !presented {
                        pending = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { origin in
            Button("Trust Origin") {
                defer { pending = nil }
                guard let source, case let .url(url) = source, TrustedHTMLOrigin(url: url) == origin else { return }
                _ = TrustedHostStore.shared.trust(origin)
                screenManager.setHTMLWallpaper(source: source, config: config, forceReload: true, for: screen)
            }
            Button("Cancel", role: .cancel) {
                pending = nil
            }
        } message: { origin in
            if origin.isSecure {
                Text("This allows the wallpaper to run scripts, use local storage, and access WebGPU. Only trust origins you recognize.")
            } else {
                Text("This allows the wallpaper to run scripts, use local storage, and access WebGPU. This address is plain HTTP on your local network, so anyone else on that network could change what it sends.")
            }
        }
    }
}
