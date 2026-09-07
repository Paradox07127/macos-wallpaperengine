#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The detail page's "Required items": the items this one references
/// (`children` on the query payload — for a Preset, the wallpaper it restyles).
/// Titles are resolved by id; an id Steam will not describe still gets a row
/// that links to its Steam page.
struct DetailRequiredItemsSection: View {
    let itemIDs: [UInt64]
    /// Opens the item in the inspector; the target may not be on the current page.
    let onOpenItem: (UInt64) -> Void

    @Environment(WorkshopServices.self) private var services
    @Environment(\.openURL) private var openURL
    /// The grid card's spoiler setting, by its named key (`MatureContentSettings`).
    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blurMatureThumbnails = true
    @State private var outcome: WorkshopItemDetailsLoader.Outcome?
    /// Which ids `outcome` answers: `.task(id:)` re-runs on a new list but
    /// `@State` survives, so the previous item's rows would otherwise stay up.
    @State private var loadedFor: [UInt64] = []
    /// Bumped by Retry so `.task(id:)` runs again for the same ids.
    @State private var attempt = 0
    /// Ephemeral, like the grid card's: a new detail page blurs again.
    @State private var revealedIDs: Set<UInt64> = []
    @State private var pendingRevealID: UInt64?
    @State private var showingAgeConfirm = false

    private struct LoadRequest: Equatable {
        let ids: [UInt64]
        let attempt: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Required items")
                .font(DesignTokens.Typography.bodyEmphasized)
            if let outcome, loadedFor == itemIDs {
                if outcome.transientFailure {
                    transientFailureRow
                } else {
                    ForEach(itemIDs, id: \.self) { id in
                        if let item = outcome.items.first(where: { $0.id == id }) {
                            if Self.opensInApp(item) {
                                itemRow(item)
                            } else {
                                steamOnlyRow(id: item.id, title: item.title, item: item)
                            }
                        } else {
                            steamOnlyRow(id: id, title: WorkshopQueryItem.displayTitle(nil, id: id), item: nil)
                        }
                        if id != itemIDs.last {
                            Divider()
                        }
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading item…"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: LoadRequest(ids: itemIDs, attempt: attempt)) {
            let requested = itemIDs
            let loaded = await services.itemDetails.load(ids: requested)
            guard !Task.isCancelled, requested == itemIDs else { return }
            outcome = loaded
            loadedFor = requested
        }
        .alert("Show mature content?", isPresented: $showingAgeConfirm) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                MatureContentSettings.confirm()
                if let id = pendingRevealID {
                    revealedIDs.insert(id)
                }
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }

    /// Whether the inspector can show the item as a wallpaper. Steam describes
    /// a public Asset or Application like any item, but the inspector would
    /// offer to download it as one.
    nonisolated static func opensInApp(_ item: WorkshopQueryItem) -> Bool {
        !item.tags.contains { tag in
            BrowseViewModel.alwaysExcludedTags.contains { tag.caseInsensitiveCompare($0) == .orderedSame }
        }
    }

    /// The grid card's spoiler rule, for a row that has the item's tags.
    nonisolated static func blursThumbnail(tags: [String], blursMature: Bool) -> Bool {
        blursMature && WorkshopQueryItem.isMatureRated(tags: tags)
    }

    private func isBlurred(_ item: WorkshopQueryItem) -> Bool {
        Self.blursThumbnail(tags: item.tags, blursMature: blurMatureThumbnails) && !revealedIDs.contains(item.id)
    }

    /// Gated by the same one-time 18+ confirmation as the grid card.
    private func requestReveal(_ id: UInt64) {
        if MatureContentSettings.isConfirmed {
            revealedIDs.insert(id)
        } else {
            pendingRevealID = id
            showingAgeConfirm = true
        }
    }

    private var transientFailureRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Couldn’t load required items.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Spacing.xs)
            Button("Retry") {
                outcome = nil
                attempt += 1
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private func itemRow(_ item: WorkshopQueryItem) -> some View {
        let blurred = isBlurred(item)
        return RequiredItemRow(item: item, isBlurred: blurred) {
            if blurred {
                requestReveal(item.id)
            } else {
                onOpenItem(item.id)
            }
        }
    }

    /// An item the inspector cannot show: unresolved (`item` nil), or not a wallpaper.
    private func steamOnlyRow(id: UInt64, title: String, item: WorkshopQueryItem?) -> some View {
        let blurred = item.map(isBlurred) ?? false
        return HStack(spacing: DesignTokens.Spacing.sm) {
            if blurred {
                Button {
                    requestReveal(id)
                } label: {
                    RequiredItemThumbnail(url: item?.previewImageURL, isBlurred: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mature content hidden. Activate to reveal."))
            } else {
                RequiredItemThumbnail(url: item?.previewImageURL, isBlurred: false)
            }
            Text(title)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.xs)
            Button {
                openURL(WorkshopCommunityURL.item(itemID: id))
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help(Text("Open in Steam"))
            .accessibilityLabel(Text("Open in Steam"))
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }
}

/// A resolved required item: a row-sized button that opens it in the inspector
/// — or, while its thumbnail is blurred, asks to reveal it.
private struct RequiredItemRow: View {
    let item: WorkshopQueryItem
    let isBlurred: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                RequiredItemThumbnail(url: item.previewImageURL, isBlurred: isBlurred)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(item.title)
                        .font(DesignTokens.Typography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let author = item.creatorPersonaName {
                        Text(author)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DesignTokens.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(DesignTokens.Typography.captionEmphasized)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .background(
                Color.primary.opacity(isHovering ? DesignTokens.Opacity.hoverFill : 0),
                in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isBlurred ? Text("Mature content hidden. Activate to reveal.") : Text("Show details"))
        .accessibilityHint(isBlurred ? Text("Mature content hidden. Activate to reveal.") : Text("Show details"))
    }
}

struct RequiredItemThumbnail: View {
    let url: URL?
    let isBlurred: Bool

    var body: some View {
        Group {
            if let url {
                WorkshopPreviewImage(url: url)
                    .blur(radius: isBlurred ? 8 : 0)
            } else {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            }
        }
        .frame(width: 32, height: 32)
        .overlay {
            if isBlurred {
                ZStack {
                    Color.black.opacity(0.45)
                    Image(systemName: "eye.slash.fill")
                        .font(DesignTokens.Typography.captionEmphasized)
                        .foregroundStyle(DesignTokens.Colors.overlayForeground)
                }
                .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }
}
#endif
