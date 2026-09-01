#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct OnboardingSheet: View {
    @AppStorage("loomscreen.workshop.onboarding.shown.v1", store: .appScoped()) private var hasShown: Bool = false
    @Environment(\.dismiss) private var dismiss
    /// Primary path: configure the API key required by the online catalog.
    var onConfigureOnline: () -> Void
    /// Key-free fallback: install a known item from its Workshop URL or id.
    var onDownloadByLink: () -> Void

    var body: some View {
        HeroScaffold(
            title: "Browse Wallpaper Engine from Steam",
            message: "Search and download without signing in. A free Steam Web API key adds ratings, authors and faster results.",
            primary: (title: "Start browsing", action: {
                hasShown = true
                dismiss()
            }),
            alternatives: [
                ("Add a Web API key", {
                    hasShown = true
                    dismiss()
                    onConfigureOnline()
                }),
                ("Add from Workshop URL or ID", {
                    hasShown = true
                    dismiss()
                    onDownloadByLink()
                }),
            ],
            illustration: {
                HeroGlyph(systemImage: "cube.transparent")
            },
            content: {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    bullet(systemImage: "network", text: "Direct to Valve over HTTPS — no third-party services.")
                    bullet(systemImage: "key", text: "Browsing needs no account and no key — a key only adds to it.")
                    bullet(systemImage: "arrow.down.circle", text: "Downloads run through Steam's official SteamCMD.")
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        )
        .padding(.vertical, DesignTokens.Spacing.xl)
        .frame(width: SteamSheetWidth.form)
        .background(DesignTokens.Colors.pageBackground)
        // Marked on *any* dismissal, Escape included. The sheet now greets the
        // first visit to Browse Online, so a declined sheet that didn't persist
        // would re-open on every visit.
        .onDisappear { hasShown = true }
    }

    private func bullet(systemImage: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 26, height: 26)
                Image(systemName: systemImage)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(Color.accentColor)
            }
            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
