import SwiftUI
import AppKit
import LiveWallpaperCore

/// HTML privacy + origin-trust controls for the WKWebView.
struct SecurityInspector: View {
    var screen: Screen
    var source: HTMLSource?
    @Binding var htmlConfig: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @State private var trustStore = TrustedHostStore.shared
    @State private var pendingTrustOrigin: TrustedHTMLOrigin?
    @AppStorage("Inspector.ContentSecurityExpanded") private var isExpanded = true

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
            title: "Clear Data on Exit",
            info: "When on, the wallpaper's WKWebView starts fresh each session — cookies, localStorage, and cache are not persisted."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.useEphemeralStorage))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Ephemeral browsing data"))
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
            title: "Enforce Content Security Policy",
            info: "Injects a strict CSP meta tag before the page evaluates its own scripts. Permits HTTPS + the bundled livewallpaper:// scheme; blocks data exfiltration via FTP / arbitrary schemes. Some wallpapers may break — toggling requires a reload."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.cspEnforcementEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Enforce content security policy"))
        }
    }

    private var aggressiveSuspendRow: some View {
        SettingRow(
            icon: "bolt.slash.fill",
            iconColor: .yellow,
            title: "Aggressive Suspend",
            info: "On suspend, force-release every GPU canvas context and recreate it on resume. This can reduce GPU work while the wallpaper is occluded or thermally throttled, but some pages do not handle context restoration and may stay black afterward."
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
            .confirmationDialog(
                Text("Trust \(origin.displayName) for JavaScript?"),
                isPresented: Binding(
                    get: { pendingTrustOrigin == origin },
                    set: { if !$0 { pendingTrustOrigin = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Trust Origin") {
                    defer { pendingTrustOrigin = nil }
                    guard let source, remoteOrigin == origin else { return }
                    _ = trustStore.trust(origin)
                    screenManager.setHTMLWallpaper(
                        source: source,
                        config: htmlConfig,
                        forceReload: true,
                        for: screen
                    )
                }
                Button("Cancel", role: .cancel) {
                    pendingTrustOrigin = nil
                }
            } message: {
                if origin.isSecure {
                    Text("This allows the wallpaper to run scripts, use local storage, and access WebGPU. Only trust origins you recognize.")
                } else {
                    Text("This allows the wallpaper to run scripts, use local storage, and access WebGPU. This address is plain HTTP on your local network, so anyone else on that network could change what it sends.")
                }
            }
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
