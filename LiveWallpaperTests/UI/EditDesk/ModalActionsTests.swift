import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Edit Desk modal actions")
struct ModalActionsTests {
    @MainActor
    private final class Fixture {
        var items: [LiveWallpaper.LibraryItem] = []
        var displays: [ModalActions.Display] = []
        var applied: [(ApplyIntent, CGDirectDisplayID)] = []
        var appliedToAll: [[CGDirectDisplayID]] = []
        let bookmarks = BookmarkStore(persistence: MemoryBookmarks())

        func inputs() -> ModalActions.Inputs {
            var inputs = ModalActions.Inputs()
            inputs.item = { id in self.items.first { $0.id == id } }
            inputs.displays = { self.displays }
            #if !LITE_BUILD
            inputs.localInfo = { _ in nil }
            #endif
            return inputs
        }

        func modal(inputs: ModalActions.Inputs? = nil, cache: ShelfThumbnailCache = ShelfThumbnailCache()) -> ModalActions {
            ModalActions(
                inputs: inputs ?? self.inputs(), bookmarks: bookmarks, thumbnails: cache,
                apply: { self.applied.append(($0, $1)) }, applyToAll: { self.appliedToAll.append($1) }
            )
        }
    }

    @MainActor
    private final class MemoryBookmarks: BookmarkPersisting {
        func load() -> [WallpaperBookmark] {
            []
        }

        func save(_: [WallpaperBookmark]) {}
    }

    private func item(_ bookmark: WallpaperBookmark) -> LiveWallpaper.LibraryItem {
        let kind: LiveWallpaper.LibraryItem.Kind = switch bookmark.content {
        case .video: .video
        case .html: .web
        case .scene: .scene
        }
        return LiveWallpaper.LibraryItem(
            id: "bookmark:\(bookmark.id)", title: bookmark.label, kind: kind, source: .bookmark(bookmark),
            isSteam: false, createdAt: bookmark.createdAt, lastUsedAt: bookmark.lastUsedAt, onDisplays: [],
            thumbnail: .bookmark(bookmark), metadata: nil, isVariant: false, parentID: nil, isSupported: true
        )
    }

    private func video() -> WallpaperBookmark {
        WallpaperBookmark(label: "Video", content: .video(bookmarkData: Data([1])))
    }

    private func displays() -> [ModalActions.Display] {
        [
            .init(id: 3, name: "Right", frame: CGRect(x: 1600, y: 0, width: 1200, height: 900)),
            .init(id: 1, name: "Left", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
            .init(id: 2, name: "Center", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
        ]
    }

    @Test func targetsKeepSpatialOrderAfterApplying() throws {
        let fixture = Fixture()
        fixture.displays = displays()
        var item = item(video())
        item.onDisplays = [1]
        let cover = try image()
        let modal = fixture.modal()
        let targets = modal.targets(for: item, covers: [2: cover])
        #expect(targets.map(\.id) == [1, 2, 3])
        #expect(targets.map(\.shortcutIndex) == [1, 2, 3])
        #expect(targets.filter(\.isPrimary).map(\.id) == [1] as [CGDirectDisplayID])
        #expect(targets.filter(\.isApplied).map(\.id) == [1] as [CGDirectDisplayID])
        let expectedRatios: [CGFloat] = [1920.0 / 1080, 1.6, 1200.0 / 900]
        #expect(targets.map(\.aspectRatio) == expectedRatios)
        #expect(targets[1].thumbnail === cover)
        #expect(targets[0].thumbnail == nil)
        item.onDisplays = [2]
        let reapplied = modal.targets(for: item)
        #expect(ModalGeometry.applyButtons(targets: reapplied).primary?.id == 1)
        #expect(reapplied.filter(\.isApplied).map(\.id) == [2] as [CGDirectDisplayID])
        item.onDisplays = [1, 2, 3]
        #expect(modal.targets(for: item).filter(\.isPrimary).map(\.id) == [1] as [CGDirectDisplayID])
    }

    @Test func preselectedDisplayTakesThePrimaryButton() {
        let fixture = Fixture()
        fixture.displays = displays()
        let modal = fixture.modal()
        let item = item(video())
        let preselected = modal.targets(for: item, preferred: 3)
        #expect(preselected.filter(\.isPrimary).map(\.id) == [3])
        #expect(preselected.map(\.shortcutIndex) == [1, 2, 3])
        #expect(ModalGeometry.applyButtons(targets: preselected).primary?.id == 3)
        // A preselected display that is gone leaves the leftmost one primary.
        #expect(modal.targets(for: item, preferred: 99).filter(\.isPrimary).map(\.id) == [1])
    }

    @Test func videoMetadataOmitsMissingParts() async throws {
        let modal = Fixture().modal()
        var item = item(video())
        let bare = await modal.content(for: item)
        #expect(bare.metaParts == [String(localized: "Local", bundle: .appLanguage)])
        #expect(bare.tags.isEmpty)
        item.metadata = .video(.init(
            resolution: CGSize(width: 3840, height: 2160), isHDR: true, duration: 60,
            fileSize: 2_000_000, probedAt: .distantPast
        ))
        item.lastUsedAt = Date().addingTimeInterval(-3600)
        let content = await modal.content(for: item)
        #expect(content.metaParts.count == 4)
        #expect(Array(content.metaParts.prefix(3)) == [
            String(localized: "Local", bundle: .appLanguage),
            WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: 2_000_000),
            "4K",
        ])
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguagePreference.current.locale
        let relative = try formatter.localizedString(for: #require(item.lastUsedAt), relativeTo: Date())
        #expect(content.metaParts.last == String(localized: "Last used \(relative)", bundle: .appLanguage))
        #expect(content.metaParts.allSatisfy { !$0.isEmpty })
        #expect(content.tags == ["4K", "HDR"])
        #expect(content.preview == nil)
        #expect(content.installed == nil)
    }

