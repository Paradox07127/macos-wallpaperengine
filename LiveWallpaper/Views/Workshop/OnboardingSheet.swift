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
        VStack(spacing: 18) {
            illustration
            VStack(spacing: 8) {
                Text("Browse Wallpaper Engine from Steam")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Search and download without signing in. A free Steam Web API key adds ratings, authors and faster results.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                bullet(systemImage: "network", text: "Direct to Valve over HTTPS — no third-party services.")
                bullet(systemImage: "key", text: "Browsing needs no account and no key — a key only adds to it.")
                bullet(systemImage: "arrow.down.circle", text: "Downloads run through Steam's official SteamCMD.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            Spacer(minLength: 6)

            VStack(spacing: 8) {
                Button {
                    hasShown = true
                    dismiss()
                } label: {
                    Text("Start browsing")
                        .frame(maxWidth: 220)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    hasShown = true
                    dismiss()
                    onConfigureOnline()
                } label: {
                    Text("Add a Web API key")
                }
                .buttonStyle(.borderless)

                Button {
                    hasShown = true
                    dismiss()
                    onDownloadByLink()
                } label: {
                    Text("Add from Workshop URL or ID")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 100, height: 100)
            Image(systemName: "cube.transparent")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }
}
#endif
