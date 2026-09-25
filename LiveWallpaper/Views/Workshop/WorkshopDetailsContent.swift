#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The Workshop inspector's write-up: identity, required items, community presets, tags, description
/// and community links. The preview, the scrolling and the download controls belong to the inspector.
struct WorkshopDetailsContent<Actions: View>: View {
    let item: WorkshopQueryItem
    let doctor: SteamCMDDoctorService
    /// nil disables the author link (plain author text).
    var onBrowseCreator: ((String, String?) -> Void)?
    /// nil → tags render as plain labels.
    var onSelectTag: ((String) -> Void)?
    /// Opens another item (Required items rows); nil hides the section.
    var onOpenItem: ((UInt64) -> Void)?
    /// Drawn between the identity header and the required items — the inspector's download row.
    @ViewBuilder var actions: () -> Actions

    @Environment(WorkshopServices.self) private var services
    @State private var descriptionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            identityBlock
            actions()
            requiredItemsGroup
            presetsGroup
            aboutGroup
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: item.id) { _, _ in descriptionExpanded = false }
    }

    // MARK: - Identity

    private var identityBlock: some View {
        WorkshopDetailIdentityHeader(
            item: item,
            isKeyless: services.isKeyless,
            onBrowseCreator: onBrowseCreator
        )
    }

    // MARK: - Groups

    @ViewBuilder
    private var requiredItemsGroup: some View {
        if !item.requiredItemIDs.isEmpty, let onOpenItem {
            GroupBox {
                DetailRequiredItemsSection(itemIDs: item.requiredItemIDs, onOpenItem: onOpenItem)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private var presetsGroup: some View {
        GroupBox {
            DetailPresetsSection(
                wallpaperID: item.id,
                communityURL: item.steamCommunityURL,
                doctor: doctor
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var aboutGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if !item.tags.isEmpty {
                    tagsSection
                }
                descriptionSection
                WorkshopCommunityLinks(itemID: item.id, commentCount: item.commentCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(WorkshopTagTaxonomy.grouped(tags: item.tags), id: \.group) { grouped in
                // Wrapping, not a horizontal scroll: at the inspector's width a scroll leaves
                // most of a group's tags off-screen with nothing to say they are there.
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                    Text(verbatim: grouped.group.displayName)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    WorkshopChipFlow(spacing: 6, lineSpacing: 4) {
                        ForEach(grouped.tags, id: \.self) { tag in
                            tagChip(tag)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        // Raw tag on the wire — Steam matches the English form.
        let label = WorkshopTagLocalization.displayName(tag)
        if let onSelectTag {
            Button { onSelectTag(tag) } label: {
                StatusChip(verbatim: label, tint: .accentColor)
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(label)"))
        } else {
            StatusChip(verbatim: label, tint: .secondary)
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        let text = item.shortDescription
        let placeholder = String(localized: "No description provided.", bundle: .appLanguage, comment: "Placeholder when a Workshop item has no description.")
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Description")
                .font(.headline)
            CollapsibleDescription(text: text.isEmpty ? placeholder : text, isExpanded: $descriptionExpanded)
        }
    }

}

/// The comments (with their count when known), change notes and collections of a Workshop item, as links
/// to its Steam pages: the inspector and both detail modals draw this row.
struct WorkshopCommunityLinks: View {
    let itemID: UInt64
    var commentCount: Int?

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Wrapping, not an HStack: three labelled links do not fit the narrow
        // inspector, and squeezed they hyphenate mid-word ("Com-ments").
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
