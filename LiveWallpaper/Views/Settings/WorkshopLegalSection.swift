#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// What leaves this Mac, and the terms the Steam side is used under.
/// Used to live in three places — a privacy sheet, the API key sheet's warning card, a tooltip
/// on the assets row — so the reader could only assemble the picture by opening all three. Held
/// here as data, rendered by both the settings section and onboarding sheet: one copy each.
/// Main-actor isolated because `LocalizedStringKey` isn't `Sendable`; both renderers are views, so it costs nothing.
@MainActor
enum WorkshopLegalContent {
    struct Point: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let body: LocalizedStringKey
    }

    struct Reference: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let url: URL
    }

    static let points: [Point] = [
        Point(
            id: "files",
            title: "File access",
            body: "Loomscreen never asks for Full Disk Access. Library access comes from one folder you pick, stored as a security-scoped bookmark."
        ),
        Point(
            id: "signIn",
            title: "Steam sign-in",
            body: "Your Steam password and Steam Guard codes go to SteamCMD only. Loomscreen never stores them, and never sends them anywhere else."
        ),
        Point(
            id: "apiKey",
            title: "Web API key",
            body: "The Web API key is stored in this Mac's login keychain and is never synced. Forgetting it here does not revoke it; do that at steamcommunity.com/dev/apikey."
        ),
        Point(
            id: "requests",
            title: "Where requests go",
            body: "Workshop requests go straight to Valve over HTTPS. Nothing is sent to Loomscreen, and Loomscreen runs no server of its own."
        ),
        Point(
            id: "assets",
            title: "Wallpaper Engine assets",
            body: "Scene resources are read only. Loomscreen never modifies a Wallpaper Engine install, and downloading one requires a Steam account that already owns it."
        )
    ]

    static let references: [Reference] = [
        Reference(id: "tou", title: "Steam Web API Terms of Use", url: SteamWebAPIKeyLinks.terms),
        Reference(id: "limited", title: "About Limited Accounts", url: SteamWebAPIKeyLinks.limitedAccounts)
    ]
}

/// The settings section. One row per statement, links at the bottom.
struct WorkshopLegalSection: View {
    var body: some View {
        Section {
            ForEach(WorkshopLegalContent.points) { point in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(point.title)
                        .font(DesignTokens.Typography.bodyEmphasized)
                    Text(point.body)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: DesignTokens.Spacing.md) {
                ForEach(WorkshopLegalContent.references) { reference in
                    Button {
                        NSWorkspace.shared.open(reference.url)
                    } label: {
                        Text(reference.title)
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
        } header: {
            SettingsSearchSectionHeader("Privacy & terms", anchor: .workshopLegal)
        }
    }
}
#endif
