#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct OnboardingSheet: View {
    @AppStorage("loomscreen.workshop.onboarding.shown.v1", store: .appScoped()) private var hasShown: Bool = false
    @Environment(\.dismiss) private var dismiss
    /// Opens optional Web API key setup.
    var onConfigureOnline: () -> Void
    /// Opens the URL/ID queue; downloading still requires Steam setup.
    var onDownloadByLink: () -> Void

    var body: some View {
        HeroScaffold(
            title: "Browse Wallpaper Engine from Steam",
            message: "Browse without signing in. Downloads require Steam sign-in.",
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
                EmptyView()
            }
        )
        .padding(.vertical, DesignTokens.Spacing.xl)
        .frame(width: SteamSheetWidth.form)
        .background(DesignTokens.Colors.pageBackground)
        // Persist Escape and other dismissals so onboarding does not reopen on every visit.
        .onDisappear { hasShown = true }
    }
}
#endif
