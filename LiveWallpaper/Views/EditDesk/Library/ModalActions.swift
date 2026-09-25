import AppKit
import LiveWallpaperCore

@MainActor
final class ModalActions {
    struct Display {
        let id: CGDirectDisplayID
        let name: String
        let frame: CGRect
    }

    @MainActor
    struct Inputs {
        var item: @MainActor (String) -> LibraryItem? = { _ in nil }
        var displays: @MainActor () -> [Display] = { [] }
        #if !LITE_BUILD
        var installedLibrary = InstalledLibraryModel()
        var localInfo: @MainActor (WPEHistoryEntry) async -> LocalProjectInfo? = { await loadWPELocalProjectInfo(for: $0) }
        var phase: @MainActor (UInt64) -> WorkshopDownloadCoordinator.DownloadPhase = { _ in .idle }
        var progress: @MainActor (UInt64) -> Double? = { _ in nil }
        var progressBytes: @MainActor (UInt64) -> WorkshopDownloadCoordinator.DownloadProgressBytes? = { _ in nil }
        var fetchingDependencies: @MainActor (UInt64) -> Bool = { _ in false }
        var update: @MainActor (WPEHistoryEntry) -> Void = { _ in }
        var cancelUpdate: @MainActor (UInt64) -> Void = { _ in }
        var deleteInstalled: @MainActor (WPEHistoryEntry, InstalledLibraryModel) -> Void = { _, _ in }
        #endif

        static func live(library: SavedLibraryModel, screenManager: ScreenManager) -> Inputs {
            var inputs = Inputs()
            inputs.item = { id in library.items.first { $0.id == id } }
            inputs.displays = {
                screenManager.screens.map { Display(id: $0.id, name: $0.name, frame: $0.frame) }
            }
            return inputs
        }
    }

    private let inputs: Inputs
    private let bookmarks: BookmarkStore
    private let thumbnails: ShelfThumbnailCache
    private let apply: @MainActor (ApplyIntent, CGDirectDisplayID) -> Void
    /// Takes "All Displays" as one change.
    private let applyToAll: @MainActor (ApplyIntent, [CGDirectDisplayID]) -> Void
    /// Where removing and renaming a saved entry are recorded; nil records nothing.
    private let undo: EditDeskUndoStack?

    init(
        inputs: Inputs, bookmarks: BookmarkStore, thumbnails: ShelfThumbnailCache, undo: EditDeskUndoStack? = nil,
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void,
        applyToAll: @escaping @MainActor (ApplyIntent, [CGDirectDisplayID]) -> Void
    ) {
        self.inputs = inputs
        self.bookmarks = bookmarks
        self.thumbnails = thumbnails
        self.undo = undo
        self.apply = apply
        self.applyToAll = applyToAll
    }

    #if LITE_BUILD
    convenience init(
        library: SavedLibraryModel, screenManager: ScreenManager, thumbnails: ShelfThumbnailCache,
        undo: EditDeskUndoStack?,
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void,
        applyToAll: @escaping @MainActor (ApplyIntent, [CGDirectDisplayID]) -> Void
    ) {
        self.init(
            inputs: .live(library: library, screenManager: screenManager),
            bookmarks: .shared, thumbnails: thumbnails, undo: undo, apply: apply, applyToAll: applyToAll
        )
    }
    #else
    convenience init(
        library: SavedLibraryModel, screenManager: ScreenManager, thumbnails: ShelfThumbnailCache,
        doctor: SteamCMDDoctorService, installedLibrary: InstalledLibraryModel, undo: EditDeskUndoStack?,
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void,
        applyToAll: @escaping @MainActor (ApplyIntent, [CGDirectDisplayID]) -> Void
    ) {
        var inputs = Inputs.live(library: library, screenManager: screenManager)
        inputs.installedLibrary = installedLibrary
        let store = BookmarkStore.shared
        let coordinator = WorkshopDownloadCoordinator.shared
        inputs.phase = { coordinator.phase(for: $0) }
        inputs.progress = { coordinator.progress[$0] }
        inputs.progressBytes = { coordinator.progressBytes[$0] }
        inputs.fetchingDependencies = { coordinator.fetchingDependencies.contains($0) }
        inputs.update = { entry in
            guard let id = UInt64(entry.origin.workshopID) else { return }
            coordinator.download(itemID: id, title: entry.origin.title, using: doctor)
        }
        inputs.cancelUpdate = { coordinator.cancel($0) }
        inputs.deleteInstalled = { entry, model in
            model.performDelete(entry, services: InstalledLibraryModel.DeleteServices(
                containsBookmark: { store.containsWPEBookmark(workshopID: $0) },
                removeBookmarks: { store.removeWPEBookmarks(workshopID: $0) },
                removeImportIfMatching: {
                    screenManager.removeWPEImport(workshopID: $0.workshopID, matchingImportedAt: $0.importedAt)
                },
                isMutating: { UInt64($0).map { coordinator.isBusy($0) } ?? false },
                deleteSharedRepositoryItem: { workshopID in
                    guard let steamRoot = try? doctor.resolveWorkdirURL() else { return nil }
                    return try await WorkshopRepositoryCoordinator.shared.withExclusiveMutation(workshopID: workshopID) {
                        await SteamConnectorClient.deleteWorkshopItem(
                            workshopID: workshopID, libraryPath: steamRoot.path(percentEncoded: false)
                        )
                    }
                }
            ))
        }
        self.init(inputs: inputs, bookmarks: store, thumbnails: thumbnails, undo: undo, apply: apply, applyToAll: applyToAll)
    }
    #endif

