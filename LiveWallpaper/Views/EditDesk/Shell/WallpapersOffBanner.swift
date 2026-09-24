import LiveWallpaperCore
import SwiftUI

/// Hangs over the resting overview while the master switch is off, with the way back on.
struct WallpapersOffBanner: View {
    let turnOn: () -> Void

    var body: some View {
        InlineNoticeBanner(
            tint: DesignTokens.Colors.Status.info,
            symbol: "power",
            title: Text(
                "Wallpapers Are Turned Off",
                comment: "Home page banner title while the master switch keeps every wallpaper off."
            ),
            message: Text(
                "Displays show no wallpaper until you turn wallpapers back on.",
                comment: "Home page banner message while the master switch keeps every wallpaper off."
            ),
            surface: .chrome
        ) {
            Button(action: turnOn) {
                Text("Turn Wallpapers On", comment: "Home page banner button that turns the master wallpaper switch back on.")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}
