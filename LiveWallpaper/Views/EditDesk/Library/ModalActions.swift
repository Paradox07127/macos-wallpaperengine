import AppKit
import LiveWallpaperCore
#if !LITE_BUILD
import Combine
#endif

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
        var togglePlayback: @MainActor (CGDirectDisplayID) -> Void = { _ in }
        var appendToPlaylist: @MainActor (Data, CGDirectDisplayID) -> Void = { _, _ in }
        var appendWallpaper: (@MainActor (WallpaperQueueEntry, CGDirectDisplayID) -> Void)?
        var presets: @MainActor () -> [String: ScenePreset] = { [:] }
        #if !LITE_BUILD
        var installedLibrary = InstalledLibraryModel()
        var localInfo: @MainActor (WPEHistoryEntry) async -> LocalProjectInfo? = { await loadWPELocalProjectInfo(for: $0) }
        var phase: @MainActor (UInt64) -> WorkshopDownloadCoordinator.DownloadPhase = { _ in .idle }
        var progress: @MainActor (UInt64) -> Double? = { _ in nil }
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
            inputs.togglePlayback = { id in
                guard let screen = screenManager.screens.first(where: { $0.id == id }),
                      let controller = screen.playbackController else { return }
                if controller.isPlaying {
                    controller.pause()
                } else {
                    controller.play()
                }
                screenManager.markWallpaperSessionStateChanged()
            }
            inputs.appendToPlaylist = { data, id in
                guard let screen = screenManager.screens.first(where: { $0.id == id }),
                      let configuration = screenManager.getConfiguration(for: screen) else { return }
                screenManager.updatePlaylistBookmarks((configuration.playlistBookmarks ?? []) + [data], for: screen)
            }
            inputs.appendWallpaper = { entry, id in
                guard let screen = screenManager.screens.first(where: { $0.id == id }),
                      let config = screenManager.getConfiguration(for: screen) else { return }
                screenManager.replaceWallpaperQueue(config.effectiveWallpaperQueue + [entry], for: screen)
            }
            inputs.presets = { SettingsManager.shared.loadGlobalSettings().scenePresets }
            return inputs
        }
    }

    private let inputs: Inputs
    private let bookmarks: BookmarkStore
    private let thumbnails: ShelfThumbnailCache
    private let apply: @MainActor (ApplyIntent, CGDirectDisplayID) -> Void
    #if !LITE_BUILD
    private var historySubscription: AnyCancellable?
    #endif

    init(
        inputs: Inputs, bookmarks: BookmarkStore, thumbnails: ShelfThumbnailCache,
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void
    ) {
        self.inputs = inputs
        self.bookmarks = bookmarks
        self.thumbnails = thumbnails
        self.apply = apply
    }

    #if LITE_BUILD
    convenience init(
        library: SavedLibraryModel, screenManager: ScreenManager, thumbnails: ShelfThumbnailCache,
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void
    ) {
        self.init(
            inputs: .live(library: library, screenManager: screenManager),
            bookmarks: .shared, thumbnails: thumbnails, apply: apply
        )
    }
    #else
    convenience init(
        library: SavedLibraryModel, screenManager: ScreenManager, thumbnails: ShelfThumbnailCache,
        doctor: SteamCMDDoctorService,
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void
    ) {
        var inputs = Inputs.live(library: library, screenManager: screenManager)
        let store = BookmarkStore.shared
        let coordinator = WorkshopDownloadCoordinator.shared
        inputs.phase = { coordinator.phase(for: $0) }
        inputs.progress = { coordinator.progress[$0] }
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
        self.init(inputs: inputs, bookmarks: store, thumbnails: thumbnails, apply: apply)
        inputs.installedLibrary.onAppear()
        historySubscription = NotificationCenter.default.publisher(for: .wpeHistoryDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.inputs.installedLibrary.historyDidChange() }
            }
    }

    isolated deinit {
        inputs.installedLibrary.onDisappear()
    }
    #endif

    static func intent(for item: LibraryItem) -> ApplyIntent? {
        guard item.isSupported else { return nil }
        switch item.source {
        case let .bookmark(bookmark):
            return .bookmark(bookmark)
        case let .aerial(asset):
            return .video(url: asset.url, bookmarkData: asset.bookmarkData, packageEntryName: nil)
        #if !LITE_BUILD
        case let .workshop(entry):
            return .installedWorkshop(entry)
        #endif
        }
    }

    func content(for item: LibraryItem) async -> WallpaperModalContent {
        var content = WallpaperModalContent(
            itemID: item.id, title: item.title, kind: item.kind, tags: [],
            metaParts: metaParts(for: item), presetName: nil, preview: nil,
            isDraggable: item.isSupported, installed: nil
        )
        if case let .bookmark(bookmark) = item.source {
            content.presetName = bookmark.content.sceneDescriptor?.resolvedPreset(in: inputs.presets())?.name
        }
        #if !LITE_BUILD
        if let entry = localInfoEntry(for: item) {
            let info = await inputs.localInfo(entry)
            content.tags = Array(Set(info?.tags ?? [])).sorted()
            content.descriptionText = info?.cleanedDescription
            content.contentRating = info?.contentRating
            content.importedAt = entry.importedAt
            content.workshopID = UInt64(entry.origin.workshopID)
            content.dependencyIDs = entry.origin.dependencyWorkshopIDs
            if case .workshop = item.source {
                content.installed = InstalledItemExtras(
                    updateState: updateState(for: entry), isWindowsOnly: entry.origin.requiresWindowsPlugin,
                    inUseOnDisplayNames: inputs.displays().filter { item.onDisplays.contains($0.id) }.map(\.name),
                    deletesFiles: inputs.installedLibrary.deletesFiles(entry), localDescription: info?.cleanedDescription
                )
            }
        }
        #endif
        if case let .video(video)? = item.metadata {
            if item.metadata?.is4K == true {
                content.tags.append("4K")
            }
            if video.isHDR {
                content.tags.append("HDR")
            }
        }
        return content
    }

    func targets(for item: LibraryItem, covers: [CGDirectDisplayID: CGImage] = [:]) -> [ModalDisplayTarget] {
        Self.targets(displays: inputs.displays(), activeOn: Set(item.onDisplays), covers: covers)
    }

    static func targets(
        displays: [Display], activeOn: Set<CGDirectDisplayID>, covers: [CGDirectDisplayID: CGImage]
    ) -> [ModalDisplayTarget] {
        let displays = displays.sorted { $0.frame.minX < $1.frame.minX }
        let primary = displays.first
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

    func actions(for item: LibraryItem) -> WallpaperModalActions {
        let id = item.id
        var actions = WallpaperModalActions(
            applyTo: { [self] displayID in
                guard let current = inputs.item(id), let intent = Self.intent(for: current) else { return }
                apply(intent, displayID)
            },
            applyToAllDisplays: { [self] in
                guard let current = inputs.item(id), let intent = Self.intent(for: current) else { return }
                for display in inputs.displays() {
                    apply(intent, display.id)
                }
            }
        )
        if !item.onDisplays.isEmpty {
            actions.togglePlayback = { [self] in
                guard let current = inputs.item(id) else { return }
                for displayID in current.onDisplays {
                    inputs.togglePlayback(displayID)
                }
            }
        }
        if let appendWallpaper = inputs.appendWallpaper, item.isSupported {
            actions.addToPlaylist = { [self] displayID in
                guard let current = inputs.item(id), let entry = WallpaperQueueEntry.libraryItem(current) else { return }
                appendWallpaper(entry, displayID)
            }
        } else if Self.playlistBookmarkData(for: item) != nil {
            actions.addToPlaylist = { [self] displayID in
                guard let current = inputs.item(id), let data = Self.playlistBookmarkData(for: current) else { return }
                inputs.appendToPlaylist(data, displayID)
            }
        }
        if case .bookmark = item.source {
            actions.removeFromSaved = { [self] in
                guard let current = inputs.item(id), case let .bookmark(bookmark) = current.source else { return }
                bookmarks.remove(bookmark.id)
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

    private func metaParts(for item: LibraryItem) -> [String] {
        let source = if item.kind == .aerial {
            String(localized: "Aerial", bundle: .appLanguage)
        } else if item.isSteam {
            String(localized: "Steam Workshop", bundle: .appLanguage)
        } else {
            String(localized: "Local", bundle: .appLanguage)
        }
        var parts = [source]
        var bytes: Int64?
        if case let .video(video)? = item.metadata {
            bytes = video.fileSize
        }
        #if !LITE_BUILD
        if bytes == nil, case let .workshop(entry) = item.source {
            bytes = entry.sizeBytes
        }
        #endif
        if let bytes {
            parts.append(WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: bytes))
        }
        if let resolution = item.metadata?.resolutionShortLabel {
            parts.append(resolution)
        }
        if let lastUsed = item.lastUsedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = AppLanguagePreference.current.locale
            let now = Date()
            let relative = now.timeIntervalSince(lastUsed) < 60
                ? String(localized: "Just now", bundle: .appLanguage)
                : formatter.localizedString(for: lastUsed, relativeTo: now)
            parts.append(String(localized: "Last used \(relative)", bundle: .appLanguage))
        }
        return parts
    }

    /// Playlists hold plain video bookmarks only, so web, scene and packaged-video items get no row.
    private static func playlistBookmarkData(for item: LibraryItem) -> Data? {
        switch item.source {
        case let .bookmark(bookmark):
            guard case let .video(data, nil) = bookmark.content else { return nil }
            return data
        case let .aerial(asset):
            return asset.bookmarkData
        #if !LITE_BUILD
        case .workshop:
            return nil
        #endif
        }
    }

    private static func revealBookmark(for item: LibraryItem) -> Data? {
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
