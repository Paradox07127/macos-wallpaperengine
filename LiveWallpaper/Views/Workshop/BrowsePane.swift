#if !LITE_BUILD
import Combine
import LiveWallpaperCore
import SwiftUI

/// Which shell hosts the grid. It decides layout only: the pager, banners, filters, skeleton and
/// query behaviour are the same either way.
enum BrowsePresentation {
    /// The old Workshop window: grid plus a resizable inspector column.
    case legacy
    /// SCREENS S8: grid alone, at a fixed six-column preset, items open through `onOpenItem`.
    case editDesk
}

struct BrowsePane: View {
    @Environment(\.libraryTileSize) private var tileSize
    let viewModel: BrowseViewModel
    let doctor: SteamCMDDoctorService
    let onRequestKeyEntry: () -> Void
    /// Downloading a pasted id needs SteamCMD but no Web API key.
    var onDownloadByLink: (() -> Void)?
    var presentation: BrowsePresentation = .legacy
    /// Where an opened item goes when there is no inspector to put it in.
    var onOpenItem: ((WorkshopQueryItem) -> Void)?
    /// nil keeps each card's reveal in its own `@State`; a state makes reveals outlive the tiles.
    var matureReveal: MatureRevealState?

    @Environment(WorkshopServices.self) private var services
    @Environment(ScreenManager.self) private var screenManager
    /// An id, not a value copy: the inspector follows the grid when a page
    /// turn or the persona pass replaces `viewModel.items`.
    @State private var selectedID: UInt64?
    /// An item opened from a Required items row, which need not be on the
    /// current page; resolved once through `services.itemDetails`.
    @State private var detachedItem: WorkshopQueryItem?
    /// The off-page open in flight, if any; `onChange(of: items)` must not
    /// clear its id while the fetch runs.
    @State private var pendingOpen: BrowseSelection.PendingOpen?
    /// Tells two opens of the same id apart, so the first fetch landing cannot
    /// settle the second.
    @State private var openGeneration = 0
    @State private var inspectorHidden = false
    @State private var rateLimitRemaining: TimeInterval = 0
    /// Read here, once, and handed to every tile: the cards are `EquatableView`s
    /// and cannot observe the environment from inside their own `body`.
    @Environment(\.galleryCardPreferences) private var cardPreferences
    @State private var pageJumpText: String = "1"
    @State private var installedWorkshopIDs: Set<String> = []
    @State private var importedAtByWorkshopID: [String: Date] = [:]
    /// Workshop ID → the ON badge of the displays running that project.
    @State private var inUseBadges: [String: String] = [:]
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1", store: .appScoped()) private var hidesDownloadedPref = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Workshop.Browse.InspectorWidth", store: .appScoped()) private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let gridTopAnchor = "workshop.browse.grid.top"

    var body: some View {
        layout
        .onAppear {
            rateLimitRemaining = currentRateLimitRemaining
            reloadInstalledIDs()
            viewModel.hidesDownloadedInBrowse = hidesDownloadedPref
            Task {
                await services.refreshAPIKeyStatus()
                viewModel.onAppear()
            }
        }
        .onChange(of: hidesDownloadedPref) { _, hide in
            viewModel.hidesDownloadedInBrowse = hide
        }
        // Either direction changes which backend serves Browse, and page size and the
        // genre form differ per path — so rebuild the query from page 1 rather than
        // leaving results from the other path on screen.
        .onChange(of: services.isKeyless) { _, _ in
            Task { await viewModel.browsePathChanged() }
        }
        // Guarded: this fires every second for the whole session, and writing `@State`
        // invalidates the grid's `ForEach` — every visible card would rebuild its
        // tooltip, context menu, accessibility actions and badge glass once a second.
        .onReceive(ticker) { _ in
            let next = currentRateLimitRemaining
            guard next != rateLimitRemaining else { return }
            rateLimitRemaining = next
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            reloadInstalledIDs()
        }
        // Read per request but pushed by nothing: without this the grid keeps
        // showing (or hiding) presets until the next filter change.
        .onReceive(NotificationCenter.default.publisher(for: .workshopPresetVisibilityDidChange)) { _ in
            Task { await viewModel.reload() }
        }
        .onChange(of: viewModel.items) { _, items in
            guard !BrowseSelection.keepsSelection(
                id: selectedID, in: items, detached: detachedItem, pending: pendingOpen?.id
            ) else { return }
            selectedID = nil
        }
    }

    /// The only place the two presentations differ: whether the grid is wrapped in a split with an
    /// inspector column, and which page background it sits on.
    @ViewBuilder
    private var layout: some View {
        if presentation == .editDesk {
            mainColumn
                .background(DesignTokens.EditDesk.Colors.background)
        } else {
            InspectorSplit(
                isMounted: true,
                isVisible: isInspectorVisible,
                animationTrigger: AnyHashable(isInspectorVisible),
                reduceMotion: reduceMotion,
                storedWidth: $inspectorWidth,
                liveWidth: $liveInspectorWidth,
                minWidth: DesignTokens.Inspector.minWidth,
                maxWidth: DesignTokens.Inspector.maxWidth,
                onClose: { inspectorHidden = true },
                main: { mainColumn },
                inspector: { width in inspectorColumn(width: width) }
            )
            .background(DesignTokens.Colors.pageBackground)
            .toolbar {
                if selectedID != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            inspectorHidden.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help(Text(inspectorHidden ? "Show details" : "Hide details"))
                        .accessibilityLabel(Text("Toggle details panel"))
                    }
                }
            }
        }
    }

    private var selectedItem: WorkshopQueryItem? {
        BrowseSelection.resolve(id: selectedID, in: viewModel.items, detached: detachedItem)
    }

    private var isInspectorVisible: Bool {
        selectedID != nil && !inspectorHidden
    }

    /// Opens an item by id, which may not be on this page. Off-page ids are fetched
    /// once; an id Steam will not describe leaves the previous selection in place.
    private func openItem(_ id: UInt64) {
        // With no inspector the resolved item leaves through the callback; the chain below still
        // runs for ids that are not on this page.
        if presentation == .editDesk,
           let item = BrowseSelection.resolve(id: id, in: viewModel.items, detached: detachedItem) {
            onOpenItem?(item)
            return
        }
        inspectorHidden = false
        guard !viewModel.items.contains(where: { $0.id == id }), detachedItem?.id != id else {
            selectedID = id
            return
        }
        openGeneration += 1
        let open = BrowseSelection.PendingOpen(
            id: id, generation: openGeneration, previousSelectedID: selectedID, previousDetached: detachedItem
        )
        pendingOpen = open
        selectedID = id
        detachedItem = nil
        Task {
            let outcome = await services.itemDetails.load(ids: [id])
            guard pendingOpen?.generation == open.generation else { return }
            pendingOpen = nil
            guard selectedID == id else { return }
            let settled = open.settle(with: outcome.items.first, in: viewModel.items)
            selectedID = settled.selectedID
            detachedItem = settled.detached
            if presentation == .editDesk,
               let item = BrowseSelection.resolve(
                   id: settled.selectedID, in: viewModel.items, detached: settled.detached
               ) {
                onOpenItem?(item)
            }
        }
    }

    private var mainColumn: some View {
        gridColumn
            .onAppear { reloadInUseBadges() }
            .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { _ in
                reloadInUseBadges()
            }
    }

    private var gridColumn: some View {
        VStack(spacing: 0) {
            filterBand
            Divider()
            keyRejectedBanner
            content
                .overlay(alignment: .top) { rateLimitBanner }
        }
    }

    @ViewBuilder
    private var keyRejectedBanner: some View {
        if viewModel.showsKeyRejectedNotice {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                    .accessibilityHidden(true)
                Text("Steam rejected the saved API key. Browsing without it.")
                    .font(DesignTokens.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open Settings") {
                    NotificationCenter.default.post(
                        name: .openSettingsSection,
                        object: nil,
                        userInfo: [
                            "destination": SettingsNavigation.workshopSetup.rawValue,
                            "anchor": SettingsSearchAnchor.workshopSetup.rawValue,
                        ]
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    viewModel.dismissKeyRejectedNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(
                DesignTokens.Colors.Status.warning.opacity(DesignTokens.Opacity.activeFill),
                in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
            )
            .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
            .padding(.top, DesignTokens.LibraryFilterBar.verticalPadding)
        }
    }

    @ViewBuilder
    private var filterBand: some View {
        if let creator = viewModel.creatorFilter {
            creatorFilterBanner(creator)
                .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
                .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
        } else if let tag = viewModel.pinnedTag {
            tagFilterBanner(tag)
                .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
                .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
        } else {
            // The keyless path applies the same server-side filters (browsesort / days /
            // requiredtags / excludedtags), so the ribbon stays live without a key.
            BrowseFilterRibbon(
                viewModel: viewModel,
                hasWebAPIKey: services.hasWebAPIKey || viewModel.usesKeylessSearch
            )
        }
    }

    private func inspectorColumn(width: CGFloat) -> some View {
        Group {
            if let selectedItem {
                WorkshopInspectorContent(
                    item: selectedItem,
                    doctor: doctor,
                    onBrowseCreator: { steamID, name in
                        selectedID = nil
                        Task { await viewModel.browseCreator(steamID: steamID, name: name) }
                    },
                    onSelectTag: { tag in
                        selectedID = nil
                        Task { await viewModel.browseTag(tag) }
                    },
                    onOpenItem: { openItem($0) }
                )
            } else if selectedID != nil {
                // Off-page id still being resolved.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text("Loading item…"))
            } else {
                inspectorPlaceholder
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        // A failure with the pager live (a page turn off an all-filtered or later page)
        // belongs to the grid branch; the full-pane error state has no way back.
        if let error = viewModel.lastError, viewModel.items.isEmpty, !viewModel.isRateLimited,
           !viewModel.currentPageIsFilteredOut {
            if viewModel.usesKeylessSearch {
                publicSearchFailedState(error)
            } else {
                errorState(error)
            }
        } else if !viewModel.hasLoadedPage, viewModel.isLoading {
            loadingSkeleton
        } else if viewModel.items.isEmpty, !viewModel.currentPageIsFilteredOut {
            emptyState
        } else {
            populatedGrid
                .opacity(viewModel.isLoading ? DesignTokens.Opacity.disabledContent : 1)
        }
    }

    private var populatedGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.gridTopAnchor)

                    if viewModel.items.isEmpty {
                        filteredPageNote
                    } else if viewModel.displayedItems.isEmpty {
                        scopeEmptyNote
                    } else {
                        LibraryGalleryGrid(size: tileSize, aspect: .square, columnWidth: gridColumnWidth) {
                            ForEach(viewModel.displayedItems) { item in
                                browseCard(for: item)
                                    .equatable()
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
                    }

                    paginationBar
                }
                .frame(maxWidth: .infinity)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = nil }
                )
            }
            // Opening the inspector reflows rows and can push the selected tile off-screen — re-center it.
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: viewModel.pageIndex) { _, _ in
                proxy.scrollTo(Self.gridTopAnchor, anchor: .top)
            }
        }
    }

    private func browseCard(for item: WorkshopQueryItem) -> BrowseCard {
        BrowseCard(
            item: item,
            isInLibrary: installedWorkshopIDs.contains(String(item.id)),
            hasUpdate: hasUpdate(item),
            inUseBadge: inUseBadges[String(item.id)],
            isSelected: selectedID == item.id,
            cardPreferences: cardPreferences,
            reduceMotion: reduceMotion,
            canDownload: doctor.isDownloadReady,
            presentation: presentation,
            isRevealed: matureReveal?.isRevealed(item.id) ?? false,
            onReveal: matureReveal.map { state in { state.reveal(item.id) } },
            onSelect: {
                guard presentation != .editDesk else {
                    openItem(item.id)
                    return
                }
                if selectedID == item.id {
                    selectedID = nil
                } else {
                    selectedID = item.id
                    detachedItem = nil
                    inspectorHidden = false
                }
            },
            onDownload: {
                WorkshopDownloadCoordinator.shared.download(
                    itemID: item.id,
                    title: item.title,
                    using: doctor
                )
            }
        )
    }

    @ViewBuilder
    private var pagingErrorBar: some View {
        if let error = viewModel.lastError, viewModel.showsPagingError, !viewModel.isRateLimited {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let target = viewModel.failedPageTarget {
                        Text("Couldn’t load page \(target).")
                            .font(DesignTokens.Typography.captionEmphasized)
                    }
                    Text(verbatim: message(for: error))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let target = viewModel.failedPageTarget {
                    Button("Retry") { Task { await viewModel.goToPage(target) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isPaging || viewModel.isLoading)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(
                DesignTokens.Colors.Status.warning.opacity(DesignTokens.Opacity.activeFill),
                in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var paginationBar: some View {
        if viewModel.pageIndex > 1 || viewModel.canGoNextPage {
            VStack(spacing: DesignTokens.Spacing.md) {
                pagingErrorBar
                pagerControls
            }
            .padding(.vertical, DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity)
            .onAppear { pageJumpText = String(viewModel.pageIndex) }
            .onChange(of: viewModel.pageIndex) { _, page in pageJumpText = String(page) }
        }
    }

    private var pagerControls: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button {
                Task { await viewModel.goToPrevPage() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Previous Page")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!viewModel.canGoPrevPage)

            HStack(spacing: 4) {
                if viewModel.isPaging {
                    ProgressView().controlSize(.small)
                }
                Text("Page")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                TextField("", text: $pageJumpText)
                    .frame(width: 46)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .contentShape(Capsule())
                    .monospacedDigit()
                    .disabled(viewModel.isPaging || viewModel.isLoading)
                    .onSubmit { jumpToTypedPage() }
                if let total = viewModel.totalPages {
                    Text("of \(total)")
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await viewModel.goToNextPage() }
            } label: {
                HStack(spacing: 4) {
                    Text("Next Page")
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!viewModel.canGoNextPage)
        }
    }

    private func jumpToTypedPage() {
        guard let page = Int(pageJumpText.trimmingCharacters(in: .whitespaces)) else {
            pageJumpText = String(viewModel.pageIndex)
            return
        }
        Task {
            await viewModel.goToPage(page)
            // A clamped or same-page target leaves pageIndex unchanged, so
            // .onChange never fires — reset the field unconditionally.
            pageJumpText = String(viewModel.pageIndex)
        }
    }

    /// nil follows the user's tile-size preference; S8 pins the Edit Desk page to six columns.
    private var gridColumnWidth: CGFloat? {
        presentation == .editDesk ? DesignTokens.LibraryGrid.workshopBrowseColumnWidth : nil
    }

    private var loadingSkeleton: some View {
        ScrollView {
            LibraryGalleryGrid(size: tileSize, aspect: .square, columnWidth: gridColumnWidth) {
                ForEach(0..<6, id: \.self) { _ in
                    WorkshopSkeletonCard()
                }
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        }
        .accessibilityLabel(Text("Loading Workshop results"))
    }

    /// The title is the classified cause, exactly as the keyed path reports it: the
    /// public page's timeouts, unreachable hosts and HTTP statuses are acted on differently.
    private func publicSearchFailedState(_ error: WorkshopQueryError) -> some View {
        IllustratedEmptyState(
            symbol: "exclamationmark.triangle.fill",
            verbatimTitle: message(for: error),
            message: "Couldn’t load results from the Steam Workshop page.",
            symbolColor: DesignTokens.Colors.Status.warning,
            primary: EmptyStateButtonAction("Retry") { Task { await viewModel.reload() } },
            secondary: EmptyStateButtonAction("Set Web API key") { onRequestKeyEntry() }
        ) {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Text(verbatim: WorkshopAPIKeyOwnershipInfo.prerequisitesLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Text("[Get a key](https://steamcommunity.com/dev/apikey)  ·  [Steam Web API TOU](https://steamcommunity.com/dev/apiterms)  ·  [About Limited Accounts](https://help.steampowered.com/en/faqs/view/71D3-35C2-AD96-AA3A)")
                    .font(.caption)
                    .tint(Color.accentColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                if let onDownloadByLink {
                    VStack(spacing: DesignTokens.Spacing.xs) {
                        Button(action: onDownloadByLink) {
                            Label("Or download by link", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Text(verbatim: String(
                            localized: "Paste a Workshop URL to install an item directly, without searching.",
                            bundle: .appLanguage, comment: "Workshop Browse fallback hint next to the “Or download by link” button."
                        ))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .padding(.top, DesignTokens.Spacing.xs)
                }

                Text(verbatim: WorkshopAPIKeyOwnershipInfo.passwordReassurance)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
    }

    private var inspectorPlaceholder: some View {
        IllustratedEmptyState(
            symbol: "square.dashed",
            title: "Select a wallpaper to see details.",
            variant: .compact
        )
    }

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "magnifyingglass",
            verbatimTitle: emptyMessage,
            primary: hasActiveFilters
                ? EmptyStateButtonAction("Clear filters") { clearFilters() }
                : nil
        )
    }

    /// Shown inside the grid when Steam's page held only items the client drops
    /// (shells, Application / Preset), so Prev / Next stay reachable.
    private var filteredPageNote: some View {
        IllustratedEmptyState(
            symbol: "line.3.horizontal.decrease.circle",
            title: "No items on this page can be shown.",
            variant: .compact
        )
    }

    private var scopeEmptyNote: some View {
        IllustratedEmptyState(
            symbol: "sparkles",
            title: "Every item on this page is already in your library.",
            primary: EmptyStateButtonAction("Show downloaded items") { hidesDownloadedPref = false },
            variant: .compact
        )
    }

    private func errorState(_ error: WorkshopQueryError) -> some View {
        IllustratedEmptyState(
            symbol: "exclamationmark.triangle.fill",
            verbatimTitle: message(for: error),
            symbolColor: DesignTokens.Colors.Status.warning,
            primary: EmptyStateButtonAction("Retry") { Task { await viewModel.reload() } },
            secondary: {
                if case .missingAPIKey = error {
                    return EmptyStateButtonAction("Set Web API key") { onRequestKeyEntry() }
                }
                return nil
            }()
        )
    }

    private func creatorFilterBanner(_ creator: BrowseViewModel.CreatorFilter) -> some View {
        scopeBanner(
            icon: "person.crop.circle",
            label: Text(creator.name.map { String(localized: "Works by \($0)", bundle: .appLanguage, comment: "Workshop creator-scoped browse header. Placeholder is the creator's name.") }
                        ?? String(localized: "Works by this creator", bundle: .appLanguage, comment: "Workshop creator-scoped browse header when the name is unknown.")),
            clear: { await viewModel.clearCreatorFilter() }
        )
    }

    private func tagFilterBanner(_ tag: String) -> some View {
        scopeBanner(
            icon: "tag",
            label: Text(String(localized: "Tagged “\(WorkshopTagLocalization.displayName(tag))”", bundle: .appLanguage, comment: "Workshop tag-scoped browse header. Placeholder is the tag.")),
            clear: { await viewModel.clearPinnedTag() }
        )
    }

    private func scopeBanner(icon: String, label: Text, clear: @escaping () async -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                Task { await clear() }
            } label: {
                Label("Back to Browse", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoading || viewModel.isPaging)

            Spacer(minLength: 0)
        }
        .overlay {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                label
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rateLimitBanner: some View {
        if viewModel.isRateLimited {
            HStack(spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.warning)
                        .accessibilityHidden(true)
                    Text("Steam is rate-limiting — retry in \(Self.countdown(rateLimitRemaining))")
                        .font(.callout.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Steam is rate-limiting. Retry in \(Self.countdown(rateLimitRemaining))."))

                Button("Retry") { Task { await viewModel.reload() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(rateLimitRemaining > 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .adaptiveGlassSurface(.capsule, tint: DesignTokens.Colors.Status.warning)
            .overlay(Capsule().strokeBorder(DesignTokens.Colors.Status.warning.opacity(0.35), lineWidth: 0.5))
            .padding(DesignTokens.Spacing.md)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var hasActiveFilters: Bool {
        guard viewModel.creatorFilter == nil, viewModel.pinnedTag == nil else { return false }
        return !viewModel.searchInput.isEmpty
            || WorkshopFilterMath.isNarrowing(viewModel.selectedTypes, total: WorkshopContentTypeFilter.selectableCases.count)
            || WorkshopFilterMath.isNarrowing(viewModel.selectedAgeRatings, total: WorkshopAgeRatingFilter.allCases.count)
            || WorkshopFilterMath.isNarrowing(viewModel.selectedResolutions, total: WorkshopResolutionFilter.selectableCases.count)
            || WorkshopFilterMath.isNarrowing(viewModel.selectedGenres, total: WorkshopGenre.allTags.count)
            || !viewModel.selectedMiscellaneous.isEmpty
    }

    private var currentRateLimitRemaining: TimeInterval {
        max(0, viewModel.rateLimitUntil?.timeIntervalSinceNow ?? 0)
    }

    private var emptyMessage: String {
        if let creator = viewModel.creatorFilter {
            if let name = creator.name {
                return String(localized: "\(name) hasn't published any wallpapers here.", bundle: .appLanguage, comment: "Empty creator-scoped Workshop browse. Placeholder is the creator's name.")
            }
            return String(localized: "This creator hasn't published any wallpapers here.", bundle: .appLanguage, comment: "Empty creator-scoped Workshop browse, name unknown.")
        }
        if let tag = viewModel.pinnedTag {
            return String(localized: "No results tagged “\(WorkshopTagLocalization.displayName(tag))”.", bundle: .appLanguage, comment: "Empty tag-scoped Workshop browse. Placeholder is the tag.")
        }
        if !viewModel.searchInput.isEmpty {
            return String(localized: "No results for \"\(viewModel.searchInput)\".", bundle: .appLanguage, comment: "Empty Workshop search result. Placeholder is the query.")
        }
        if hasActiveFilters {
            return String(localized: "No results for these filters.", bundle: .appLanguage, comment: "Empty Workshop result when type/age filters exclude everything.")
        }
        return String(localized: "No results yet.", bundle: .appLanguage, comment: "Initial empty Workshop browse state.")
    }

    private func clearFilters() {
        viewModel.searchInput = ""
        viewModel.resetFilters()
        Task { await viewModel.submitSearch() }
    }

    private func reloadInstalledIDs() {
        let imports = SettingsManager.shared.loadGlobalSettings().recentWPEImports
        installedWorkshopIDs = Set(imports.map(\.origin.workshopID))
        importedAtByWorkshopID = Dictionary(imports.map { ($0.origin.workshopID, $0.importedAt) }) { newest, _ in newest }
        viewModel.installedWorkshopIDs = installedWorkshopIDs
    }

    /// `InstalledLibraryModel`'s update rule, judged on the browse result's own update date.
    private func hasUpdate(_ item: WorkshopQueryItem) -> Bool {
        guard let importedAt = importedAtByWorkshopID[String(item.id)], let updated = item.timeUpdated else { return false }
        return updated > importedAt
    }

    private func reloadInUseBadges() {
        // `onBadge` reads only each display's id, frame and name.
        let displays = screenManager.screens.map { screen in
            StageDisplay(
                id: screen.id, fingerprint: screen.displayFingerprint, frame: screen.frame, isBuiltin: false,
                name: screen.name, badgeText: "", statusText: "", cover: nil, state: .ok
            )
        }
        var running: [String: [StageDisplay.ID]] = [:]
        for screen in screenManager.screens {
            if let workshopID = screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID {
                running[workshopID, default: []].append(screen.id)
            }
        }
        inUseBadges = running.compactMapValues { StageCard.onBadge(on: $0, among: displays) }
    }

    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func message(for error: WorkshopQueryError) -> String {
        switch error {
        case .missingAPIKey:
            String(
                localized: "Set your Steam Web API key in Settings to browse online.",
                bundle: .appLanguage, comment: "Workshop browse error when no Steam Web API key is configured."
            )
        case .keychainAccessDenied:
            String(
                localized: "macOS wouldn't unlock your saved API key — allow access when it asks, or set the key again in Settings.",
                bundle: .appLanguage, comment: "Workshop browse error when the keychain refused to hand over the stored API key."
            )
        case .unauthorized:
            String(
                localized: "Steam rejected the API key. Update it in Settings.",
                bundle: .appLanguage, comment: "Workshop browse error when the Steam Web API key is rejected."
            )
        case .keyDisabled:
            String(
                localized: "Your Steam API key was disabled by Valve. Regenerate one.",
                bundle: .appLanguage, comment: "Workshop browse error when Valve disabled the API key."
            )
        case .keychainUnreadable, .rateLimited, .networkUnreachable, .secureConnectionFailed,
             .networkFailure, .timeout, .http, .responseParseFailure, .schemaMismatch, .cancelled:
            // Listed rather than defaulted: a new case has to be considered
            // here for a remedy, not silently inherit the bare cause.
            error.causeDescription
        }
    }
}

/// Which item the inspector shows for a selected id: the grid's copy when the id
/// is on the page (it carries the persona pass), else the detached copy.
enum BrowseSelection {
    static func resolve(id: UInt64?, in items: [WorkshopQueryItem], detached: WorkshopQueryItem?) -> WorkshopQueryItem? {
        guard let id else {
            return nil
        }
        if let onPage = items.first(where: { $0.id == id }) {
            return onPage
        }
        return detached?.id == id ? detached : nil
    }

    /// Whether the selection survives the grid replacing its items: on the new page,
    /// already detached from it, or still being fetched for an off-page open.
    static func keepsSelection(
        id: UInt64?, in items: [WorkshopQueryItem], detached: WorkshopQueryItem?, pending: UInt64?
    ) -> Bool {
        guard let id else {
            return true
        }
        return pending == id || detached?.id == id || items.contains { $0.id == id }
    }

    struct PendingOpen: Equatable {
        let id: UInt64
        /// The pane's open counter at the time; two opens of the same id from
        /// the same selection are otherwise indistinguishable.
        let generation: Int
        let previousSelectedID: UInt64?
        let previousDetached: WorkshopQueryItem?

        /// The inspector's selection once Steam answered: the fetched item, or what was
        /// showing before — an id Steam will not describe must not close open details.
        func settle(
            with item: WorkshopQueryItem?, in items: [WorkshopQueryItem]
        ) -> (selectedID: UInt64?, detached: WorkshopQueryItem?) {
            if let item {
                return (id, item)
            }
            guard BrowseSelection.resolve(id: previousSelectedID, in: items, detached: previousDetached) != nil else {
                return (nil, nil)
            }
            return (previousSelectedID, previousDetached)
        }
    }
}

/// Same footprint as the real card, so results arriving do not reflow the grid.
private struct WorkshopSkeletonCard: View {
    var body: some View {
        WorkshopShimmer()
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottom) { titleBand }
            .galleryTileChrome(isHovering: false)
            .accessibilityHidden(true)
    }

    /// Mirrors `ThumbnailTitleBand` at rest — one line of type, same insets.
    private var titleBand: some View {
        WorkshopShimmer()
            .frame(height: 13)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.sm)
            .padding(.top, DesignTokens.Spacing.xs)
    }
}

private struct WorkshopShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsed = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsed = true
                }
            }
    }

    private var opacity: Double {
        if reduceMotion { return 0.08 }
        return pulsed ? 0.14 : 0.05
    }
}
#endif
