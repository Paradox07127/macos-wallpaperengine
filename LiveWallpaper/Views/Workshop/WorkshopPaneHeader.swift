#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Shared Workshop header hosted inside each tab's main split column.
struct WorkshopPaneHeader: View {
    let selectedTab: WorkshopPaneTab
    let installedCount: Int
    let onPaste: () -> Void

    @Environment(WorkshopServices.self) private var services

    /// Same `DetailHeaderBar` as Bookmarks and Apple Aerials — this pane used to
    /// hand-roll an identical icon/title/metadata/actions row, so the three
    /// library headers drifted apart on spacing and type.
    var body: some View {
        DetailHeaderBar(
            systemImage: "cube.transparent.fill",
            title: { Text("Steam Workshop") },
            metadata: { headerStatView },
            actions: { headerActions }
        )
    }

    /// On Workshop, prefixes the request count with the API-key status seal so
    /// key health and today's request count read in one place.
    private var headerStatView: some View {
        HStack(spacing: 4) {
            if selectedTab == .browseOnline, services.hasWebAPIKey {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Colors.Status.active)
                    .accessibilityHidden(true)
            }
            Text(verbatim: headerStat)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(selectedTab == .browseOnline && services.hasWebAPIKey
            ? Text("Steam doesn't expose remaining quota; this counts only the requests this Mac has issued today.")
            : Text(""))
    }

    private var headerStat: String {
        switch selectedTab {
        case .installed:
            return String(localized: "\(installedCount) installed", comment: "Workshop header stat: number of installed wallpapers.")
        case .browseOnline:
            if !services.hasWebAPIKey {
                return String(localized: "API key required", comment: "Workshop header stat when no Steam Web API key is set.")
            }
            return String(localized: "\(WorkshopRequestCounter.countForToday()) API requests today", comment: "Workshop header stat: Steam Web API requests issued today.")
        }
    }

    // Folder import moved to the toolbar's single add button, which routes any
    // picked file or folder — including a Workshop library root — by what it is.
    // Circle glass at `.large`, matching the other pages' header actions.
    private var headerActions: some View {
        Button(action: onPaste) {
            Image(systemName: "link.badge.plus")
        }
        .adaptiveGlassButton(.regular, shape: .circle)
        .controlSize(.large)
        .help(Text("Add a Steam Workshop item by URL or ID"))
        .accessibilityLabel(Text("Add from Workshop URL or ID"))
    }
}
#endif
