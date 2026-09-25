import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Saved library model")
struct SavedLibraryModelTests {
    private func bookmark(_ title: String, used: Double? = nil, created: Double = 0) -> WallpaperBookmark {
        WallpaperBookmark(
            label: title, content: .video(bookmarkData: Data(title.utf8)),
            createdAt: Date(timeIntervalSince1970: created),
            lastUsedAt: used.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func aerial(_ id: String = "sky", in directory: String = "/", bookmark: String? = nil) -> AerialAsset {
        AerialAsset(
            id: id, url: URL(fileURLWithPath: directory).appendingPathComponent("\(id).mov"), displayName: id,
            category: nil, fileSize: nil, bookmarkData: Data((bookmark ?? id).utf8)
        )
    }

    private var fourK: LibraryMetadata {
        .video(.init(
            resolution: CGSize(width: 3840, height: 2160), isHDR: false,
            duration: 60, fileSize: 100, probedAt: .distantPast
        ))
    }

    private func inputs(_ bookmarks: [WallpaperBookmark] = [], aerials: [AerialAsset] = []) -> SavedLibraryModel.Inputs {
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { bookmarks }
        inputs.aerials = { .init(assets: aerials, isAuthorized: true, lastScanError: nil, isScanning: false) }
        return inputs
    }

    @Test func allIncludesAerials() {
        let saved = bookmark("Saved")
        let model = SavedLibraryModel(inputs: inputs([saved], aerials: [aerial()]))
        model.chip = .all
        #expect(model.items.count == 2)
        #expect(model.visibleItems.map(\.id) == ["bookmark:\(saved.id)", "aerial:/sky.mov"])
        #expect(model.visibleItems.first?.thumbnail == .bookmark(saved))
    }

    @Test func recentNarrowsBeforeSortingAndSearching() {
        let saved = (0 ..< 16).map { bookmark(String(format: "%02d", $0), used: Double($0)) }
        let model = SavedLibraryModel(inputs: inputs(saved + [bookmark("Unused")]))
        model.chip = .recent
        #expect(model.visibleItems.map(\.title) == (2 ..< 16).reversed().map { String(format: "%02d", $0) })
        model.sort = .name
        #expect(model.visibleItems.map(\.title) == (2 ..< 16).map { String(format: "%02d", $0) })
        model.query = "00"
        #expect(model.visibleItems.isEmpty)
        model.query = ""
        model.sort = .type
        #expect(model.visibleItems.count == 14)
    }

    @Test func steamRequiresANonemptyNumericOrigin() {
        var steam = bookmark("Steam")
        steam.wpeOrigin = origin("123")
        var local = bookmark("Folder")
        local.wpeOrigin = origin("local-123")
        var empty = bookmark("Empty")
        empty.wpeOrigin = origin("")
        let model = SavedLibraryModel(inputs: inputs([steam, local, empty, bookmark("Plain")]))
        model.chip = .steam
        #expect(model.visibleItems.map(\.title) == ["Steam"])
    }

    @Test func localExcludesSteamAndAerials() {
        var steam = bookmark("Steam")
        steam.wpeOrigin = origin("123")
        let model = SavedLibraryModel(inputs: inputs([steam, bookmark("Local")], aerials: [aerial()]))
        model.chip = .local
        #expect(model.visibleItems.map(\.title) == ["Local"])
    }

    @Test func aerialsHaveTheirOwnRows() {
        let model = SavedLibraryModel(inputs: inputs([bookmark("Saved")], aerials: [aerial()]))
        model.chip = .aerials
        #expect(model.visibleItems.map(\.id) == ["aerial:/sky.mov"])
        #expect(model.visibleItems.first?.kind == .aerial)
        #expect(model.visibleItems.first?.createdAt == .distantPast)
        #expect(model.visibleItems.first?.thumbnail == .aerial(.init(aerial())))
    }

    @Test("An aerial row is keyed by its file: two files with one name keep two rows, a rescan keeps the ID")
    func aerialRowsAreKeyedByTheirFile() {
        let scanned = SavedLibraryModel(inputs: inputs(aerials: [
            aerial(in: "/4K", bookmark: "4K"), aerial(in: "/HD", bookmark: "HD"),
        ]))
        let ids = Set(scanned.visibleItems.map(\.id))
        #expect(ids.count == 2, "two files named sky.mov share one row ID")
        let rescanned = SavedLibraryModel(inputs: inputs(aerials: [
            aerial(in: "/4K", bookmark: "4K again"), aerial(in: "/HD", bookmark: "HD again"),
        ]))
        #expect(Set(rescanned.visibleItems.map(\.id)) == ids, "a rescan's new bookmarks changed the rows' IDs")
    }

    @Test func nowPlayingPreservesDisplayIDs() {
        let playing = bookmark("Playing")
        var source = inputs([playing, bookmark("Idle")])
        let displays: [CGDirectDisplayID: WallpaperContent] = [7: playing.content, 42: playing.content]
        #if !LITE_BUILD
        source.nowPlaying = { content, _ in displays.filter { $0.value == content }.map(\.key).sorted() }
        #else
        source.nowPlaying = { content in displays.filter { $0.value == content }.map(\.key).sorted() }
        #endif
        let model = SavedLibraryModel(inputs: source)
        #expect(model.items.first { $0.title == "Playing" }?.onDisplays == [7, 42])
        #expect(model.items.first { $0.title == "Idle" }?.onDisplays == [])
    }

    @Test("The filter chips are All, Recent, Steam, Local and Aerials")
    func chipsAreTheFiveFilters() {
        #expect(SavedLibraryModel.Chip.allCases == [.all, .recent, .steam, .local, .aerials])
    }

    @Test func recentlyUsedSortPutsNilLastAndBreaksTiesByCreation() {
        let model = SavedLibraryModel(inputs: inputs([
            bookmark("Old tie", used: 10, created: 1), bookmark("Nil old", created: 1),
            bookmark("Newest", used: 20), bookmark("New tie", used: 10, created: 2),
            bookmark("Nil new", created: 2),
        ]))
        model.sort = .recentlyUsed
        #expect(model.visibleItems.map(\.title) == ["Newest", "New tie", "Old tie", "Nil new", "Nil old"])
    }

    @Test("A browse keeps the order it opened with; the next one sorts by the new use")
    func browsingKeepsTheOrderItOpenedWith() {
        var saved = [bookmark("A", used: 3), bookmark("B", used: 2), bookmark("C")]
        var source = inputs()
        source.bookmarks = { saved }
        let model = SavedLibraryModel(inputs: source)
        model.beginBrowsing()
        saved[2].lastUsedAt = Date(timeIntervalSince1970: 4)
        model.refresh()
        // The modal opening over the open shelf begins again inside the same browse.
        model.beginBrowsing()
        #expect(model.visibleItems.map(\.title) == ["A", "B", "C"], "applying C moved it while the browse was open")
        model.chip = .recent
        #expect(model.visibleItems.map(\.title) == ["A", "B"])
        model.chip = .all
        model.endBrowsing()
        #expect(model.visibleItems.map(\.title) == ["C", "A", "B"])
    }

    @Test func nameSortIgnoresCase() {
        let model = SavedLibraryModel(inputs: inputs([bookmark("zebra"), bookmark("Beta"), bookmark("alpha")]))
        model.sort = .name
        #expect(model.visibleItems.map(\.title) == ["alpha", "Beta", "zebra"])
    }

    @Test func typeSortUsesKindThenName() {
        var web = bookmark("A web", used: 1)
        web.content = .html(source: .url(URL(fileURLWithPath: "/web")), config: .init())
        var scene = bookmark("A scene", used: 1)
        scene.content = .scene(descriptor())
        let source = inputs([scene, bookmark("Z video", used: 1), web, bookmark("B video", used: 1)], aerials: [aerial()])
        let model = SavedLibraryModel(inputs: source)
        model.chip = .all
        model.sort = .type
        #expect(model.visibleItems.map(\.kind) == [.video, .video, .web, .scene, .aerial])
        #expect(model.visibleItems.prefix(2).map(\.title) == ["B video", "Z video"])
    }

    @Test func queryOnlyMatchesTitleWithoutCaseSensitivity() {
        var hidden = bookmark("Other")
        hidden.sourceDisplayName = "sunset"
        let model = SavedLibraryModel(inputs: inputs([hidden, bookmark("Golden SUNSET")]))
        model.query = "sunSet"
        #expect(model.visibleItems.map(\.title) == ["Golden SUNSET"])
        model.query = ""
        #expect(model.visibleItems.count == 2)
    }

    @Test("A search finds rows by the whole name of their type")
    func searchFindsRowsByTheWholeNameOfTheirType() {
        var web = bookmark("Beta")
        web.content = .html(source: .url(URL(fileURLWithPath: "/web")), config: .init())
        let model = SavedLibraryModel(inputs: inputs([bookmark("Alpha"), web]))
        let name = LibraryItem.Kind.web.localizedName
        model.query = name
        #expect(model.visibleItems.map(\.title) == ["Beta"], "the web row is not found by its type's name")
        model.query = String(name.prefix(1))
        #expect(model.visibleItems.isEmpty, "the first character of a type's name matched that type's rows")
    }

    @Test func aerialsStatusMirrorsInputsOnRefresh() {
        let scanning = SavedLibraryModel.AerialsState(
            assets: [], isAuthorized: false, lastScanError: "scan failed", isScanning: true
        )
        let ready = SavedLibraryModel.AerialsState(assets: [aerial()], isAuthorized: true, lastScanError: nil, isScanning: false)
        let states = StateBox(scanning)
        var source = inputs()
        source.aerials = { states.value }
        let model = SavedLibraryModel(inputs: source)
        #expect(!model.aerialsStatus.isAuthorized)
        #expect(model.aerialsStatus.lastScanError == "scan failed")
        #expect(model.aerialsStatus.isScanning)
        #expect(model.aerialsStatus.isEmpty)
        states.value = ready
        model.refresh()
        #expect(model.aerialsStatus.isAuthorized)
        #expect(model.aerialsStatus.lastScanError == nil)
        #expect(!model.aerialsStatus.isScanning)
        #expect(!model.aerialsStatus.isEmpty)
    }

    @Test func probeMetadataOnlyUpdatesRequestedVideoItems() async {
        let first = bookmark("First")
        let second = bookmark("Second")
        var web = bookmark("Web")
        web.content = .html(source: .url(URL(fileURLWithPath: "/web")), config: .init())
        var probed: [UUID] = []
        var cacheIsReady = false
        var source = inputs([first, second, web], aerials: [aerial()])
        source.metadata = { _ in cacheIsReady ? fourK : nil }
        source.probeMetadata = {
            probed.append($0.id)
            cacheIsReady = true
            return fourK
        }
        let model = SavedLibraryModel(inputs: source)
        #expect(probed.isEmpty)
        await model.probeMetadata(for: ["bookmark:\(first.id)", "bookmark:\(first.id)", "bookmark:\(web.id)", "missing"])
        #expect(probed == [first.id])
        #expect(model.items.first { $0.id == "bookmark:\(first.id)" }?.metadata == fourK)
        #expect(model.items.first { $0.id == "bookmark:\(second.id)" }?.metadata == nil)
        #expect(model.items.first { $0.id == "aerial:/sky.mov" }?.metadata == nil)
    }

    @Test func missingSourcesAreMarkedAndProbedOnce() async {
        let present = bookmark("Present")
        let missing = bookmark("Missing")
        var probes = 0
        var source = inputs([present, missing])
        source.sourceAvailable = { item in
            probes += 1
            guard case let .bookmark(bookmark) = item else { return true }
            return bookmark.id != missing.id
        }
        let model = SavedLibraryModel(inputs: source)
        await model.probeSources()
        #expect(model.items.filter(\.isSourceMissing).map(\.id) == ["bookmark:\(missing.id)"])
        let probed = probes
        model.refresh()
        #expect(probes == probed, "an unchanged row was probed again")
        #expect(model.items.filter(\.isSourceMissing).map(\.id) == ["bookmark:\(missing.id)"])
    }

    @Test("Applying an aerial rechecks the aerial's own row")
    func recheckFindsTheAerialItsIntentCameFrom() async throws {
        var probes = 0
        var source = inputs(aerials: [aerial()])
        // Found by the first probe, gone for every later one.
        source.sourceAvailable = { _ in
            probes += 1
            return probes == 1
        }
        let model = SavedLibraryModel(inputs: source)
        await model.probeSources()
        let row = try #require(model.items.first)
        let intent = try #require(ModalActions.intent(for: row))
        await model.recheck(intent)
        #expect(model.items.first?.isSourceMissing == true, "the recheck after applying the aerial skipped its row")
    }

    @Test("A display still holding the bookmark an aerial had before a rescan marks and rechecks that aerial's row")
    func aerialRowIsMatchedByFileAfterARescan() async {
        let beforeRescan = Data("sky before the rescan".utf8)
        let other = Data("another video".utf8)
        var source = inputs(aerials: [aerial()])
        source.activeWallpapers = { [(7, .video(bookmarkData: beforeRescan)), (9, .video(bookmarkData: other))] }
        let paths = [beforeRescan: "/sky.mov", other: "/other.mov"]
        var resolves = 0
        source.filePath = { data in
            resolves += 1
            return paths[data]
        }
        var probes = 0
        // Found by the first probe, gone for every later one.
        source.sourceAvailable = { _ in
            probes += 1
            return probes == 1
        }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.items.first?.onDisplays == [7], "the rescan's new bookmark hid the display still running this aerial")
        let resolved = resolves
        #expect(model.aerial(aerial(), matches: .video(bookmarkData: beforeRescan)))
        #expect(resolves == resolved, "matching again before the next refresh resolved the same bookmark again")
        await model.probeSources()
        await model.recheck(.bookmark(WallpaperBookmark(label: "sky", content: .video(bookmarkData: beforeRescan))))
        #expect(model.items.first?.isSourceMissing == true, "applying the aerial as it was before the rescan skipped its row")
    }

    @Test("A refresh resolves the bookmarks the displays run, not one per aerial")
    func refreshResolvesOnlyTheDisplaysBookmarks() {
        let films = [Data("film".utf8): "/Movies/film.mov", Data("other film".utf8): "/Movies/other film.mov"]
        var source = inputs(aerials: (0 ..< 100).map { aerial("sky \($0)") })
        source.activeWallpapers = { [(7, .video(bookmarkData: Data("film".utf8))), (9, .video(bookmarkData: Data("other film".utf8)))] }
        var resolves = 0
        source.filePath = { data in
            resolves += 1
            return films[data]
        }
        _ = SavedLibraryModel(inputs: source)
        #expect(resolves <= 2, "the refresh resolved each aerial's bookmark to compare it with the displays")
    }

    @Test("A bookmark that did not resolve is resolved again by the next refresh")
    func unresolvedBookmarkIsRetriedOnTheNextRefresh() {
        let playing = Data("sky from an earlier scan".utf8)
        var source = inputs(aerials: [aerial()])
        source.activeWallpapers = { [(7, .video(bookmarkData: playing))] }
        var resolvable = false
        source.filePath = { $0 != playing || resolvable ? "/sky.mov" : nil }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.items.first?.onDisplays == [])
        resolvable = true
        model.refresh()
        #expect(model.items.first?.onDisplays == [7], "a bookmark that failed to resolve once was never resolved again")
    }

