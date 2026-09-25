#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// SCREENS.md S8b: a Workshop item in the library modal's layout. The preview is the animated one,
/// the rows and chips are Steam's, and a display button downloads the item and applies it there.
@MainActor
struct WorkshopModal: View {
    let content: WorkshopModalContent
    let doctor: SteamCMDDoctorService
    let facts: [WallpaperFact]
    let row: WorkshopModalButtonRow
    let download: WorkshopDownloadPresentation
    /// The library's copy when this Mac can't run it; the right column says why. nil otherwise.
    let unsupportedOrigin: WPEOrigin?
    /// The mature reveal lives in the page's `MatureRevealState`, so it survives closing this modal.
    let isRevealed: Bool
    /// The same state, for the dependency and preset rows: R-24 ④ shares one reveal set.
    let matureReveal: MatureRevealState?
    let navigation: ModalNavigation
    /// The stage's own `bounds.size`. A `GeometryReader` here would measure one title bar short.
    let windowSize: CGSize
    /// Height the scrim leaves untouched so the traffic lights and window drag still work.
    let titlebarInset: CGFloat
    let onDismiss: () -> Void
    let actions: WorkshopModalActions

    @Environment(WorkshopServices.self) private var services
    @Environment(\.openURL) private var openURL
    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blursMature = true
    @State private var showingAgeConfirm = false
    @State private var descriptionExpanded = false

    private var item: WorkshopQueryItem {
        content.item
    }

    private var shouldBlurPreview: Bool {
        blursMature && item.isMatureRated && !isRevealed
    }

    var body: some View {
        EditDeskModalChrome(
            windowSize: windowSize,
            titlebarInset: titlebarInset,
            title: item.title,
            actions: [ModalHeaderAction(kind: .openInSteam, perform: actions.openInSteam)],
            onDismiss: onDismiss,
            onTargetShortcut: pressByShortcut
        ) { _ in
            WallpaperDetailLayout(
                facts: facts,
                tags: WallpaperFacts.chips(item.tags),
                authorLink: authorLink,
                onSelectTag: actions.selectTag,
                onPrevious: navigation.canGoPrevious ? { navigation.previous() } : nil,
                onNext: navigation.canGoNext ? { navigation.next() } : nil,
                preview: { preview },
                sidebar: { sidebar },
                status: { status },
                buttons: { buttons }
            )
            .id(item.id)
        }
        .alert("Show mature content?", isPresented: $showingAgeConfirm) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                MatureContentSettings.confirm()
                actions.reveal()
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }

    // MARK: Preview

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge, style: .continuous)
    }

    /// The whole animation fitted into the layout's 4:3 box. A Button keeps one view identity across the
    /// reveal: branching on the blur would rebuild the thumbnail and lose its unblur animation.
    private var preview: some View {
        Button {
            guard shouldBlurPreview else { return }
            if MatureContentSettings.isConfirmed {
                actions.reveal()
            } else {
                showingAgeConfirm = true
            }
        } label: {
            ZStack {
                DesignTokens.Colors.surfaceSunken
                AnimatedGIFThumbnail(
                    url: item.previewImageURL,
                    playbackMode: .autoPlay,
                    showsPlayingBadge: false,
                    previewSize: .hero,
                    isBlurred: shouldBlurPreview,
                    contentMode: .fit
                )
            }
            .clipShape(previewShape)
            .overlay(previewShape.strokeBorder(DesignTokens.EditDesk.Colors.strokeBadge, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                mediaChip(Text("▶ GIF preview"))
                    .padding(DesignTokens.EditDesk.Spacing.s8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(shouldBlurPreview)
        .accessibilityHidden(!shouldBlurPreview)
        .accessibilityLabel(Text("Show mature content?"))
    }

    private func mediaChip(_ label: Text) -> some View {
        label
            .font(DesignTokens.EditDesk.Typography.metaMono)
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip, style: .continuous)
                    .fill(DesignTokens.EditDesk.Colors.mediaChipFill)
            )
    }

    /// The inspector's author line picks the same way: Steam's own page when there is no key to browse with.
    private var authorLink: WallpaperAuthorLink? {
        guard let author = item.creatorPersonaName, !author.isEmpty, let creatorID = item.creatorID else { return nil }
        if services.isKeyless {
            return WallpaperAuthorLink(
                symbol: "arrow.up.right.square",
                help: String(localized: "Open \(author)’s Workshop on Steam", bundle: .appLanguage)
            ) { openURL(WorkshopCommunityURL.creatorWorkshop(steamID: creatorID)) }
        }
        guard let browseCreator = actions.browseCreator else { return nil }
        return WallpaperAuthorLink(
            symbol: "chevron.right",
            help: String(localized: "Show more wallpapers from \(author)", bundle: .appLanguage)
        ) { browseCreator(creatorID, author) }
    }

    // MARK: Right column

    /// Notices first, then the description, the required items, the presets and the Steam links.
    @ViewBuilder
    private var sidebar: some View {
        if let unsupportedOrigin {
            UnsupportedProjectNotice(origin: unsupportedOrigin, showsIdentity: true)
        }
        if item.isBanned {
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.danger,
                symbol: "xmark.octagon.fill",
                title: Text("Unavailable — removed or hidden on Steam")
            )
        }
        WallpaperDetailSection(title: Text("Description")) {
            CollapsibleDescription(
                text: item.shortDescription.isEmpty
                    ? String(localized: "No description provided.", bundle: .appLanguage, comment: "Placeholder when a Workshop item has no description.")
                    : item.shortDescription,
                isExpanded: $descriptionExpanded,
                collapsedLineLimit: 4
            )
        }
        if !requiredItemIDs.isEmpty {
            DetailRequiredItemsSection(itemIDs: requiredItemIDs, onOpenItem: actions.openItem, matureReveal: matureReveal)
        }
        DetailPresetsSection(
            wallpaperID: item.id, communityURL: item.steamCommunityURL, doctor: doctor, matureReveal: matureReveal
        )
        WorkshopCommunityLinks(itemID: item.id, commentCount: item.commentCount)
    }

    /// The unsupported-project notice already lists the missing ones, so the section would repeat them.
    private var requiredItemIDs: [UInt64] {
        guard unsupportedOrigin?.missingDependencyIDs.isEmpty ?? true else { return [] }
        return item.requiredItemIDs
    }

    // MARK: Bottom

    @ViewBuilder
    private var status: some View {
        if download != WorkshopDownloadPresentation() {
            ModalDownloadStatusLine(presentation: download)
        }
    }

    private var buttons: some View {
        ModalDisplayButtons(
            targets: row.targets,
            canApply: row.canPress,
            mode: row.mode,
            applyTo: actions.press,
            extras: row.extras.map { extra in
                ModalExtraButton(title: extra.kind.title, isEnabled: extra.isEnabled, action: perform(extra.kind))
            }
        )
    }

    private func perform(_ kind: WorkshopModalButtonRow.ExtraKind) -> @MainActor () -> Void {
        switch kind {
        case .saveOnly, .cancelAutoApply: actions.saveOnly
        case .cancelDownload: actions.cancelDownload
        case .connectSteam: actions.connectSteam
        }
    }

    // MARK: Keyboard

    /// ⌘1…⌘9 press that display's button, as a click would.
    private func pressByShortcut(_ index: Int) {
        guard let target = ModalKeyMap.target(forShortcut: index, in: row.targets),
              ModalDisplayButtons.isEnabled(target, canApply: row.canPress, mode: row.mode) else { return }
        actions.press(target.id)
    }
}
#endif