    static func intent(for item: LibraryItem) -> ApplyIntent? {
        guard item.isSupported else { return nil }
        switch item.source {
        case let .bookmark(bookmark):
            return .bookmark(bookmark)
        case let .aerial(asset):
            // Not `asset.url`: the folder's scope closed when the scan ended; the file's own bookmark still resolves with one.
            return .bookmark(WallpaperBookmark(label: asset.displayName, content: .video(bookmarkData: asset.bookmarkData)))
        #if !LITE_BUILD
        case let .workshop(entry):
            return .installedWorkshop(entry)
        #endif
        }
    }

    func content(for item: LibraryItem) async -> WallpaperModalContent {
        var content = WallpaperModalContent(itemID: item.id, title: item.title, kind: item.kind)
        content.canApply = item.isSupported
        #if !LITE_BUILD
        if case let .workshop(entry) = item.source, entry.origin.resourceLocation == .unsupported {
            content.unsupportedOrigin = entry.origin
        }
        #endif
        if !item.isSupported {
            // The unsupported-project banner already says why; this line would only repeat it.
            if content.unsupportedOrigin == nil {
                content.notice = String(localized: "Can't run on this Mac", bundle: .appLanguage)
            }
        } else if item.isSourceMissing {
            content.notice = DropFailure.sourceMissing.toastText
        }
        #if LITE_BUILD
        content.facts = WallpaperFacts.library(
            item, sizeBytes: Self.fileSize(of: item), now: Date(), locale: AppLanguagePreference.current.locale
        )
        #else
        await fillProjectDetails(of: item, into: &content)
        #endif
        if content.workshopID == nil {
            content.fileFacts = fileFacts(for: item)
        }
        return content
    }

    func targets(
        for item: LibraryItem, covers: [CGDirectDisplayID: CGImage] = [:], preferred: CGDirectDisplayID? = nil
    ) -> [ModalDisplayTarget] {
        Self.targets(displays: inputs.displays(), activeOn: Set(item.onDisplays), covers: covers, preferred: preferred)
    }

    static func targets(
        displays: [Display], activeOn: Set<CGDirectDisplayID>, covers: [CGDirectDisplayID: CGImage],
        preferred: CGDirectDisplayID? = nil
    ) -> [ModalDisplayTarget] {
        let displays = displays.sorted { $0.frame.minX < $1.frame.minX }
        let primary = displays.first { $0.id == preferred } ?? displays.first
        return displays.enumerated().map { index, display in
            ModalDisplayTarget(
                id: display.id, name: display.name, shortcutIndex: index + 1,
                aspectRatio: display.frame.width / display.frame.height,
                thumbnail: covers[display.id], isPrimary: display.id == primary?.id,
                isApplied: activeOn.contains(display.id)
            )
        }
    }

    func preview(for item: LibraryItem, pixelSize: CGSize, scale: CGFloat) async -> CGImage? {
        guard let request = item.thumbnail else { return nil }
        return await thumbnails.image(request, pixelSize: pixelSize, scale: scale)
    }

    /// The modal's "…" rows for `item`, as its context menus show them.
    func menuItems(
        for item: LibraryItem, requestRename: @escaping @MainActor () -> Void,
        requestDelete: @escaping @MainActor () -> Void
    ) -> [StageMenuItem] {
        actions(for: item).menuItems(
            targets: targets(for: item), canApply: item.isSupported, isUpdating: isUpdating(item),
            requestRename: requestRename, requestDelete: requestDelete
        )
    }

    /// The modal's title-row buttons for `item`: the context menu's rows that do not apply.
    func headerActions(
        for item: LibraryItem, requestRename: @escaping @MainActor () -> Void,
        requestDelete: @escaping @MainActor () -> Void
    ) -> [ModalHeaderAction] {
        actions(for: item).headerActions(
            isUpdating: isUpdating(item), requestRename: requestRename, requestDelete: requestDelete
        )
    }