    @Test("A rescan's new bookmark keeps an aerial's missing mark without probing the same file again")
    func rescanKeepsTheAerialsProbe() async {
        let scan = StateBox(.init(assets: [aerial()], isAuthorized: true, lastScanError: nil, isScanning: false))
        var source = inputs()
        source.aerials = { scan.value }
        var probes = 0
        source.sourceAvailable = { _ in
            probes += 1
            return false
        }
        let model = SavedLibraryModel(inputs: source)
        await model.probeSources()
        let probed = probes
        scan.value.assets = [aerial(bookmark: "sky after the rescan")]
        model.refresh()
        #expect(model.items.first?.isSourceMissing == true, "the rescan's new bookmark cleared the missing mark")
        await model.probeSources()
        #expect(probes == probed, "the rescan probed the same file again")
        let beforeMove = probes
        scan.value.assets = [aerial(in: "/moved")]
        model.refresh()
        await model.probeSources()
        #expect(probes == beforeMove + 1, "a file at a new path was not probed")
    }

    /// Holds each availability probe until the test answers it, so the test picks the order they finish in.
    @MainActor
    private final class ProbeGate {
        private var parked: [CheckedContinuation<Bool, Never>] = []

        var pending: Int {
            parked.count
        }

        func park() async -> Bool {
            await withCheckedContinuation { parked.append($0) }
        }

