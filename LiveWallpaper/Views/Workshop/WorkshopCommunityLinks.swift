#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The comments (with their count when known), change notes and collections of a Workshop item, as links
/// to its Steam pages: both detail modals draw this row.
struct WorkshopCommunityLinks: View {
    let itemID: UInt64
    var commentCount: Int?

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Wrapping, not an HStack: three labelled links do not fit a narrow
        // column, and squeezed they hyphenate mid-word ("Com-ments").
        WorkshopChipFlow(spacing: DesignTokens.Spacing.md, lineSpacing: DesignTokens.Spacing.xs) {
            communityLink(commentsTitle, systemImage: "bubble.left", url: WorkshopCommunityURL.comments(itemID: itemID))
            communityLink(Text("Change Notes"), systemImage: "clock.arrow.circlepath", url: WorkshopCommunityURL.changeNotes(itemID: itemID))
            communityLink(Text("Collections"), systemImage: "square.stack", url: WorkshopCommunityURL.collections(itemID: itemID))
        }
        .font(DesignTokens.Typography.caption)
    }

    private var commentsTitle: Text {
        if let commentCount, commentCount > 0 {
            return Text("\(commentCount) comments", comment: "Workshop detail link to the item's comment thread. Placeholder is the comment count.")
        }
        return Text("Comments")
    }

    private func communityLink(_ title: Text, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label { title } icon: { Image(systemName: systemImage) }
        }
        .buttonStyle(.link)
        .fixedSize()
    }
}
#endif