    @Test func bookmarkActionsUseCurrentIdentityAndDisappearWithTheItem() throws {
        let fixture = Fixture()
        let saved = fixture.bookmarks.add(label: "Saved", content: .video(bookmarkData: Data([1])))
        var current = item(saved)
        fixture.items = [current]
        let modal = fixture.modal()
        let actions = modal.actions(for: current)
        #expect(actions.removeFromSaved != nil)
        #expect(actions.deleteInstalled == nil)
        #expect(actions.checkForUpdate == nil)
        #expect(actions.cancelUpdate == nil)
        #expect(actions.openInSteam == nil)
        var renamed = saved
        renamed.label = "Renamed"
        current.source = .bookmark(renamed)
        fixture.items = [current]
        actions.applyTo(9)
        guard case let .bookmark(received) = try #require(fixture.applied.first).0 else {
            Issue.record("Expected bookmark intent")
            return
        }
        #expect(received == renamed)
        #expect(fixture.applied.first?.1 == 9)
        fixture.items = []
        actions.applyTo(9)
        actions.removeFromSaved?()
        #expect(fixture.applied.count == 1)
        #expect(fixture.bookmarks.bookmarks.count == 1)
        fixture.items = [current]
        actions.removeFromSaved?()
        #expect(fixture.bookmarks.bookmarks.isEmpty)
    }

    private func undoStack(_ fixture: Fixture) -> EditDeskUndoStack {
        let manager = UndoTestManager()
        return EditDeskUndoStack(
            manager: manager, router: ApplyRouter(manager: manager, bookmarks: fixture.bookmarks, sceneCapable: true),
            bookmarks: fixture.bookmarks
        )
    }

    @Test("Remove from Wallpaper Library records one step at the index the entry had, which undo puts back", .timeLimit(.minutes(1)))
    func removeFromSavedRecordsItsIndex() async throws {
        let fixture = Fixture()
        let before = fixture.bookmarks.add(label: "Before", content: .video(bookmarkData: Data([1])))
        let saved = fixture.bookmarks.add(label: "Saved", content: .video(bookmarkData: Data([2])))
        let after = fixture.bookmarks.add(label: "After", content: .video(bookmarkData: Data([3])))
        fixture.items = [item(saved)]
        let undo = undoStack(fixture)
        let modal = ModalActions(
            inputs: fixture.inputs(), bookmarks: fixture.bookmarks, thumbnails: ShelfThumbnailCache(), undo: undo,
            apply: { _, _ in }, applyToAll: { _, _ in }
        )

        modal.actions(for: item(saved)).removeFromSaved?()

        #expect(fixture.bookmarks.bookmarks.map(\.id) == [before.id, after.id])
        guard case let .bookmark(recorded, index)? = undo.undoSteps.last?.change else {
            Issue.record("Remove from Wallpaper Library recorded no step")
            return
        }
        #expect(recorded == saved)
        #expect(index == 1)
        _ = try #require(await undo.undo())
        #expect(fixture.bookmarks.bookmarks.map(\.id) == [before.id, saved.id, after.id])
    }

    @Test("A saved entry renames through the store as one undoable step; other items have no Rename", .timeLimit(.minutes(1)))
    func savedEntryRenames() async throws {
        let fixture = Fixture()
        let saved = fixture.bookmarks.add(label: "Saved", content: .video(bookmarkData: Data([1])))
        fixture.items = [item(saved)]
        let undo = undoStack(fixture)
        let modal = ModalActions(
            inputs: fixture.inputs(), bookmarks: fixture.bookmarks, thumbnails: ShelfThumbnailCache(), undo: undo,
            apply: { _, _ in }, applyToAll: { _, _ in }
        )

        let rename = try #require(modal.actions(for: item(saved)).rename)
        rename("  Renamed  ")

        #expect(fixture.bookmarks.bookmarks.map(\.label) == ["Renamed"])
        #expect(undo.undoSteps.map(\.action) == [.renameWallpaper])
        _ = try #require(await undo.undo())
        #expect(fixture.bookmarks.bookmarks.map(\.label) == ["Saved"])
        #if !LITE_BUILD
        #expect(modal.actions(for: workshop("123")).rename == nil, "a Workshop item's name comes from Steam")
        #endif
    }

    @Test("The … rows every menu draws follow the item, and apply rows grey out for an item this Mac can't run")
    func menuRowsFollowTheItem() throws {
        let fixture = Fixture()
        fixture.displays = displays()
        let saved = fixture.bookmarks.add(label: "Saved", content: .video(bookmarkData: Data([1])))
        var current = item(saved)
        fixture.items = [current]
        let modal = fixture.modal()
        var requested: [String] = []
        let rows = modal.menuItems(
            for: current, requestRename: { requested.append("rename") }, requestDelete: { requested.append("delete") }
        )

        #expect(rows.map(\.title) == [
            String(localized: "Apply to", bundle: .appLanguage),
            String(localized: "All Displays", bundle: .appLanguage),
            String(localized: "Show in Finder", bundle: .appLanguage),
            String(localized: "Rename", bundle: .appLanguage),
            String(localized: "Remove from Wallpaper Library", bundle: .appLanguage),
        ])
        try #require(rows.count == 5)
        #expect(rows.map(\.isEnabled) == [true, true, true, true, true])
        #expect(rows.map(\.isDestructive) == [false, false, false, false, true])
        #expect(rows[0].submenu.map(\.title) == ["Left", "Center", "Right"])
        try #require(rows[0].submenu.count == 3)
        rows[0].submenu[1].action()
        #expect(fixture.applied.map(\.1) == [2])
        rows[3].action()
        #expect(requested == ["rename"])

        current.isSupported = false
        fixture.items = [current]
        let blocked = modal.menuItems(for: current, requestRename: {}, requestDelete: {})
        #expect(blocked.prefix(2).map(\.isEnabled) == [false, false], "an item this Mac can't run still offers to apply it")
        #if !LITE_BUILD
        let installed = modal.menuItems(
            for: workshop("123"), requestRename: { requested.append("rename") }, requestDelete: { requested.append("delete") }
        )
        #expect(installed.map(\.title) == [
            String(localized: "Apply to", bundle: .appLanguage),
            String(localized: "All Displays", bundle: .appLanguage),
            String(localized: "Show in Finder", bundle: .appLanguage),
            String(localized: "Open in Steam", bundle: .appLanguage),
            String(localized: "Check for updates", bundle: .appLanguage),
            String(localized: "Delete", bundle: .appLanguage),
        ])
        installed.last?.action()
        #expect(requested == ["rename", "delete"])
        #endif
    }

    @Test func applyAllReadsCurrentDisplays() {
        let fixture = Fixture()
        let item = item(video())
        fixture.items = [item]
        fixture.displays = displays()
        let actions = fixture.modal().actions(for: item)
        fixture.displays.removeFirst()
        actions.applyToAllDisplays()
        #expect(fixture.appliedToAll == [[1, 2]])
        fixture.items = []
        actions.applyToAllDisplays()
        #expect(fixture.appliedToAll.count == 1)
    }

    @Test("All Displays goes to the group closure once, with every display")
    func applyAllGoesToTheGroupOnce() {
        let fixture = Fixture()
        let item = item(video())
        fixture.items = [item]
        fixture.displays = displays()
        var groups: [[CGDirectDisplayID]] = []
        let modal = ModalActions(
            inputs: fixture.inputs(), bookmarks: fixture.bookmarks, thumbnails: ShelfThumbnailCache(),
            apply: { fixture.applied.append(($0, $1)) },
            applyToAll: { _, ids in groups.append(ids) }
        )
        modal.actions(for: item).applyToAllDisplays()
        #expect(groups == [[3, 1, 2]])
        #expect(fixture.applied.isEmpty, "each display was also applied on its own")
    }

    @Test("An aerial applies through its own file's bookmark and can show in Finder")
    func aerialAppliesThroughItsBookmark() throws {
        let fixture = Fixture()
        let asset = AerialAsset(
            id: "sky", url: URL(fileURLWithPath: "/sky.mov"), displayName: "Sky",
            category: nil, fileSize: nil, bookmarkData: Data([2])
        )
        var item = LiveWallpaper.LibraryItem(
            id: "aerial:sky", title: "Sky", kind: .aerial, source: .aerial(asset), isSteam: false,
            createdAt: .distantPast, lastUsedAt: nil, onDisplays: [], thumbnail: nil,
            metadata: nil, isVariant: false, parentID: nil, isSupported: true
        )
        fixture.items = [item]
        let actions = fixture.modal().actions(for: item)
        actions.applyTo(2)
        guard case let .bookmark(bookmark) = try #require(fixture.applied.first).0 else {
            Issue.record("Expected the aerial's bookmark intent")
            return
        }
        #expect(bookmark.content == .video(bookmarkData: asset.bookmarkData))
        #expect(bookmark.label == "Sky")
        #expect(actions.showInFinder != nil)
        #expect(actions.rename == nil)
        #expect(actions.removeFromSaved == nil)
        #expect(actions.deleteInstalled == nil)
        item.isSupported = false
        fixture.items = [item]
        actions.applyTo(2)
        #expect(fixture.applied.count == 1)
    }

    @Test func previewUsesTheHostsCacheAndRequestedDimensions() async throws {
        let fixture = Fixture()
        let original = try image()
        var loads = 0
        var sources = ShelfThumbnailCache.Sources()
        sources.video = { _, _, _ in loads += 1; return original }
        let cache = ShelfThumbnailCache(sources: sources)
        let modal = fixture.modal(cache: cache)
        var item = item(video())
        let size = CGSize(width: 80, height: 45)
        let request = try #require(item.thumbnail)
        #expect(cache.cached(request, pixelSize: size, scale: 2) == nil)
        let preview = try #require(await modal.preview(for: item, pixelSize: size, scale: 2))
        #expect(preview.width == 80 && preview.height == 45)
        #expect(cache.cached(request, pixelSize: size, scale: 2) === preview)
        #expect(await modal.preview(for: item, pixelSize: size, scale: 2) === preview)
        #expect(loads == 1)
        item.thumbnail = nil
        #expect(await modal.preview(for: item, pixelSize: size, scale: 2) == nil)
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    #if !LITE_BUILD
    private func workshop(_ id: String, importedAt: Date = .distantPast) -> LiveWallpaper.LibraryItem {
        let entry = WPEHistoryEntry(origin: WPEOrigin(
            workshopID: id, title: "Installed", originalType: .scene, sourceFolderBookmark: Data([3]),
            cacheRelativePath: id, previewFileName: nil, requiresWindowsPlugin: true
        ), importedAt: importedAt, sizeBytes: 5_000_000)
        return LiveWallpaper.LibraryItem(
            id: "workshop:\(id)", title: entry.origin.title, kind: .scene, source: .workshop(entry),
            isSteam: UInt64(id) != nil, createdAt: importedAt, lastUsedAt: nil, onDisplays: [],
            thumbnail: .workshop(entry), metadata: nil, isVariant: false, parentID: nil, isSupported: true
        )
    }

    @Test func unsupportedItemCannotApplyAndSaysWhy() async {
        let modal = Fixture().modal()
        var unsupported = workshop("123")
        unsupported.isSupported = false
        let blocked = await modal.content(for: unsupported)
        #expect(!blocked.canApply)
        #expect(blocked.notice == String(localized: "Can't run on this Mac", bundle: .appLanguage))
        var missing = item(video())
        missing.isSourceMissing = true
        let stale = await modal.content(for: missing)
        #expect(stale.canApply)
        #expect(stale.notice == DropFailure.sourceMissing.toastText)
    }

    @Test func unsupportedWorkshopItemExplainsWhy() async {
        let modal = Fixture().modal()
        func unsupported(_ type: WPEType, missing: [String]) -> LiveWallpaper.LibraryItem {
            let entry = WPEHistoryEntry(origin: WPEOrigin(
                workshopID: "456", title: "Needs parts", originalType: type, sourceFolderBookmark: Data([3]),
                cacheRelativePath: nil, previewFileName: nil, resourceLocation: .unsupported, missingDependencyIDs: missing
            ), importedAt: .distantPast)
            return LiveWallpaper.LibraryItem(
                id: "workshop:456", title: entry.origin.title, kind: .scene, source: .workshop(entry),
                isSteam: true, createdAt: .distantPast, lastUsedAt: nil, onDisplays: [], thumbnail: .workshop(entry),
                metadata: nil, isVariant: false, parentID: nil, isSupported: type != .application
            )
        }
        #expect(await modal.content(for: unsupported(.scene, missing: ["1", "2"])).unsupportedOrigin?.missingDependencyIDs == ["1", "2"])
        // The banner says why, so the one-line notice under the preview would only repeat it.
        let executable = await modal.content(for: unsupported(.application, missing: []))
        #expect(executable.unsupportedOrigin != nil)
        #expect(executable.notice == nil)
        #expect(!executable.canApply)
        // Control: an installed item this Mac can run has nothing to explain.
        #expect(await modal.content(for: workshop("123")).unsupportedOrigin == nil)
    }

    @Test func installedActionsKeepWorkshopIdentityAndNumericSteamLinks() throws {
        let fixture = Fixture()
        let item = workshop("123")
        fixture.items = [item]
        var updated: [WPEHistoryEntry] = []
        var deleted: [WPEHistoryEntry] = []
        var cancelled: [UInt64] = []
        var inputs = fixture.inputs()
        inputs.update = { updated.append($0) }
        inputs.deleteInstalled = { entry, _ in deleted.append(entry) }
        inputs.cancelUpdate = { cancelled.append($0) }
        let modal = fixture.modal(inputs: inputs)
        let actions = modal.actions(for: item)
        #expect(actions.removeFromSaved == nil)
        #expect(actions.deleteInstalled != nil)
        #expect(actions.openInSteam != nil)
        #expect(actions.showInFinder != nil)
        #expect(actions.checkForUpdate != nil)
        #expect(actions.cancelUpdate != nil)
        let refreshed = workshop("123", importedAt: Date(timeIntervalSince1970: 10))
        fixture.items = [refreshed]
        actions.applyTo(3)
        actions.checkForUpdate?()
        actions.cancelUpdate?()
        actions.deleteInstalled?()
        guard case let .workshop(entry) = refreshed.source,
              case let .installedWorkshop(received) = try #require(fixture.applied.first).0 else {
            Issue.record("Expected installed Workshop intent")
            return
        }
        #expect(received == entry)
        #expect(updated == [entry])
        #expect(deleted == [entry])
        #expect(cancelled == [123])
        fixture.items = []
        actions.applyTo(3)
        actions.checkForUpdate?()
        actions.cancelUpdate?()
        actions.deleteInstalled?()
        #expect(fixture.applied.count == 1)
        #expect(updated.count == 1 && deleted.count == 1 && cancelled.count == 1)
        let local = modal.actions(for: workshop("local-folder"))
        #expect(local.openInSteam == nil)
        #expect(local.checkForUpdate == nil)
        #expect(local.deleteInstalled != nil)
    }

    @Test func installedUpdateFlagsDistinguishAvailableFromUpToDate() async {
        let fixture = Fixture()
        let item = workshop("123", importedAt: Date(timeIntervalSince1970: 10))
        guard case let .workshop(entry) = item.source else { return }
        var remoteEpochs: [String: Double] = [:]
        let model = InstalledLibraryModel(dependencies: .init(
            loadEntries: { [entry] }, loadRemoteUpdateEpochs: { remoteEpochs },
            saveRemoteUpdateEpochs: { _ in }, loadLastUpdateCheckEpoch: { 100 },
            saveLastUpdateCheckEpoch: { _ in }, makeMetadataService: { SteamWorkshopMetadataService() },
            now: { Date(timeIntervalSince1970: 100) }, prefetchPreviewURLs: { _ in }
        ))
        var inputs = fixture.inputs()
        inputs.installedLibrary = model
        let modal = fixture.modal(inputs: inputs)
        model.onAppear()
        #expect(await modal.content(for: item).installed?.updateState == .upToDate)
        remoteEpochs = ["123": 20]
        model.onAppear()
        #expect(await modal.content(for: item).installed?.updateState == .available)
        model.onDisappear()
    }

    @Test func installedStateKeyFollowsTheDailyCheck() {
        let fixture = Fixture()
        let item = workshop("123", importedAt: Date(timeIntervalSince1970: 10))
        let other = workshop("999", importedAt: Date(timeIntervalSince1970: 10))
        guard case let .workshop(entry) = item.source, case let .workshop(otherEntry) = other.source else { return }
        var remoteEpochs: [String: Double] = [:]
        let model = InstalledLibraryModel(dependencies: .init(
            loadEntries: { [entry, otherEntry] }, loadRemoteUpdateEpochs: { remoteEpochs },
            saveRemoteUpdateEpochs: { _ in }, loadLastUpdateCheckEpoch: { 100 },
            saveLastUpdateCheckEpoch: { _ in }, makeMetadataService: { SteamWorkshopMetadataService() },
            now: { Date(timeIntervalSince1970: 100) }, prefetchPreviewURLs: { _ in }
        ))
        var inputs = fixture.inputs()
        inputs.installedLibrary = model
        let modal = fixture.modal(inputs: inputs)
        model.onAppear()
        let before = modal.installedStateKey(for: item)
        // Control: another item's flag leaves this item's key alone.
        remoteEpochs = ["999": 20]
        model.onAppear()
        #expect(model.updatedWorkshopIDs == ["999"])
        #expect(modal.installedStateKey(for: item) == before)
        remoteEpochs = ["123": 20]
        model.onAppear()
        #expect(modal.installedStateKey(for: item) != before)
        model.onDisappear()
    }

    @Test func installedContentKeepsLocalMetadataAndUpdateProgress() async throws {
        let fixture = Fixture()
        fixture.displays = displays()
        var item = workshop("123")
        item.onDisplays = [2]
        var inputs = fixture.inputs()
        inputs.localInfo = { _ in
            LocalProjectInfo(cleanedDescription: "Description", tags: ["Nature"], contentRating: nil, sizeBytes: nil)
        }
        var phase = WorkshopDownloadCoordinator.DownloadPhase.downloading
        inputs.phase = { _ in phase }
        inputs.progress = { _ in 0.25 }
        let modal = fixture.modal(inputs: inputs)
        let content = await modal.content(for: item)
        #expect(content.tags == ["Nature"])
        #expect(content.metaParts == [
            String(localized: "Steam Workshop", bundle: .appLanguage),
            WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: 5_000_000),
        ])
        let installed = try #require(content.installed)
        #expect(installed.isWindowsOnly)
        #expect(modal.deletesFiles(item))
        #expect(installed.inUseOnDisplayNames == ["Center"])
        #expect(installed.updateState == .checking(progress: 0.25))
        phase = .failed("Offline")
        #expect(await modal.content(for: item).installed?.updateState == .failed(message: "Offline"))
        #expect(!modal.deletesFiles(workshop("local-folder")))
        var saved = video()
        if case let .workshop(entry) = item.source {
            saved.wpeOrigin = entry.origin
        }
        let bookmarked = await modal.content(for: self.item(saved))
        #expect(bookmarked.tags == ["Nature"])
        #expect(bookmarked.installed == nil)
        #expect(modal.actions(for: self.item(saved)).openInSteam != nil)
    }
    #endif
}
