import AppKit
import LiveWallpaperCore
import SwiftUI

struct AgentFolderAccessSection: View {
    @AppStorage("Monitor.AuthorizationExpanded") private var isAuthorizationExpanded = true

    @State private var claudeAuthorized = false
    @State private var codexAuthorized = false
    @State private var showsAgentActivity = false

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "AI Session History Access",
                systemImage: "folder.badge.person.crop",
                isExpanded: $isAuthorizationExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    authorizationRows
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onAppear(perform: refreshAuthorizationState)
        .sheet(isPresented: $showsAgentActivity) {
            AppLanguageScope(defaults: .appScoped()) {
                AgentActivityPanel()
            }
        }
    }

    @ViewBuilder
    private var authorizationRows: some View {
        Button("Open Agent Activity") { showsAgentActivity = true }
            .buttonStyle(.bordered)
        authorizationRow(
            title: "Claude Folder",
            subtitle: "Read-only access to ~/.claude",
            info: "Used by Agent Session and Agent Activity to display session metadata. Prompt text, replies and tool arguments are excluded.",
            isAuthorized: claudeAuthorized,
            authorize: {
                SourceAuthorization.shared.requestAccess(for: .claude, from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await Runtime.shared.refreshSources() }
                }
            },
            revoke: { revoke(.claude) }
        )

        Divider()

        authorizationRow(
            title: "Codex Folder",
            subtitle: "Read-only access to ~/.codex",
            info: "Used by Agent Session and Agent Activity to display session metadata. Prompt text, replies and tool arguments are excluded.",
            isAuthorized: codexAuthorized,
            authorize: {
                SourceAuthorization.shared.requestAccess(for: .codex, from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await Runtime.shared.refreshSources() }
                }
            },
            revoke: { revoke(.codex) }
        )
    }

    private func authorizationRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        info: String.LocalizationValue,
        isAuthorized: Bool,
        authorize: @escaping () -> Void,
        revoke: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(
                icon: "folder.badge.person.crop",
                iconColor: .indigo,
                title: title,
                titleBadge: isAuthorized
                    ? SettingRowTitleBadge(
                        systemImage: "checkmark.circle.fill",
                        tint: DesignTokens.Colors.Status.active,
                        accessibilityLabel: Text("Authorized")
                    )
                    : nil,
                subtitle: subtitle,
                info: info
            ) {
                if !isAuthorized {
                    Button("Authorize", action: authorize)
                        .fixedSize()
                }
            }
            if isAuthorized {
                HStack(spacing: 6) {
                    Button("Revoke", action: revoke)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    Button("Re-authorize", action: authorize)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func revoke(_ provider: SourceAuthorization.Provider) {
        SourceAuthorization.shared.revokeAccess(provider)
        refreshAuthorizationState()
        Task { await Runtime.shared.refreshSources() }
    }

    private func refreshAuthorizationState() {
        claudeAuthorized = SourceAuthorization.shared.isAuthorized(.claude)
        codexAuthorized = SourceAuthorization.shared.isAuthorized(.codex)
    }

    private func hostWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    }
}
