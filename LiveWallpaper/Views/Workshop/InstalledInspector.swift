#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import SwiftUI

/// Trailing detail inspector for an installed item. Apply happens here
/// (per-display via the mini-map, or "All"); drag-onto-display is the quick path.
struct WPEInstalledInspectorContent: View {
    /// Derived boolean state for the item (bookmark + update availability), grouped so the caller sets a labelled bundle rather than four loose same-typed flags.
    struct ItemState {
        let isBookmarked: Bool
        let canBookmark: Bool
        let hasUpdate: Bool
        let canUpdate: Bool
    }

    /// Per-item callbacks. `onSelectTag` is wired only when tags should be
    /// tappable (jump to Browse Online by tag).
    struct Actions {
        let onApply: (Screen) -> Void
        let onApplyToAll: () -> Void
        let onUpdate: () -> Void
        let onToggleBookmark: () -> Void
        let onShowInFinder: () -> Void
        let onDelete: () -> Void
        let onSelectTag: ((String) -> Void)?
    }

    let entry: WPEHistoryEntry
    let screens: [Screen]
    let activeScreenIDs: Set<CGDirectDisplayID>
    let state: ItemState
    let actions: Actions

    @Environment(\.openURL) private var openURL
    @Environment(SteamCMDDoctorService.self) private var doctor
    @State private var showingApplyPopover = false
    /// WPE metadata read from the item's local `project.json` — no Steam API.
    /// nil until the off-main read completes; reloaded when the entry changes.
    @State private var localInfo: LocalProjectInfo?
    @State private var localInfoLoadOwner = WorkshopInstalledLocalInfoLoadOwner()
    @State private var descriptionExpanded = false

    /// Shared singleton — reading it here makes this view observe the
    /// re-download's phase + progress.
    private var downloadCoordinator: WorkshopDownloadCoordinator { .shared }
    private var itemID: UInt64? { UInt64(entry.origin.workshopID) }
    private var updatePhase: WorkshopDownloadCoordinator.DownloadPhase {
        guard let itemID else { return .idle }
        return downloadCoordinator.phase(for: itemID)
    }
    private var isUpdateRetry: Bool {
        if case .failed = updatePhase { return true }
        return false
    }
    private var localInfoLoadIdentity: WorkshopInstalledLocalInfoLoadIdentity {
        WorkshopInstalledLocalInfoLoadIdentity(entryID: entry.id, importedAt: entry.importedAt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                hero
                // Three groups under the hero instead of eight blocks separated
                // by spacing alone: what this is, what you can do with it, what
                // the author said. Same `GroupBox` container the settings pages
                // use, so the inspector doesn't invent a fourth card style.
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    identityBlock
                    actionsGroup
                    presetsGroup
                    aboutGroup
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignTokens.Colors.pageBackground)
        .task(id: localInfoLoadIdentity) {
            let ticket = localInfoLoadOwner.begin(identity: localInfoLoadIdentity)
            descriptionExpanded = false
            let loadedInfo = await loadWPELocalProjectInfo(for: entry)
            guard localInfoLoadOwner.canPublish(ticket) else { return }
            localInfo = loadedInfo
        }
        .onDisappear { localInfoLoadOwner.invalidate() }
    }

