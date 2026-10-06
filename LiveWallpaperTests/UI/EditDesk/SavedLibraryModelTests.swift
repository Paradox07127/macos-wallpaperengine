import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import os
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

    private var hd: LibraryMetadata {
        .video(.init(
            resolution: CGSize(width: 1920, height: 1080), isHDR: false,
            duration: 60, fileSize: 100, probedAt: .distantPast
        ))
    }

    private func inputs(_ bookmarks: [WallpaperBookmark] = [], aerials: [AerialAsset] = []) -> SavedLibraryModel.Inputs {
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { bookmarks }
        inputs.aerials = { .init(assets: aerials, isAuthorized: true, lastScanError: nil, isScanning: false) }
        return inputs
    }

    @Test("Observation follows visible rows and refresh publishes the new rows")
    func visibleItemsRemainObservable() {
        @MainActor final class Changes { var count = 0 }
        let saved = OSAllocatedUnfairLock(initialState: [bookmark("Alpha"), bookmark("Beta")])
        var input = SavedLibraryModel.Inputs()
        input.bookmarks = { saved.withLock { $0 } }
        let model = SavedLibraryModel(inputs: input)
        model.sort = .name
        _ = model.visibleItems
        let changes = Changes()
        withObservationTracking {
            _ = model.visibleItems
        } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }
        model.query = "Beta"
        #expect(changes.count == 1)
        #expect(model.visibleItems.map(\.title) == ["Beta"])
        let renamed = [bookmark("Beta new")]
        saved.withLock { $0 = renamed }
        model.refresh()
        #expect(model.visibleItems.map(\.title) == ["Beta new"])
        model.chip = .bookmarks
        #expect(model.visibleItems.isEmpty)
    }

    @Test("Live usage refresh invalidates the snapshot while a browsing order stays frozen")
    func usageRefreshAndBrowseFreeze() {
        var saved = [bookmark("First", used: 2), bookmark("Second", used: 1)]
        var input = SavedLibraryModel.Inputs()
        input.bookmarks = { saved }
        let model = SavedLibraryModel(inputs: input)
        #expect(model.visibleItems.map(\.title) == ["First", "Second"])
        saved[1].lastUsedAt = Date(timeIntervalSince1970: 3)
        model.refresh()
        #expect(model.visibleItems.map(\.title) == ["Second", "First"])
        model.beginBrowsing()
        saved[0].lastUsedAt = Date(timeIntervalSince1970: 4)
        model.refresh()
        #expect(model.visibleItems.map(\.title) == ["Second", "First"])
        model.endBrowsing()
        #expect(model.visibleItems.map(\.title) == ["First", "Second"])
    }

    @Test("Size ordering uses known file bytes largest-first and never treats unknown as zero")
    func knownFileSizeSort() {
        var input = inputs([bookmark("A small"), bookmark("Z large"), bookmark("Zero"), bookmark("Unknown"), bookmark("Negative")])
        input.metadata = { bookmark in
            let size: Int64? = switch bookmark.label {
            case "A small": 20
            case "Z large": Int64.max
            case "Zero": 0
            case "Negative": -1
            default: nil
            }
            return .video(.init(resolution: nil, isHDR: false, duration: nil, fileSize: size, probedAt: .distantPast))
        }
        let model = SavedLibraryModel(inputs: input)
        model.sort = .size
        #expect(model.visibleItems.map(\.title) == ["Z large", "A small", "Zero", "Negative", "Unknown"])
        model.sort = .name
        #expect(model.visibleItems.first?.title == "A small")
    }

    @Test("Leaving Size or ending browsing stops subsequent probes and rejects the cancelled result")
    func sizeProbeCancellationDoesNotUpdateRows() async {
        @MainActor final class Probe {
            var labels: [String] = []
            var continuation: CheckedContinuation<LibraryMetadata?, Never>?

            func read(_ bookmark: WallpaperBookmark) async -> LibraryMetadata? {
                labels.append(bookmark.label)
                return await withCheckedContinuation { continuation = $0 }
            }

            func finish() {
                continuation?.resume(returning: .video(.init(resolution: nil, isHDR: false, duration: nil, fileSize: 500, probedAt: .distantPast)))
                continuation = nil
            }
        }
        let probe = Probe()
        var input = inputs([bookmark("First"), bookmark("Second")])
        input.probeMetadata = { await probe.read($0) }
        let model = SavedLibraryModel(inputs: input)
        model.beginBrowsing()
        model.sort = .size
        let firstDeadline = ContinuousClock.now + .seconds(3)
        while probe.labels.isEmpty, ContinuousClock.now < firstDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(probe.labels == ["First"])
        model.sort = .name
        probe.finish()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(probe.labels == ["First"])
        #expect(model.items.allSatisfy { $0.metadata == nil })
        model.sort = .size
        let secondDeadline = ContinuousClock.now + .seconds(3)
        while probe.labels.count < 2, ContinuousClock.now < secondDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(probe.labels == ["First", "First"])
        model.endBrowsing()
        probe.finish()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(probe.labels.count == 2)
        #expect(model.items.allSatisfy { $0.metadata == nil })
        model.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(probe.labels.count == 2, "refreshing a hidden library restarted file probes")
    }

    @Test("A late size result cannot update a replaced source with the same row ID")
    func sizeProbeSourceIdentity() async {
        @MainActor final class Probe {
            var contents: [WallpaperContent] = []
            var parked: [CheckedContinuation<LibraryMetadata?, Never>] = []

            func read(_ bookmark: WallpaperBookmark) async -> LibraryMetadata? {
                contents.append(bookmark.content)
                return await withCheckedContinuation { parked.append($0) }
            }

            func finish(_ index: Int, bytes: Int64) {
                parked.remove(at: index).resume(returning: .video(.init(resolution: nil, isHDR: false, duration: nil, fileSize: bytes, probedAt: .distantPast)))
            }
        }
        let probe = Probe()
        var saved = bookmark("Same row")
        var input = inputs()
        input.bookmarks = { [saved] }
        input.probeMetadata = { await probe.read($0) }
        let model = SavedLibraryModel(inputs: input)
        model.beginBrowsing()
        model.sort = .size
        await settle { probe.parked.count == 1 }
        #expect(probe.parked.count == 1)
        saved.content = .video(bookmarkData: Data("replacement".utf8))
        model.refresh()
        await settle { probe.parked.count == 2 }
        #expect(probe.parked.count == 2)
        probe.finish(0, bytes: 111)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.items.first?.metadata == nil)
        probe.finish(0, bytes: 222)
        await settle { model.items.first?.metadata != nil }
        guard case let .video(metadata)? = model.items.first?.metadata else {
            Issue.record("the current source's probe did not publish")
            return
        }
        #expect(metadata.fileSize == 222)
        #expect(probe.contents == [.video(bookmarkData: Data("Same row".utf8)), saved.content])
        model.endBrowsing()
    }

    @Test("Store refresh after browsing ends does not restart unresolved size probes")
    func hiddenSizeSortDoesNotProbeOnRefresh() async {
        var probes = 0
        var input = inputs([bookmark("Unknown file")])
        input.probeMetadata = { _ in
            probes += 1
            return nil
        }
        let model = SavedLibraryModel(inputs: input)
        model.sort = .size
        await Task.yield()
        #expect(probes == 0)
        model.beginBrowsing()
        await settle { probes == 1 }
        #expect(probes == 1)
        model.endBrowsing()
        model.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(probes == 1)
        model.beginBrowsing()
        await settle { probes == 2 }
        #expect(probes == 2)
        model.endBrowsing()
    }

    #if !LITE_BUILD
    @Test("A video Workshop row without authorized content does not block the next size probe")
    func sizeProbeSkipsUnavailableWorkshopContent() async {
        let unavailable = WPEHistoryEntry(origin: origin("123", type: .video), importedAt: .distantPast)
        var labels: [String] = []
        var input = inputs([bookmark("Valid file")])
        input.history = { [unavailable] }
        input.workshopContent = { _ in nil }
        input.probeMetadata = {
            labels.append($0.label)
            return .video(.init(resolution: nil, isHDR: false, duration: nil, fileSize: 25, probedAt: .distantPast))
        }
        let model = SavedLibraryModel(inputs: input)
        #expect(model.items.first?.id == "workshop:123")
        model.sort = .size
        #expect(labels.isEmpty)
        model.beginBrowsing()
        await settle { labels.count == 1 }
        #expect(labels == ["Valid file"])
        #expect(model.visibleItems.first?.title == "Valid file")
        model.endBrowsing()
    }
    #endif

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

    @Test("The filter chips are All, Bookmarks, Recent, Steam, Local and Aerials")
    func chipsAreTheSixFilters() {
        #expect(SavedLibraryModel.Chip.allCases == [.all, .bookmarks, .recent, .steam, .local, .aerials])
    }

    @Test("Bookmarks keeps only the marked rows, and follows a mark added or taken off")
    func bookmarksChipKeepsOnlyMarkedRows() {
        let marked = bookmark("Marked")
        let plain = bookmark("Plain")
        let marks = OSAllocatedUnfairLock<Set<LibraryItem.ID>>(initialState: ["bookmark:\(marked.id)", "aerial:/sky.mov", "bookmark:gone"])
        var source = inputs([marked, plain], aerials: [aerial()])
        source.libraryBookmarks = { marks.withLock { $0 } }
        let model = SavedLibraryModel(inputs: source)
        model.chip = .bookmarks
        #expect(Set(model.visibleItems.map(\.id)) == ["bookmark:\(marked.id)", "aerial:/sky.mov"])

        marks.withLock { $0 = ["bookmark:\(plain.id)"] }
        model.refresh()
        #expect(model.visibleItems.map(\.title) == ["Plain"])
        model.chip = .all
        #expect(model.visibleItems.count == 3, "control: the other rows left the library, not just the chip")
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

    #if !LITE_BUILD
    @Test("A search finds a row by its translated name")
    func searchFindsTranslatedName() {
        let title = "夕阳下的海边小镇"
        WPEPropertyLabelTranslator.wallpaperNames.store([(title, "Seaside town at sunset")])
        let model = SavedLibraryModel(inputs: inputs([bookmark(title), bookmark("Alpha")]))
        model.query = "seaside"
        #expect(model.visibleItems.map(\.title) == [title], "the row is not found by its translated name")
    }
    #endif

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

    @Test("Cancelled manual metadata probes never publish or start a subsequent item", arguments: [false, true])
    func cancelledManualMetadataProbe(cancelledBeforeStart: Bool) async throws {
        @MainActor final class Probe {
            var labels: [String] = []
            var continuation: CheckedContinuation<LibraryMetadata?, Never>?
            let result: LibraryMetadata
            init(result: LibraryMetadata) {
                self.result = result
            }

            func read(_ bookmark: WallpaperBookmark) async -> LibraryMetadata? {
                labels.append(bookmark.label)
                // A cancelled caller must not enter even a cooperative decoder.
                if Task.isCancelled || labels.count > 1 {
                    return result
                }
                return await withCheckedContinuation { continuation = $0 }
            }
        }
        let first = bookmark("First"), second = bookmark("Second")
        let probe = Probe(result: fourK)
        var source = inputs([first, second])
        source.probeMetadata = { await probe.read($0) }
        let model = SavedLibraryModel(inputs: source)
        let task = Task { await model.probeMetadata(for: ["bookmark:\(first.id)", "bookmark:\(second.id)"]) }
        if cancelledBeforeStart {
            task.cancel()
        } else {
            await settle { probe.continuation != nil }
            let parked = try #require(probe.continuation)
            task.cancel()
            parked.resume(returning: fourK)
            probe.continuation = nil
        }
        await task.value
        #expect(probe.labels == (cancelledBeforeStart ? [] : ["First"]))
        #expect(model.items.allSatisfy { $0.metadata == nil })
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

    @Test("A refresh keeps an unchanged row's metadata without reading it again")
    func refreshKeepsUnchangedMetadataWithoutReadingIt() {
        var reads = 0
        var source = inputs([bookmark("Saved")], aerials: [aerial()])
        source.metadata = { _ in
            reads += 1
            return fourK
        }
        #if !LITE_BUILD
        let entry = WPEHistoryEntry(origin: origin("123", type: .video), importedAt: .distantPast)
        var contentReads = 0
        source.history = { [entry] }
        source.workshopContent = { _ in
            contentReads += 1
            return .video(bookmarkData: Data("workshop film".utf8))
        }
        #endif
        let model = SavedLibraryModel(inputs: source)
        let first = reads
        model.refresh()
        #if !LITE_BUILD
        #expect(first == 3)
        #expect(contentReads == 1, "the refresh bookmarked the Workshop video anew to read it again")
        #else
        #expect(first == 2)
        #endif
        #expect(reads == first, "the refresh read every unchanged row's metadata again")
        #expect(model.items.allSatisfy { $0.metadata == fourK })
    }

    @Test("A row whose bookmark changed is read again")
    func changedBookmarkIsReadAgain() {
        let replaced = Data("replaced film".utf8)
        var saved = bookmark("Saved")
        var source = inputs(aerials: [aerial()])
        source.bookmarks = { [saved] }
        source.metadata = { $0.content.activeVideoBookmarkData == replaced ? hd : fourK }
        let model = SavedLibraryModel(inputs: source)
        saved.content = .video(bookmarkData: replaced)
        model.refresh()
        #expect(model.items.first { $0.id == "bookmark:\(saved.id)" }?.metadata == hd, "a row whose bookmark changed kept the old file's metadata")
        #expect(model.items.first { $0.kind == .aerial }?.metadata == fourK)
    }

    @Test("A tile probe's new answer replaces a kept one and survives the next refresh")
    func probedMetadataSurvivesTheNextRefresh() async {
        let saved = bookmark("Saved")
        let row = "bookmark:\(saved.id)"
        var record = fourK
        var source = inputs([saved])
        source.metadata = { _ in record }
        source.probeMetadata = { _ in
            record = hd
            return record
        }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.items.first { $0.id == row }?.metadata == fourK)
        await model.probeMetadata(for: [row])
        #expect(model.items.first { $0.id == row }?.metadata == hd, "the tile probe's answer did not reach the row")
        model.refresh()
        #expect(model.items.first { $0.id == row }?.metadata == hd, "the refresh put back the metadata the probe replaced")
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

    @Test("Aerial display matching keeps direct and resolved matches in display order, excluding unresolved videos")
    func aerialDisplayMatchingPreservesOrderAndRejectsMissingPaths() {
        let asset = aerial()
        let previous = Data("previous scan".utf8)
        let missing = Data("unresolved video".utf8)
        var source = inputs(aerials: [asset, aerial("other")])
        source.activeWallpapers = { [
            (42, .video(bookmarkData: previous)),
            (7, .video(bookmarkData: asset.bookmarkData)),
            (9, .video(bookmarkData: missing)),
            (12, .video(bookmarkData: previous)),
        ] }
        source.filePath = { $0 == previous ? "/sky.mov" : nil }
        let snapshot = SavedLibraryModel.catalogSnapshot(inputs: source)
        #expect(snapshot.items[0].onDisplays == [42, 7, 12])
        #expect(snapshot.items[1].onDisplays.isEmpty)
    }

    @Test("An unresolved match is reused until refresh, then the newly available file can match")
    func missingAerialPathIsCachedUntilRefresh() {
        let oldBookmark = Data("old scan".utf8)
        var source = inputs(aerials: [aerial(), aerial("other")])
        var resolves = 0
        var available = false
        source.filePath = { _ in
            resolves += 1
            return available ? "/sky.mov" : nil
        }
        let model = SavedLibraryModel(inputs: source)
        let content = WallpaperContent.video(bookmarkData: oldBookmark)
        #expect(!model.aerial(aerial(), matches: content))
        #expect(!model.aerial(aerial("other"), matches: content))
        #expect(resolves == 1)
        available = true
        #expect(!model.aerial(aerial(), matches: content))
        #expect(resolves == 1)
        model.refresh()
        #expect(model.aerial(aerial(), matches: content))
        #expect(resolves == 2)
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

    private func origin(_ id: String, type: WPEType = .scene, location: WPEResourceLocation? = nil) -> WPEOrigin {
        WPEOrigin(
            workshopID: id, title: "Installed \(id)", originalType: type,
            sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil, resourceLocation: location
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

    @Test("The marks carried over are the installed rows saved entries fold into, each once; a tuned variant is not one")
    func foldedBookmarksMarkTheirWorkshopRows() {
        func saved(_ workshopID: String, overrides: [String: WallpaperEngineProjectPropertyValue] = [:]) -> WallpaperBookmark {
            var entry = bookmark("Saved \(workshopID)")
            entry.wpeOrigin = origin(workshopID)
            entry.content = .scene(descriptor(overrides: overrides))
            return entry
        }
        var video = bookmark("Video")
        video.wpeOrigin = origin("9", type: .video)
        let bookmarks = [
            saved("2"), saved("1"), saved("2"), saved("3", overrides: ["speed": .number(2)]), saved("4"), video, bookmark("Plain"),
        ]

        let marks = SavedLibraryModel.foldedBookmarkMarks(bookmarks, installed: ["1", "2", "3", "9"])

        #expect(marks == ["workshop:2", "workshop:1", "workshop:9"], Comment(rawValue: "\(marks)"))
    }

    @Test("The carry-over runs once: a mark taken off afterwards stays off")
    func foldedBookmarkMigrationRunsOnce() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "SavedLibraryModelTests")
        defer { suite.discard() }
        let marks = LibraryBookmarkStore(defaults: suite.defaults)
        marks.add("bookmark:kept")
        var folded = bookmark("Folded")
        folded.wpeOrigin = origin("123")
        folded.content = .scene(descriptor())

        SavedLibraryModel.migrateFoldedBookmarks([folded], installed: ["123"], into: marks, defaults: suite.defaults)

        #expect(marks.ids == ["bookmark:kept", "workshop:123"])
        #expect(suite.defaults.bool(forKey: "loomscreen.library.bookmarks.migrated.v1"))
        marks.remove("workshop:123")
        SavedLibraryModel.migrateFoldedBookmarks([folded], installed: ["123"], into: marks, defaults: suite.defaults)
        #expect(marks.ids == ["bookmark:kept"], "the carry-over ran a second time")
    }

    @Test("The carry-over is not recorded as done when the marks archive cannot be read")
    func foldedBookmarkMigrationWaitsForAReadableArchive() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "SavedLibraryModelTests")
        defer { suite.discard() }
        suite.defaults.set(Data("not json".utf8), forKey: LibraryBookmarkStore.preferencesKey)
        let marks = LibraryBookmarkStore(defaults: suite.defaults)
        var folded = bookmark("Folded")
        folded.wpeOrigin = origin("123")
        folded.content = .scene(descriptor())

        SavedLibraryModel.migrateFoldedBookmarks([folded], installed: ["123"], into: marks, defaults: suite.defaults)

        #expect(!suite.defaults.bool(forKey: SavedLibraryModel.bookmarksMigratedKey), "a refused write was recorded as carried over")
    }

    @Test("A marked saved entry that folds into a newly installed project's row moves its mark to that row")
    func markFollowsAnEntryIntoItsWorkshopRow() {
        var saved = bookmark("Saved")
        saved.wpeOrigin = origin("123")
        saved.content = .scene(descriptor())
        let history = OSAllocatedUnfairLock<[WPEHistoryEntry]>(initialState: [])
        var marks: Set<LibraryItem.ID> = ["bookmark:\(saved.id)"]
        var remapped: [(LibraryItem.ID, LibraryItem.ID)] = []
        var source = inputs([saved])
        source.history = { history.withLock { $0 } }
        source.libraryBookmarks = { marks }
        source.remapLibraryBookmark = { old, new in
            remapped.append((old, new))
            marks.remove(old)
            marks.insert(new)
        }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.bookmarkedIDs == ["bookmark:\(saved.id)"])
        #expect(remapped.isEmpty)

        let installed = [WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast)]
        history.withLock { $0 = installed }
        model.refresh()

        #expect(model.bookmarkedIDs == ["workshop:123"])
        #expect(remapped.map(\.0) == ["bookmark:\(saved.id)"] && remapped.map(\.1) == ["workshop:123"], Comment(rawValue: "\(remapped)"))
        model.chip = .bookmarks
        #expect(model.visibleItems.map(\.id) == ["workshop:123"], "the entry's mark points at a row that is not listed")
    }

    @Test("A mark on a Workshop row not installed right now is kept as is")
    func markOnAnAbsentWorkshopRowIsKept() {
        var remapped: [(LibraryItem.ID, LibraryItem.ID)] = []
        var source = inputs()
        source.libraryBookmarks = { ["workshop:123"] }
        source.remapLibraryBookmark = { remapped.append(($0, $1)) }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.bookmarkedIDs == ["workshop:123"])
        #expect(remapped.isEmpty, Comment(rawValue: "\(remapped)"))
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

    @Test("Search tags refresh for the same ID's new grant or import revision", arguments: [false, true])
    func tagsFollowCurrentProjectSource(newGrant: Bool) async throws {
        let a = origin("123")
        let b = try #require(a.replacingSourceFolderBookmark(matching: Data(), with: Data("new grant".utf8)))
        let history = OSAllocatedUnfairLock(initialState: [WPEHistoryEntry(origin: a, importedAt: .distantPast)])
        let tags = OSAllocatedUnfairLock(initialState: ["Landscape"])
        var reads = 0
        var source = inputs()
        source.history = { history.withLock { $0 } }
        source.projectTags = { _ in
            reads += 1
            return tags.withLock { $0 }
        }
        let model = SavedLibraryModel(inputs: source)
        model.query = "landscape"
        await model.loadSearchTags()
        #expect(model.visibleItems.map(\.id) == ["workshop:123"])
        tags.withLock { $0 = ["Nebula"] }
        history.withLock { $0 = [WPEHistoryEntry(origin: newGrant ? b : a, importedAt: Date(timeIntervalSince1970: 1))] }
        model.refresh()
        await model.loadSearchTags()
        model.query = "nebula"
        #expect(model.visibleItems.map(\.id) == ["workshop:123"])
        model.query = "landscape"
        #expect(model.visibleItems.isEmpty)
        #expect(reads == 2)
        await model.loadSearchTags()
        #expect(reads == 2, "an unchanged current source should retain one completed tag result")
        history.withLock { $0[0].lastUsedAt = Date(timeIntervalSince1970: 2) }
        model.refresh()
        await model.loadSearchTags()
        #expect(reads == 2, "usage bookkeeping must not invalidate the source's completed tags")
    }

    @Test("An old source's delayed tags cannot override its replacement")
    func lateTagReadCannotReplaceCurrentSource() async throws {
        let a = origin("123")
        let b = try #require(a.replacingSourceFolderBookmark(matching: Data(), with: Data("replacement".utf8)))
        let history = OSAllocatedUnfairLock(initialState: [WPEHistoryEntry(origin: a, importedAt: .distantPast)])
        var parked: CheckedContinuation<[String], Never>?
        var source = inputs()
        source.history = { history.withLock { $0 } }
        source.projectTags = { origin in
            if origin.sourceFolderBookmark == b.sourceFolderBookmark {
                return ["Nebula"]
            }
            return await withCheckedContinuation { parked = $0 }
        }
        let model = SavedLibraryModel(inputs: source)
        model.query = "nebula"
        let old = Task { await model.loadSearchTags() }
        defer {
            old.cancel()
            parked?.resume(returning: [])
            parked = nil
        }
        await settle { parked != nil }
        let release = try #require(parked)
        history.withLock { $0 = [WPEHistoryEntry(origin: b, importedAt: .distantPast)] }
        model.refresh()
        await model.loadSearchTags()
        #expect(model.visibleItems.map(\.id) == ["workshop:123"])
        release.resume(returning: ["Landscape"])
        parked = nil
        await old.value
        #expect(model.visibleItems.map(\.id) == ["workshop:123"])
        model.query = "landscape"
        #expect(model.visibleItems.isEmpty)
    }

    @Test("Rows with the same Workshop ID search only their own source's tags")
    func sharedProjectIDDoesNotShareDifferentSourceTags() async throws {
        let a = origin("123")
        let b = try #require(a.replacingSourceFolderBookmark(matching: Data(), with: Data("variant source".utf8)))
        var variant = bookmark("Custom version")
        variant.wpeOrigin = b
        variant.content = .scene(descriptor(overrides: ["speed": .number(2)]))
        var source = inputs([variant])
        source.history = { [WPEHistoryEntry(origin: a, importedAt: .distantPast)] }
        source.projectTags = { $0.sourceFolderBookmark == b.sourceFolderBookmark ? ["Nebula"] : ["Landscape"] }
        let model = SavedLibraryModel(inputs: source)
        model.query = "landscape"
        await model.loadSearchTags()
        #expect(model.visibleItems.map(\.id) == ["workshop:123"])
        model.query = "nebula"
        #expect(model.visibleItems.map(\.id) == ["bookmark:\(variant.id)"])
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

    @Test("A search left open reads the tags of a project added meanwhile", .timeLimit(.minutes(1)))
    func openSearchReadsTheTagsOfNewRows() async {
        @MainActor final class History {
            var entries: [WPEHistoryEntry] = []
        }
        let history = History()
        history.entries = [WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast)]
        var reads = 0
        var source = inputs()
        source.history = { history.entries }
        source.projectTags = {
            reads += 1
            return $0.workshopID == "456" ? ["Nebula"] : []
        }
        let model = SavedLibraryModel(inputs: source)
        model.refresh()
        await settle { reads > 0 }
        #expect(reads == 0, "a refresh read project tags while the search was empty")
        model.query = "nebula"
        await model.loadSearchTags()
        #expect(model.visibleItems.isEmpty, "a project matched before any project had the tag")
        history.entries.append(WPEHistoryEntry(origin: origin("456"), importedAt: .distantPast))
        model.refresh()
        await settle { !model.visibleItems.isEmpty }
        #expect(model.visibleItems.map(\.id) == ["workshop:456"], "the tags of a project added while the search was open were never read")
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
        for kind: LibraryItem.Kind in [.video, .web, .scene, .aerial] {
            let typed = LibraryCardBadges(nowPlaying: on).accessibilityLabel(title: "Variant", kind: kind)
            #expect(typed == "Variant, \(kind.localizedName), \(playing)")
        }
    }

    @Test("Needs Update puts the projects with an update first, then sorts by name")
    func needsUpdateSortPutsUpdatedProjectsFirst() {
        var source = inputs([bookmark("Saved", used: 5)])
        source.history = {
            [
                WPEHistoryEntry(origin: origin("123"), importedAt: Date(timeIntervalSince1970: 2)),
                WPEHistoryEntry(origin: origin("456"), importedAt: Date(timeIntervalSince1970: 1)),
            ]
        }
        let model = SavedLibraryModel(inputs: source)
        model.updatedWorkshopIDs = ["456"]
        model.sort = .needsUpdate
        #expect(model.visibleItems.map(\.title) == ["Installed 456", "Installed 123", "Saved"])
    }

    @Test("The linked-folder filter keeps only installed projects outside the app's copy")
    func linkedFolderFilterKeepsLinkedProjects() {
        var source = inputs([bookmark("Saved")], aerials: [aerial()])
        source.history = {
            [
                WPEHistoryEntry(origin: origin("123", location: .cache), importedAt: .distantPast),
                WPEHistoryEntry(origin: origin("456", location: .sourceFolder), importedAt: .distantPast),
            ]
        }
        let model = SavedLibraryModel(inputs: source)
        model.filter = .storage(.linked)
        #expect(model.visibleItems.map(\.id) == ["workshop:456"])
    }

    @Test("The Unsupported filter keeps only the project types this Mac cannot run")
    func unsupportedFilterKeepsUnsupportedProjects() {
        let types: [WPEType] = [.video, .web, .scene, .application, .unknown]
        var source = inputs([bookmark("Saved")])
        source.history = { types.map { WPEHistoryEntry(origin: origin($0.rawValue, type: $0), importedAt: .distantPast) } }
        let model = SavedLibraryModel(inputs: source)
        model.filter = .unsupported
        #expect(Set(model.visibleItems.map(\.id)) == ["workshop:application", "workshop:unknown"])
    }

    @Test("A Workshop video row names the video it plays; a scene row names none")
    func workshopVideoOfARow() throws {
        let played = WallpaperContent.video(bookmarkData: Data([9]))
        let entries = [
            WPEHistoryEntry(origin: origin("video", type: .video), importedAt: .distantPast),
            WPEHistoryEntry(origin: origin("scene"), importedAt: .distantPast),
        ]
        var source = inputs()
        source.history = { entries }
        source.workshopContent = { $0.origin.originalType == .video ? played : nil }
        let model = SavedLibraryModel(inputs: source)
        let video = try #require(model.items.first { $0.id == "workshop:video" })
        let scene = try #require(model.items.first { $0.id == "workshop:scene" })
        #expect(model.workshopVideo(for: video) == played)
        #expect(model.workshopVideo(for: scene) == nil)
    }

    @Test("On disk the sweep keeps the Workshop cover of the current import and deletes the one an update left behind")
    func sweepDropsCoversOfOldImports() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-cover-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperCoverStore(directory: ConfigurationDirectory(root: root))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let frame = try #require(context.makeImage())
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let after = Date(timeIntervalSince1970: 1_727_000_000)
        let stale = try #require(store.storeWorkshopCover(frame, workshopID: "42", importedAt: before))
        let current = try #require(store.storeWorkshopCover(frame, workshopID: "42", importedAt: after))
        try #require(stale != current, "control: re-importing did not change the cover's name")
        let entry = WPEHistoryEntry(origin: origin("42"), importedAt: after)
        var source = inputs()
        source.savedCoverFileNames = { WallpaperCoverStore.keptFileNames(bookmarks: [], schemes: [], workshopImports: [entry]) }
        source.removeOrphanCovers = { store.removeOrphans(keeping: $0) }
        SavedLibraryModel(inputs: source).prepareLibrary(alsoKeeping: [])
        let covers = root.appendingPathComponent("Covers", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: covers.appendingPathComponent(current).path), "the sweep deleted the current import's cover")
        #expect(!FileManager.default.fileExists(atPath: covers.appendingPathComponent(stale).path), "the cover of the replaced import outlived the sweep")
    }

    @Test("A Workshop card draws the saved cover of the import it lists: each write decodes it again, and a re-import leaves the old cover unread")
    func workshopCardFollowsItsSavedCover() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-card-cover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperCoverStore(directory: ConfigurationDirectory(root: root))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let frame = try #require(context.makeImage())
        let imported = WPEHistoryEntry(origin: origin("42"), importedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let history = OSAllocatedUnfairLock(initialState: [imported])
        var source = inputs()
        source.history = { history.withLock { $0 } }
        source.workshopCoverRevision = { entry in
            WallpaperCoverStore.workshopFileName(workshopID: entry.origin.workshopID, importedAt: entry.importedAt)
                .flatMap { store.revision(of: $0) }
        }
        let model = SavedLibraryModel(inputs: source)
        var decodes: [String] = []
        var sources = ShelfThumbnailCache.Sources()
        sources.scene = { _, _ in decodes.append("author"); return frame }
        sources.coverThumbnail = { name, _ in decodes.append(name); return frame }
        let cache = ShelfThumbnailCache(sources: sources)
        func drawCard() async throws {
            let request = try #require(model.items.first { $0.id == "workshop:42" }?.thumbnail)
            _ = try #require(await cache.image(request, pixelSize: CGSize(width: 64, height: 36), scale: 2))
        }

        try await drawCard()
        #expect(decodes == ["author"], "control: with no cover saved the card draws the author's preview")
        let name = try #require(store.storeWorkshopCover(frame, workshopID: "42", importedAt: imported.importedAt))
        model.refresh()
        try await drawCard()
        #expect(decodes == ["author", name], Comment(rawValue: "after the cover was saved the card drew \(decodes)"))
        _ = try #require(store.storeWorkshopCover(frame, workshopID: "42", importedAt: imported.importedAt))
        model.refresh()
        try await drawCard()
        try await drawCard()
        #expect(decodes == ["author", name, name], Comment(rawValue: "a rewritten cover, drawn twice, decoded as \(decodes)"))

        let reimported = [WPEHistoryEntry(origin: origin("42"), importedAt: Date(timeIntervalSince1970: 1_727_000_000))]
        history.withLock { $0 = reimported }
        model.refresh()
        try await drawCard()
        #expect(decodes.last == "author", Comment(rawValue: "the re-imported project drew \(decodes)"))
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