        func answer(_ index: Int, available: Bool) {
            parked.remove(at: index).resume(returning: available)
        }
    }

    private func settle(_ isDone: () -> Bool) async {
        for _ in 0 ..< 200 where !isDone() {
            await Task.yield()
        }
    }

    @Test("An older probe that finishes after a recheck does not overwrite the recheck's result", .timeLimit(.minutes(1)))
    func lateProbeKeepsTheNewerResult() async {
        let row = bookmark("Row")
        let gate = ProbeGate()
        var source = inputs([row])
        source.aerials = { .init() }
        source.sourceAvailable = { _ in await gate.park() }
        let model = SavedLibraryModel(inputs: source)
        await settle { gate.pending == 1 }
        let recheck = Task { await model.recheck(.bookmark(row)) }
        await settle { gate.pending == 2 }
        gate.answer(1, available: false)
        await recheck.value
        #expect(model.items.first?.isSourceMissing == true)
        gate.answer(0, available: true)
        // Every chance for the late answer to land.
        await settle { model.items.first?.isSourceMissing == false }
        #expect(model.items.first?.isSourceMissing == true, "the older probe overwrote the recheck's newer result")
    }

    @MainActor
    private final class StateBox {
        var value: SavedLibraryModel.AerialsState

        init(_ value: SavedLibraryModel.AerialsState) {
            self.value = value
        }
    }