    #if !LITE_BUILD
    /// An installed Workshop item's transfer, or its pending update while nothing moves; nil when there is
    /// nothing to say. Read in the host's body, so the modal follows every published byte count.
    func downloadStatus(for item: LibraryItem) -> WorkshopDownloadPresentation? {
        guard case let .workshop(entry) = item.source, let id = UInt64(entry.origin.workshopID) else { return nil }
        let bytes = inputs.progressBytes(id)
        var status = WorkshopDownloadPresentation.make(
            ticketState: nil, settledScreenName: "", wallpapersOn: true, phase: inputs.phase(id),
            isFetchingDependencies: inputs.fetchingDependencies(id), fraction: inputs.progress(id),
            downloadedBytes: bytes?.downloaded, totalBytes: bytes?.total, bytesPerSecond: nil,
            isInstalled: true, unsupportedOrigin: nil, blocker: nil
        )
        if status.status.isEmpty, status.progress == .none, updateState(for: entry) == .available {
            status.status = String(
                localized: "Update available", bundle: .appLanguage,
                comment: "A11y: the installed item has a newer version on Steam."
            )
        }
        return status.status.isEmpty && status.progress == .none ? nil : status
    }
    #endif

    /// What the delete confirmation says for `item`: whether deleting it frees disk space.
    func deletesFiles(_ item: LibraryItem) -> Bool {
        #if !LITE_BUILD
        if case let .workshop(entry) = item.source {
            return inputs.installedLibrary.deletesFiles(entry)
        }
        #endif
        return false
    }

    /// The "…" menu offers Cancel Update while this is true, as the modal does while its content reads `.checking`.
    private func isUpdating(_ item: LibraryItem) -> Bool {
        #if !LITE_BUILD
        if case let .workshop(entry) = item.source, case .checking = updateState(for: entry) {
            return true
        }
        #endif
        return false
    }