    /// Uncarded on purpose: it names the thing the cards below act on, so a
    /// container around it would read as one more peer section.
    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(verbatim: entry.origin.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.xs) {
                typePill
                if let rating = localInfo?.contentRating, !rating.isEmpty {
                    contentRatingPill(rating)
                }
            }
            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if state.hasUpdate {
                    updateSection
                }
                unsupportedWarning
                if !activeScreenIDs.isEmpty {
                    inUseRow
                }
                applySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    /// Presets for a wallpaper you already own are worth reaching without going
    /// back to the online tab. Workshop items only — a folder import has no id.
    @ViewBuilder
    private var presetsGroup: some View {
        if let itemID, let steamURL {
            GroupBox {
                DetailPresetsSection(
                    wallpaperID: itemID,
                    communityURL: steamURL,
                    doctor: doctor
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    @ViewBuilder
    private var aboutGroup: some View {
        if let info = localInfo, info.hasContent {
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    if let description = info.cleanedDescription, !description.isEmpty {
                        descriptionSection(description)
                    }
                    if !info.tags.isEmpty {
                        tagsSection(info.tags)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private var hero: some View {
        WPEPreviewView(
            imageURL: entry.origin.sourcePreviewURL,
            securityScopedBookmarkData: entry.origin.sourceFolderBookmark,
            playbackMode: .hoverToPlay,
            previewSize: .tile
        )
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
        .padding([.horizontal, .top], DesignTokens.Spacing.lg)
    }

    /// All local (no API). Size shows instantly from the persisted measurement,
    /// or once the first off-main folder scan lands; the date is always available.
    private var metaRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Group {
                if let bytes = entry.sizeBytes ?? localInfo?.sizeBytes, bytes > 0 {
                    Label {
                        Text(verbatim: WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: bytes))
                    } icon: {
                        Image(systemName: "internaldrive")
                    }
                }
                Label {
                    Text(entry.importedAt, format: .dateTime.year().month().day())
                } icon: {
                    Image(systemName: "calendar")
                }
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Spacer(minLength: DesignTokens.Spacing.sm)

            if state.canBookmark || state.isBookmarked {
                plainIconButton(
                    state.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: state.isBookmarked ? "bookmark.fill" : "bookmark",
                    tint: state.isBookmarked ? AnyShapeStyle(DesignTokens.Colors.rating) : AnyShapeStyle(.secondary),
                    action: actions.onToggleBookmark
                )
            }
            if let url = steamURL {
                plainIconButton("Steam", systemImage: "arrow.up.forward.app", tint: AnyShapeStyle(.secondary)) {
                    openURL(url)
                }
            }
        }
    }

    private func plainIconButton(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        tint: AnyShapeStyle,
        size: CGFloat = 13,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(titleKey))
        .accessibilityLabel(Text(titleKey))
    }

    private var typePill: some View {
        TypeBadge(entry.origin.localizedDisplayTypeName, systemImage: entry.origin.originalType.symbolName)
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Update available on Steam", systemImage: "arrow.triangle.2.circlepath")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(DesignTokens.Colors.Status.warning)

            switch updatePhase {
            case .downloading, .importing:
                updateProgressRow
            default:
                Button(action: actions.onUpdate) {
                    Label(isUpdateRetry ? "Retry Update" : "Update", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.canUpdate)
                .help(state.canUpdate
                      ? Text("Re-download the latest version from Steam")
                      : Text("Set up SteamCMD in Settings → Workshop to enable updates."))

                if case .failed(let message) = updatePhase {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !state.canUpdate {
                    Text("Updates need Loomscreen's background Steam connector.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var updateProgressRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let itemID, let fraction = downloadCoordinator.progress[itemID] {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(updatePhase == .importing ? "Importing…" : "Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                if let itemID { downloadCoordinator.cancel(itemID) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Cancel update"))
            .accessibilityLabel(Text("Cancel update"))
        }
    }

    @ViewBuilder
    private var unsupportedWarning: some View {
        if entry.origin.originalType == .application || entry.origin.originalType == .unknown {
            Label("This is a Windows-only wallpaper and can't run on macOS.", systemImage: "exclamationmark.triangle.fill")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inUseRow: some View {
        let names = screens.filter { activeScreenIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        return Label("In use on \(names)", systemImage: "checkmark.circle.fill")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.Status.active)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var applySection: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            applyControl
            plainIconButton("Show in Finder", systemImage: "folder", tint: AnyShapeStyle(.secondary), size: 15, action: actions.onShowInFinder)
            plainIconButton("Remove", systemImage: "trash", tint: AnyShapeStyle(DesignTokens.Colors.Status.danger), size: 15, action: actions.onDelete)
        }
    }

    @ViewBuilder
    private var applyControl: some View {
        if screens.isEmpty {
            Button {} label: {
                Label("Apply", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(true)
            .help(Text("Open a display first, then apply"))
        } else if screens.count == 1, let only = screens.first {
            Button { actions.onApply(only) } label: {
                Label("Apply to \(only.name)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        } else {
            Button { showingApplyPopover = true } label: {
                Label("Apply", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .popover(isPresented: $showingApplyPopover, arrowEdge: .bottom) {
                AppLanguageScope(defaults: .appScoped()) {
                    WorkshopApplyTargetPicker(
                        screens: screens,
                        activeScreenIDs: activeScreenIDs,
                        onPick: { actions.onApply($0); showingApplyPopover = false },
                        onAll: { actions.onApplyToAll(); showingApplyPopover = false }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Description").font(.headline)
            CollapsibleDescription(
                text: text,
                isExpanded: $descriptionExpanded
            )
        }
    }

    private func tagsSection(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    /// Tappable accent chip when `onSelectTag` is wired; otherwise inert.
    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        if let onSelectTag = actions.onSelectTag {
            Button { onSelectTag(tag) } label: {
                StatusChip(verbatim: tag, tint: .accentColor)
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(tag)"))
        } else {
            StatusChip(verbatim: tag, tint: .secondary)
        }
    }

    private func contentRatingPill(_ rating: String) -> some View {
        StatusChip(verbatim: rating.uppercased(with: .current), tint: contentRatingTint(rating))
    }

    private func contentRatingTint(_ rating: String) -> Color {
        switch rating.lowercased() {
        case "everyone": return .green
        case "questionable": return .orange
        case "mature": return .red
        default: return .gray
        }
    }

    private var steamURL: URL? {
        guard UInt64(entry.origin.workshopID) != nil else { return nil }
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(entry.origin.workshopID)")
    }
}

#endif