    private func origin(_ id: String, type: WPEType = .scene) -> WPEOrigin {
        WPEOrigin(
            workshopID: id, title: "Installed \(id)", originalType: type,
            sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil
        )
    }

    private func descriptor(overrides: [String: WallpaperEngineProjectPropertyValue] = [:]) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "123", cacheRelativePath: "scene", entryFile: "scene.json", capabilityTier: .imageOnly,
            propertyOverrides: overrides, presetID: "preset", presetSnapshot: ["speed": .number(1)]
        )
    }

    #if !LITE_BUILD
    @Test func workshopFoldKeepsLatestUsageAndInstalledIdentity() {
        let entry = WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast, lastUsedAt: Date(timeIntervalSince1970: 2))
        var saved = bookmark("Saved", used: 3)
        saved.wpeOrigin = entry.origin
        saved.content = .scene(descriptor())
        var source = inputs([saved])
        source.history = { [entry] }
        source.nowPlaying = { _, history in history?.id == "123" ? [9] : [] }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.visibleItems.count == 1)
        #expect(model.visibleItems.first?.id == "workshop:123")
        #expect(model.visibleItems.first?.source == .workshop(entry))
        #expect(model.visibleItems.first?.lastUsedAt == saved.lastUsedAt)
        #expect(model.visibleItems.first?.onDisplays == [9])
        #expect(model.visibleItems.first?.isVariant == false)
        saved.lastUsedAt = Date(timeIntervalSince1970: 1)
        source.bookmarks = { [saved] }
        #expect(SavedLibraryModel(inputs: source).visibleItems.first?.lastUsedAt == entry.lastUsedAt)
    }

    @Test func sceneOverridesKeepAVariantRow() {
        let entry = WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast)
        var saved = bookmark("Variant")
        saved.wpeOrigin = entry.origin
        saved.content = .scene(descriptor(overrides: ["speed": .number(2)]))
        var source = inputs([saved])
        source.history = { [entry] }
        let model = SavedLibraryModel(inputs: source)
        let variant = model.items.first { $0.id == "bookmark:\(saved.id)" }
        #expect(model.visibleItems.count == 2)
        #expect(variant?.isVariant == true)
        #expect(variant?.parentID == "workshop:123")
        #expect(variant?.source == .bookmark(saved))
    }

    @Test func unsupportedInstalledTypesRemainInTheLibrary() {
        let types: [WPEType] = [.video, .web, .scene, .application, .unknown]
        var source = inputs()
        source.history = { types.map { WPEHistoryEntry(origin: origin($0.rawValue, type: $0), importedAt: .distantPast) } }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.visibleItems.count == 5)
        for item in model.visibleItems {
            let unsupported = item.id == "workshop:application" || item.id == "workshop:unknown"
            #expect(item.isSupported == !unsupported)
            if unsupported {
                #expect(item.kind == .scene)
            }
        }
    }

    @Test func installedVideoMetadataUsesResolvedContentWithoutASavedBookmark() async {
        let entry = WPEHistoryEntry(origin: origin("123", type: .video), importedAt: .distantPast)
        let content = WallpaperContent.video(bookmarkData: Data([1]))
        var source = inputs(aerials: [aerial()])
        source.history = { [entry] }
        source.workshopContent = { $0.id == entry.id ? content : nil }
        var probed: [WallpaperContent] = []
        source.probeMetadata = { probed.append($0.content); return fourK }
        let model = SavedLibraryModel(inputs: source)
        #expect(probed.isEmpty)
        await model.probeMetadata(for: ["workshop:123"])
        #expect(probed == [content])
        #expect(model.visibleItems.first?.metadata == fourK)
        #expect(model.items.first { $0.kind == .aerial }?.metadata == nil)
    }

    @Test("A search matches a Workshop project's tags once they are read")
    func searchMatchesWorkshopTagsOnceLoaded() async {
        let entry = WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast)
        var source = inputs()
        source.history = { [entry] }
        source.projectTags = { $0.workshopID == entry.id ? ["Landscape", "Nature"] : [] }
        let model = SavedLibraryModel(inputs: source)
        model.query = "landsc"
        #expect(model.visibleItems.isEmpty, "the project matched before its tags were read")
        await model.loadSearchTags()
        #expect(model.visibleItems.map(\.id) == ["workshop:123"], "the project's tags are not searched")
    }

    @Test("A search finds a Workshop project by its ID")
    func searchFindsAWorkshopProjectByItsID() {
        // Not `origin(_:)`: its title contains the ID, so the title alone would match.
        let sunset = WPEOrigin(
            workshopID: "2785019345", title: "Sunset", originalType: .scene,
            sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil
        )
        var source = inputs()
        source.history = { [WPEHistoryEntry(origin: sunset, importedAt: .distantPast)] }
        let model = SavedLibraryModel(inputs: source)
        model.query = "27850"
        #expect(model.visibleItems.map(\.id) == ["workshop:2785019345"], "the project is not found by part of its ID")
        model.query = "99999"
        #expect(model.visibleItems.isEmpty, "a project matched an ID it does not have")
    }

    @Test("Library card badges appear only while their switches are on; other rows keep now-playing and never need an update")
    func cardBadgesFollowTheWorkshopSwitches() throws {
        let entry = WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast)
        var variant = bookmark("Variant")
        variant.wpeOrigin = entry.origin
        variant.content = .scene(descriptor(overrides: ["speed": .number(2)]))
        var source = inputs([variant])
        source.history = { [entry] }
        source.nowPlaying = { _, _ in [1] }
        let model = SavedLibraryModel(inputs: source)
        let workshop = try #require(model.items.first { $0.id == "workshop:123" })
        let saved = try #require(model.items.first { $0.id == "bookmark:\(variant.id)" })
        let displays = [StageDisplay(
            id: 1, fingerprint: "Studio", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false,
            name: "Studio", badgeText: "", statusText: "", cover: nil, state: .ok
        )]
        let on = try #require(NowPlayingBadge(on: [1], among: displays))
        let shown = GalleryCardPreferences()
        let hidden = GalleryCardPreferences(showsUpdate: false, showsInUse: false)
        func badges(_ item: LibraryItem, _ preferences: GalleryCardPreferences) -> LibraryCardBadges {
            item.cardBadges(among: displays, updatedWorkshopIDs: ["123"], preferences: preferences)
        }
        #expect(badges(workshop, shown) == LibraryCardBadges(nowPlaying: on, needsUpdate: true))
        #expect(badges(workshop, hidden) == LibraryCardBadges(), "a switch that is off still shows its badge")
        #expect(badges(saved, shown) == LibraryCardBadges(nowPlaying: on), "only an installed project needs an update")
        #expect(badges(saved, hidden) == LibraryCardBadges(nowPlaying: on), "the Workshop switches hide a saved row's now-playing badge")
        // The tile reads the capsule the way a shelf card does.
        let playing = String(localized: "Playing on \("Studio")", bundle: .appLanguage)
        let reading = LibraryCardBadges(nowPlaying: on).accessibilityLabel(title: "Variant")
        #expect(reading == "Variant, \(playing)", Comment(rawValue: reading))
    }
    #endif

    @Test("Preparing the library sweeps covers against every saved entry, once")
    func prepareLibrarySweepsOrphanCovers() {
        var swept: [Set<String>] = []
        var source = inputs([bookmark("Saved")])
        source.savedCoverFileNames = { ["bookmark.png", "scheme.png"] }
        source.removeOrphanCovers = { swept.append($0) }
        let model = SavedLibraryModel(inputs: source)
        #expect(swept.isEmpty, "building the model must not sweep")

        model.prepareLibrary(alsoKeeping: [])
        #expect(swept == [["bookmark.png", "scheme.png"]])

        model.chip = .steam
        model.refresh()
        #expect(swept.count == 1, "a refresh must not sweep again, and never against the filtered view")
    }

    @Test("The sweep keeps a cover only the undo history still points at")
    func prepareLibraryKeepsCoversUndoCanBringBack() {
        var swept: [Set<String>] = []
        var source = inputs([bookmark("Saved")])
        source.savedCoverFileNames = { ["bookmark.png"] }
        source.removeOrphanCovers = { swept.append($0) }
        let model = SavedLibraryModel(inputs: source)

        model.prepareLibrary(alsoKeeping: ["removed.png"])

        #expect(swept == [["bookmark.png", "removed.png"]])
    }

    @Test("Preparing the library asks for one Apple Aerials scan; a refresh asks for none")
    func preparingTheLibraryAsksForOneAerialsScan() {
        var scans = 0
        var source = inputs()
        source.scanAerials = { scans += 1 }
        let model = SavedLibraryModel(inputs: source)

        model.prepareLibrary(alsoKeeping: [])
        #expect(scans == 1)

        model.refresh()
        #expect(scans == 1, "a refresh asked for another scan")
    }

    @Test("Tracking the shared stores does not keep the model alive")
    func observationDoesNotRetainTheModel() {
        weak var leaked: SavedLibraryModel?
        do {
            let model = SavedLibraryModel(inputs: inputs([bookmark("Saved")]))
            model.observeStores()
            leaked = model
        }
        // The observation registrar of an app-wide singleton outlives every window, so a strong
        // capture here keeps the whole library — thumbnails included — alive after teardown.
        #expect(leaked == nil)
    }
}