    func actions(for item: LibraryItem) -> WallpaperModalActions {
        let id = item.id
        var actions = WallpaperModalActions(
            applyTo: { [self] displayID in
                guard let current = inputs.item(id), let intent = Self.intent(for: current) else { return }
                apply(intent, displayID)
            },
            applyToAllDisplays: { [self] in
                guard let current = inputs.item(id), let intent = Self.intent(for: current) else { return }
                applyToAll(intent, inputs.displays().map(\.id))
            }
        )
        if case .bookmark = item.source {
            actions.removeFromSaved = { [self] in
                guard let current = inputs.item(id), case let .bookmark(bookmark) = current.source,
                      let index = bookmarks.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
                let removed = bookmarks.bookmarks[index]
                bookmarks.remove(removed.id)
                undo?.recordRemoval(of: removed, at: index)
            }
            actions.rename = { [self] name in
                guard let current = inputs.item(id), case let .bookmark(bookmark) = current.source,
                      let before = bookmarks.bookmarks.first(where: { $0.id == bookmark.id }) else { return }
                bookmarks.rename(before.id, to: name)
                guard bookmarks.bookmarks.first(where: { $0.id == before.id })?.label != before.label else { return }
                undo?.recordRename(of: before)
            }
        }
        if Self.revealBookmark(for: item) != nil {
            actions.showInFinder = { [self] in
                guard let current = inputs.item(id), let data = Self.revealBookmark(for: current),
                      let resolved = try? SecurityScopedBookmarkResolver.shared.resolve(data, target: .transient).get()
                else { return }
                SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    NSWorkspace.shared.activateFileViewerSelecting([resolved.url])
                }
            }
        }
        #if !LITE_BUILD
        if steamID(for: item) != nil {
            actions.openInSteam = { [self] in
                guard let current = inputs.item(id), let steamID = steamID(for: current),
                      let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(steamID)") else { return }
                NSWorkspace.shared.open(url)
            }
        }
        if case .workshop = item.source {
            actions.showInFinder = { [self] in
                guard let current = inputs.item(id), case let .workshop(entry) = current.source else { return }
                inputs.installedLibrary.showInFinder(entry)
            }
            actions.deleteInstalled = { [self] in
                guard let current = inputs.item(id), case let .workshop(entry) = current.source else { return }
                inputs.deleteInstalled(entry, inputs.installedLibrary)
            }
            if steamID(for: item) != nil {
                actions.checkForUpdate = { [self] in
                    guard let current = inputs.item(id), case let .workshop(entry) = current.source else { return }
                    inputs.update(entry)
                }
                actions.cancelUpdate = { [self] in
                    guard let current = inputs.item(id), let steamID = steamID(for: current) else { return }
                    inputs.cancelUpdate(steamID)
                }
            }
        }
        #endif
        return actions
    }

    #if !LITE_BUILD
    /// The rows, chips and description a Workshop project's manifest adds to the library's own rows.
    private func fillProjectDetails(of item: LibraryItem, into content: inout WallpaperModalContent) async {
        let now = Date()
        let locale = AppLanguagePreference.current.locale
        guard let entry = localInfoEntry(for: item) else {
            content.facts = WallpaperFacts.library(item, sizeBytes: Self.fileSize(of: item), now: now, locale: locale)
            return
        }
        let info = await inputs.localInfo(entry)
        let tags = info?.tags ?? []
        var manifestFacts = WallpaperFacts.tagFacts(tags)
        if let rating = info?.contentRating, !rating.isEmpty {
            manifestFacts = WallpaperFacts.merged(
                [WallpaperFact(kind: .ageRating, value: WorkshopTagLocalization.displayName(rating))], manifestFacts
            )
        }
        let library = WallpaperFacts.library(
            item, typeName: entry.origin.localizedDisplayTypeName,
            sizeBytes: Self.fileSize(of: item) ?? entry.sizeBytes ?? info?.sizeBytes, now: now, locale: locale
        )
        content.facts = WallpaperFacts.merged(library, manifestFacts)
        content.tags = WallpaperFacts.chips(tags)
        content.descriptionText = info?.cleanedDescription ?? ""
        content.workshopID = UInt64(entry.origin.workshopID)
        content.dependencyIDs = entry.origin.dependencyWorkshopIDs
        if case .workshop = item.source {
            content.installed = InstalledItemExtras(updateState: updateState(for: entry))
        }
    }
    #endif

    /// What the library measured itself: a probed video's file, an aerial's catalog size.
    private static func fileSize(of item: LibraryItem) -> Int64? {
        if case let .video(video)? = item.metadata, let size = video.fileSize {
            return size
        }
        if case let .aerial(asset) = item.source {
            return asset.fileSize
        }
        return nil
    }

    /// Where an item without a Workshop page lives: a path for files and folders, the address for a web page.
    private func fileFacts(for item: LibraryItem) -> [WallpaperFact] {
        if case let .aerial(asset) = item.source {
            return [WallpaperFact(kind: .location, value: asset.url.path(percentEncoded: false))]
        }
        if case let .bookmark(bookmark) = item.source, case let .html(.url(address), _) = bookmark.content {
            return [WallpaperFact(kind: .webAddress, value: address.absoluteString)]
        }
        #if !LITE_BUILD
        if case let .workshop(entry) = item.source {
            return location(of: entry.origin.sourceFolderBookmark)
        }
        #endif
        return Self.revealBookmark(for: item).map(location(of:)) ?? []
    }

    private func location(of bookmark: Data) -> [WallpaperFact] {
        guard let resolved = try? SecurityScopedBookmarkResolver.shared.resolve(bookmark, target: .transient).get() else { return [] }
        return [WallpaperFact(kind: .location, value: resolved.url.path(percentEncoded: false))]
    }

    private static func revealBookmark(for item: LibraryItem) -> Data? {
        if case let .aerial(asset) = item.source {
            return asset.bookmarkData
        }
        guard case let .bookmark(bookmark) = item.source else { return nil }
        switch bookmark.content {
        case let .video(data, _): return data
        case let .html(source, _): return source.localBookmarkData
        case .scene:
            #if !LITE_BUILD
            return bookmark.wpeOrigin?.sourceFolderBookmark
            #else
            return nil
            #endif
        }
    }

    #if !LITE_BUILD
    private func localInfoEntry(for item: LibraryItem) -> WPEHistoryEntry? {
        switch item.source {
        case let .workshop(entry): return entry
        case let .bookmark(bookmark):
            guard let origin = bookmark.wpeOrigin else { return nil }
            return WPEHistoryEntry(origin: origin, importedAt: bookmark.createdAt)
        case .aerial: return nil
        }
    }

    private func steamID(for item: LibraryItem) -> UInt64? {
        guard let entry = localInfoEntry(for: item),
              entry.origin.workshopID.allSatisfy(\.isNumber) else { return nil }
        return UInt64(entry.origin.workshopID)
    }

    /// Must change whenever `updateState(for:)` would, other than `.checking`'s progress, which nothing in the
    /// library modal shows: the modal reloads its content only when this changes.
    func installedStateKey(for item: LibraryItem) -> String {
        guard let entry = localInfoEntry(for: item), let id = UInt64(entry.origin.workshopID) else { return "" }
        return "\(inputs.phase(id)) \(inputs.installedLibrary.updatedWorkshopIDs.contains(entry.id))"
    }

    private func updateState(for entry: WPEHistoryEntry) -> InstalledItemExtras.UpdateState {
        guard let id = UInt64(entry.origin.workshopID) else { return .unknown }
        switch inputs.phase(id) {
        case .downloading, .importing: return .checking(progress: inputs.progress(id))
        case let .failed(message): return .failed(message: message)
        case .idle, .succeeded, .succeededAsPreset:
            return inputs.installedLibrary.updatedWorkshopIDs.contains(entry.id) ? .available : .upToDate
        }
    }
    #endif
}
