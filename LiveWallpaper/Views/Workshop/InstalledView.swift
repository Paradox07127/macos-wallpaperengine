#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

/// Installed Workshop tab (import history + Steam Workshop repository).
struct InstalledView: View {
    /// Tag tap → Browse Online scoped to that tag.
    var onBrowseTag: ((String) -> Void)?
    var onBrowseOnline: (() -> Void)?
    var onInstallSteamCMD: (() -> Void)?
    var onOpenWorkshopSettings: (() -> Void)?
    var isInstallingSteamCMD = false
    /// nil = no header / toolbar (embeddable like Browse).
    var paneHeader: (() -> AnyView)?

    @Environment(ScreenManager.self) private var screenManager
    @Environment(SteamCMDDoctorService.self) private var doctor
    @State private var importCoordinator = WorkshopFolderImportCoordinator.shared
    @State private var bookmarkStore = BookmarkStore.shared
    @State private var model = InstalledLibraryModel()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Same width tokens as the screen-detail inspector.
    @AppStorage("Workshop.Installed.InspectorWidth", store: .appScoped()) private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?


    var body: some View {
        @Bindable var model = model
        ResizableInspectorSplit(
                isMounted: true,
                isVisible: isInspectorVisible,
                animationTrigger: AnyHashable(isInspectorVisible),
                reduceMotion: reduceMotion,
                storedWidth: $inspectorWidth,
                liveWidth: $liveInspectorWidth,
                minWidth: DesignTokens.Inspector.minWidth,
                maxWidth: DesignTokens.Inspector.maxWidth,
                onClose: { model.inspectorHidden = true },
                main: { mainColumn },
                inspector: { width in installedInspectorColumn(width: width) }
            )
            .background(DesignTokens.Colors.pageBackground)
            .toolbar {
                if paneHeader != nil, model.selectedEntry != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.inspectorHidden.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help(Text(model.inspectorHidden ? "Show details" : "Hide details"))
                        .accessibilityLabel(Text("Toggle details panel"))
                    }
                }
            }
            .onAppear { model.onAppear() }
            .onDisappear { model.onDisappear() }
            .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
                model.historyDidChange()
            }
            .confirmationDialog(
                Text("Delete this wallpaper?"),
                isPresented: Binding(
                    get: { model.pendingDelete != nil },
                    set: { if !$0 { model.cancelDelete() } }
                ),
                presenting: model.pendingDelete
            ) { entry in
                Button(role: .destructive) {
                    performDelete(entry)
                } label: {
                    Text(model.deletesFiles(entry) ? "Delete & Free Up Space" : "Remove from Library")
                }
                Button("Cancel", role: .cancel) { model.cancelDelete() }
            } message: { entry in
                if model.deletesFiles(entry) {
                    Text("“\(entry.origin.title)” will be deleted from your Steam library on this Mac and removed from Loomscreen. This frees up disk space and can't be undone — you can download it again anytime. Your Steam subscription is unaffected.")
                } else {
                    Text("“\(entry.origin.title)” will be removed from your library. Its original files (imported from your own folder) are left untouched.")
                }
            }
    }

    private func installedInspectorColumn(width: CGFloat) -> some View {
        Group {
            if let entry = model.selectedEntry {
                WPEInstalledInspectorContent(
                    entry: entry,
                    screens: screenManager.screens,
                    activeScreenIDs: activeScreenIDs(for: entry),
                    state: WPEInstalledInspectorContent.ItemState(
                        isBookmarked: bookmarkStore.containsWPEBookmark(workshopID: entry.origin.workshopID),
                        canBookmark: model.canAddBookmark(entry),
                        hasUpdate: model.updatedWorkshopIDs.contains(entry.origin.workshopID),
                        canUpdate: doctor.isDownloadReady
                    ),
                    actions: WPEInstalledInspectorContent.Actions(
                        onApply: { apply(entry, to: $0) },
                        onApplyToAll: { applyToAll(entry) },
                        onUpdate: { updateEntry(entry) },
                        onToggleBookmark: { model.toggleBookmark(entry, store: bookmarkStore) },
                        onShowInFinder: { model.showInFinder(entry) },
                        onDelete: { model.requestDelete(entry) },
                        onSelectTag: onBrowseTag.map { browse in
                            { tag in model.clearSelectionAndBrowse(tag: tag, action: browse) }
                        }
                    )
                )
            } else {
                installedInspectorPlaceholder
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }

    private var installedInspectorPlaceholder: some View {
        IllustratedEmptyState(
            symbol: "square.dashed",
            title: "Select a wallpaper to see details.",
            variant: .compact
        )
    }


    // MARK: - Main column

    private var isInspectorVisible: Bool { model.selectedEntry != nil && !model.inspectorHidden }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if let paneHeader {
                paneHeader()
                Divider()
            }
            content
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        if model.entries.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                LibraryFilterBar(
                    searchText: $model.searchText,
                    searchPrompt: "Search library",
                    resultCount: model.visibleEntries.count,
                    totalCount: model.entries.count
                ) {
                    HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
                        WorkshopFiltersToggle(isExpanded: $model.showFilters, activeFilterCount: model.activeFilterCount)

                        Spacer(minLength: 0)

                        Picker("Sort", selection: $model.sortOrder) {
                            ForEach(WPELibrarySortOrder.allCases) { order in
                                Text(verbatim: order.title).tag(order)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .help(Text("Sort the library"))
                    }
                    .frame(maxWidth: .infinity)
                }

                if model.showFilters {
                    installedFilterPanel
                }

                if importCoordinator.isImporting {
                    importingBanner
                }

                gallery
            }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if model.visibleEntries.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, DesignTokens.Spacing.sm)
                }
                LazyVGrid(columns: DesignTokens.LibraryGrid.columns, spacing: DesignTokens.LibraryGrid.spacing) {
                    ForEach(model.visibleEntries, id: \.id) { entry in
                        let bookmarked = bookmarkStore.containsWPEBookmark(workshopID: entry.origin.workshopID)
                        WPEHistoryRow(
                            entry: entry,
                            isActive: isActive(entry),
                            allowsInlineApply: true,
                            isSelected: model.selectedEntry?.id == entry.id,
                            screens: screenManager.screens,
                            onApply: { screen in apply(entry, to: screen) },
                            onApplyToAll: { applyToAll(entry) },
                            onTap: { model.select(entry) },
                            onRemove: { model.requestDelete(entry) },
                            isBookmarked: bookmarked,
                            // Only offer "Add" when the content can be rebuilt into a
                            // bookmark; "Remove" stays available for anything bookmarked.
                            onBookmark: (bookmarked || model.canAddBookmark(entry))
                                ? { model.toggleBookmark(entry, store: bookmarkStore) } : nil,
                            hasUpdate: model.updatedWorkshopIDs.contains(entry.origin.workshopID),
                            onUpdate: doctor.isDownloadReady ? { updateEntry(entry) } : nil
                        )
                        .onDrag({
                            NSItemProvider(object: model.beginEntryDrag(entry) as NSString)
                        }, preview: { dragPreview(entry) })
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, DesignTokens.Spacing.cardInset)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection() }
                )
            }
            .overlay(alignment: .top) {
                if model.isDraggingEntry, !screenManager.screens.isEmpty {
                    screenDropBar
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isDraggingEntry)
        }
    }

    private var importingBanner: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Importing from folder…")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "square.stack.3d.up.slash",
            title: "No wallpapers installed yet.",
            // The buttons below carry the two main paths; the message only
            // teaches the alternates they don't cover.
            message: "You can also paste a Workshop URL or add a library folder with +.",
            primary: emptyStatePrimaryAction,
            secondary: onOpenWorkshopSettings.map { openSettings in
                EmptyStateButtonAction("Configure", action: openSettings)
            }
        ) {
            if isInstallingSteamCMD {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Setting up SteamCMD…")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            }
        }
    }

    private var emptyStatePrimaryAction: EmptyStateButtonAction? {
        if doctor.hasBoundBinary, doctor.isGreen(.binaryIdentity), let onBrowseOnline {
            return EmptyStateButtonAction("Browse Online", action: onBrowseOnline)
        }
        return onInstallSteamCMD.map { install in
            EmptyStateButtonAction("Install SteamCMD…", action: install)
        }
    }

    // MARK: - Type filter chips (multi-select)

    private var typeChipRow: some View {
        HStack(spacing: 6) {
            ForEach(WPELibraryTypeKind.allCases) { kind in
                WorkshopFilterChip(
                    title: Text(verbatim: kind.title),
                    isSelected: model.selectedTypes.contains(kind),
                    onIsolate: { model.isolateType(kind) }
                ) {
                    model.toggleType(kind)
                }
            }
        }
    }

    // MARK: - Filters panel (origin + storage)

    private var installedFilterPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            WorkshopFilterRow("Type") {
                typeChipRow
            }

            WorkshopFilterRow("Source") {
                HStack(spacing: 6) {
                    ForEach(InstalledSource.allCases) { source in
                        WorkshopFilterChip(
                            title: Text(verbatim: source.title),
                            isSelected: model.selectedSources.contains(source),
                            onIsolate: { model.isolateSource(source) }
                        ) {
                            model.toggleSource(source)
                        }
                    }
                }
            }

            WorkshopFilterRow("Storage") {
                HStack(spacing: 6) {
                    ForEach(InstalledStorageKind.allCases) { storage in
                        WorkshopFilterChip(
                            title: Text(verbatim: storage.title),
                            isSelected: model.selectedStorage.contains(storage),
                            onIsolate: { model.isolateStorage(storage) }
                        ) {
                            model.toggleStorage(storage)
                        }
                    }
                }
            }

            if model.activeFilterCount > 0 {
                Button("Clear filters") { model.resetFilters() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.leading, 74 + DesignTokens.Spacing.sm)
            }
        }
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Actions

    /// "In use" == the entry's project is the active wallpaper on *any* open
    /// display (no single target screen in this multi-display library).
    private func isActive(_ entry: WPEHistoryEntry) -> Bool {
        screenManager.screens.contains { screen in
            screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID == entry.origin.workshopID
        }
    }

    /// Displays currently running this entry — drives the active checkmark in
    /// the Apply popover.
    private func activeScreenIDs(for entry: WPEHistoryEntry) -> Set<CGDirectDisplayID> {
        Set(screenManager.screens
            .filter { screenManager.getConfiguration(for: $0)?.wpeOrigin?.workshopID == entry.origin.workshopID }
            .map(\.id))
    }

    private func apply(_ entry: WPEHistoryEntry, to screen: Screen) {
        model.startApply(entry: entry) {
            await screenManager.activateWPEHistoryEntry(entry, for: screen)
            return screenManager.wpeImportTracker.error(for: screen.id) != nil
        }
    }

    private func applyToAll(_ entry: WPEHistoryEntry) {
        model.startApply(entry: entry) {
            var failed = false
            for screen in screenManager.screens {
                await screenManager.activateWPEHistoryEntry(entry, for: screen)
                failed = failed || screenManager.wpeImportTracker.error(for: screen.id) != nil
            }
            return failed
        }
    }

    /// Re-download from Steam to pick up the newer Workshop version. On success
    /// the fresher `importedAt` clears the badge via `reconcileUpdateFlags`.
    private func updateEntry(_ entry: WPEHistoryEntry) {
        guard let id = UInt64(entry.origin.workshopID) else { return }
        WorkshopDownloadCoordinator.shared.download(itemID: id, title: entry.origin.title, using: doctor)
    }

    private func performDelete(_ entry: WPEHistoryEntry) {
        model.performDelete(
            entry,
            services: InstalledLibraryModel.DeleteServices(
                containsBookmark: { bookmarkStore.containsWPEBookmark(workshopID: $0) },
                removeBookmarks: { bookmarkStore.removeWPEBookmarks(workshopID: $0) },
                removeImportIfMatching: {
                    screenManager.removeWPEImport(
                        workshopID: $0.workshopID,
                        matchingImportedAt: $0.importedAt
                    )
                },
                deleteSharedRepositoryItem: { await SteamConnectorClient.deleteWorkshopItem(workshopID: $0) }
            )
        )
    }

    // MARK: - Drag-to-apply screen bar

    /// Floats in only while a card is being dragged, listing the open displays
    /// as drop targets. (Click-to-apply lives in the inspector's Apply popover.)
    private var screenDropBar: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("Drop onto a display to apply")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)

            // Laid out in the system's own arrangement so the target you aim at
            // is the panel in that physical position.
            DisplayArrangementMap(
                items: screenManager.screens.map {
                    DisplayArrangementItem(id: $0.id, frame: $0.frame)
                },
                height: 110
            ) { item, size in
                if let screen = screenManager.screens.first(where: { $0.id == item.id }) {
                    screenDropTarget(screen, size: size)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            Button { model.endEntryDrag() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(DesignTokens.Spacing.sm)
            .help(Text("Cancel"))
            .accessibilityLabel(Text("Cancel"))
        }
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func screenDropTarget(_ screen: Screen, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.system(size: size.height >= 60 ? 24 : 16))
                        .foregroundStyle(Color.accentColor)
                    // A short panel has no room for both glyph and name.
                    if size.height >= 46 {
                        Text(verbatim: screen.name)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                handleScreenDrop(providers, to: screen)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Apply to \(screen.name)"))
    }

    /// Small icon shown under the cursor while dragging — deliberately NOT the
    /// preview image, so it doesn't obscure which display you're hovering.
    private func dragPreview(_ entry: WPEHistoryEntry) -> some View {
        Image(systemName: entry.origin.originalType.symbolName)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.onAccentFill)
            .frame(width: 54, height: 54)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
    }

    private func handleScreenDrop(_ providers: [NSItemProvider], to screen: Screen) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            model.endEntryDrag()
            return false
        }
        let ticket = model.makeDropTicket()
        _ = provider.loadObject(ofClass: NSString.self) { value, error in
            // Extract Sendable values (String / Bool) before crossing to the main
            // actor — NSString and Error are not Sendable under Swift 6.
            let workshopID = value as? String
            let loadFailed = error != nil
            Task { @MainActor in
                guard let entry = model.consumeDrop(
                    ticket,
                    workshopID: workshopID,
                    loadFailed: loadFailed
                ) else { return }
                guard let target = screenManager.screens.first(where: { $0.id == screen.id }) else { return }
                apply(entry, to: target)
            }
        }
        return true
    }
}

#endif
