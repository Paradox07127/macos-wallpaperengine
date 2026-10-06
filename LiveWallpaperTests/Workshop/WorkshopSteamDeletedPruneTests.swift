#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Workshop items Steam deleted — pruned with their saved records after each SteamCMD run", .timeLimit(.minutes(1)))
@MainActor
struct WorkshopSteamDeletedPruneTests {
    @Test("Pruning drops an item Steam deleted with its bookmarks, variants and marks, and records no tombstone")
    func prunedItemTakesItsSavedRecords() async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        let (gone, kept) = (library.ids[0], library.ids[1])
        let goneOrigin = try #require(library.entry(gone)).origin
        let keptOrigin = try #require(library.entry(kept)).origin
        let favorite = library.bookmarks.add(label: "Favorite", content: .video(bookmarkData: Data([1])), wpeOrigin: goneOrigin)
        let variant = library.bookmarks.add(label: "Variant", content: .video(bookmarkData: Data([2])), wpeOrigin: goneOrigin)
        let other = library.bookmarks.add(label: "Other", content: .video(bookmarkData: Data([3])), wpeOrigin: keptOrigin)
        for mark in ["workshop:\(gone)", "bookmark:\(favorite.id)", "bookmark:\(variant.id)", "workshop:\(kept)", "bookmark:\(other.id)"] {
            library.marks.add(mark)
        }

        try library.steamDeletes(0, listing: [kept])
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == [kept])
        #expect(library.bookmarks.bookmarks.map(\.id) == [other.id], "the deleted item's bookmark or saved variant stayed")
        #expect(library.marks.ids == ["workshop:\(kept)", "bookmark:\(other.id)"])
        #expect(library.manager.loadGlobalSettings().deletedWorkshopIDs.isEmpty)
    }

    @Test("Pruning keeps every present folder, whether or not the acf lists it yet")
    func pruneKeepsPresentFolders() async throws {
        let library = try PruneLibrary(itemCount: 3)
        defer { await library.discard() }
        await library.ingest()

        try library.steamDeletes(0, listing: [library.ids[1]])
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == [library.ids[1], library.ids[2]])
    }

    @Test("Pruning removes nothing after the Steam library is renamed away and rebuilt empty at its old path")
    func rebuiltLibraryPrunesNothing() async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        let before = try #require(library.coordinator.steamPruneBaseline)
        #expect(Set(before.listedIDs) == Set(library.ids))

        try library.rebuildLibrary()
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == Set(library.ids), "a prune against a rebuilt library removed entries")
        let after = try #require(library.coordinator.steamPruneBaseline)
        #expect(after.libraryIdentity != before.libraryIdentity, "the baseline still names the renamed library")
        #expect(after.listedIDs.isEmpty)
    }

    @Test("Without an acf baseline a prune removes nothing, and neither does the next; with one listing the item it goes", arguments: [false, true])
    func pruneNeedsBaselineListingTheItem(hasBaseline: Bool) async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        if !hasBaseline {
            library.steamSuite.defaults.removeObject(forKey: WorkshopFolderImportCoordinator.pruneBaselineKey)
        }
        try library.steamDeletes(0, listing: [library.ids[1]])

        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)
        let afterFirst = library.importedIDs
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        if hasBaseline {
            #expect(afterFirst == [library.ids[1]])
        } else {
            #expect(afterFirst == Set(library.ids), "the first prune, with no baseline, removed an entry")
            #expect(library.importedIDs == Set(library.ids), "the second prune removed an id its baseline never listed")
            #expect(library.coordinator.steamPruneBaseline?.listedIDs == [library.ids[1]], "the first prune recorded no baseline")
        }
    }

    @Test("The download scan records a baseline with no stale entry, so the next prune drops an item Steam deleted")
    func scanRecordsBaselineWithoutCandidates() async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.coordinator.ingestExistingDownloads(using: library.doctor)
        #expect(library.coordinator.steamPruneBaseline?.listedIDs == library.ids.sorted(), "a scan with no stale entry recorded no baseline")

        try library.steamDeletes(0, listing: [library.ids[1]])
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == [library.ids[1]])
    }

    @Test("A mutation that starts and ends while the prune surveys voids that prune")
    func mutationDuringSurveyVoidsPrune() async throws {
        let hold = SurveyHold()
        let library = try PruneLibrary(itemCount: 2, holdingSurveysWith: hold)
        defer { await library.discard() }
        await library.ingest()
        let gone = library.ids[0]
        let favorite = try library.bookmarks.add(
            label: "Favorite", content: .video(bookmarkData: Data([1])), wpeOrigin: #require(library.entry(gone)).origin
        )
        try library.steamDeletes(0, listing: [library.ids[1]])
        hold.isArmed = true
        let prune = Task { [coordinator = library.coordinator, doctor = library.doctor] in
            await coordinator.pruneSteamDeletedImports(using: doctor)
        }
        #expect(await waitUntil { hold.isParked })

        let (folder, steamRoot, ids) = (library.itemFolders[0], library.steamRoot, library.ids)
        try await library.repository.withExclusiveMutation(workshopID: gone) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeAppWorkshopACF(appWorkshopACF(installed: ids), steamRoot: steamRoot)
        }
        hold.release()
        await prune.value

        #expect(library.importedIDs == Set(library.ids), "a prune surveyed before a redownload removed the redownloaded item")
        #expect(library.bookmarks.bookmarks.map(\.id) == [favorite.id])
    }

    @Test("A folder restored outside any mutation while the prune surveys keeps its item")
    func folderRestoredDuringSurveyIsKept() async throws {
        let hold = SurveyHold()
        let library = try PruneLibrary(itemCount: 2, holdingSurveysWith: hold)
        defer { await library.discard() }
        await library.ingest()
        let gone = library.ids[0]
        let favorite = try library.bookmarks.add(
            label: "Favorite", content: .video(bookmarkData: Data([1])), wpeOrigin: #require(library.entry(gone)).origin
        )
        try library.steamDeletes(0, listing: [library.ids[1]])
        hold.isArmed = true
        let prune = Task { [coordinator = library.coordinator, doctor = library.doctor] in
            await coordinator.pruneSteamDeletedImports(using: doctor)
        }
        #expect(await waitUntil { hold.isParked })

        try FileManager.default.createDirectory(at: library.itemFolders[0], withIntermediateDirectories: true)
        hold.release()
        await prune.value

        #expect(library.importedIDs == Set(library.ids), "a prune surveyed before the folder came back removed its item")
        #expect(library.bookmarks.bookmarks.map(\.id) == [favorite.id])
    }

    @Test("A removal that fails keeps its id in the baseline, so the next prune retries it")
    func failedRemovalIsRetried() async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        let removes = library.coordinator.removeVanishedImport
        try library.steamDeletes(0, listing: [library.ids[1]])

        library.coordinator.removeVanishedImport = { _ in false }
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)
        #expect(library.importedIDs == Set(library.ids))
        library.coordinator.removeVanishedImport = removes
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == [library.ids[1]], "the failed removal dropped out of the baseline and was never retried")
    }

    @Test("The survey takes an entry as Steam-deleted only when its bookmark reports the folder gone", arguments: [
        "gone", "denied", "found but unreachable",
    ])
    func surveyNeedsConfirmedMissingSource(resolution: String) async throws {
        let library = try PruneLibrary(itemCount: 1)
        defer { await library.discard() }
        await library.ingest()
        let entry = try #require(library.entry(library.ids[0]))
        let baseline = library.coordinator.steamPruneBaseline
        try library.steamDeletes(0, listing: [])
        // The folder is gone from here, so a resolve answering with it stands for one the sandbox won't let the app stat.
        let unreachable = library.itemFolders[0]
        let resolve: @Sendable (Data) throws -> (URL, Bool) = { _ in
            switch resolution {
            case "gone": throw CocoaError(.fileNoSuchFile)
            case "denied": throw CocoaError(.fileReadNoPermission)
            default: return (unreachable, false)
            }
        }

        let survey = WorkshopFolderImportCoordinator.entriesSteamDeleted(
            [entry], steamRoot: library.steamRoot, baseline: baseline,
            identity: WorkshopFolderImportCoordinator.libraryIdentity(of: library.steamRoot),
            resolver: SecurityScopedBookmarkResolver(resolveData: resolve, refreshData: { _ in Data() })
        )

        let expected = resolution == "gone" ? [entry.origin.workshopID] : []
        #expect(survey?.deleted.map(\.origin.workshopID) == expected, "a source the bookmark could not confirm gone was taken as deleted")
    }

    @Test("A prune that starts while another surveys does not run")
    func overlappingPruneDoesNotRun() async throws {
        let hold = SurveyHold()
        let library = try PruneLibrary(itemCount: 2, holdingSurveysWith: hold)
        defer { await library.discard() }
        await library.ingest()
        try library.steamDeletes(0, listing: [library.ids[1]])
        hold.isArmed = true
        let first = Task { [coordinator = library.coordinator, doctor = library.doctor] in
            await coordinator.pruneSteamDeletedImports(using: doctor)
        }
        #expect(await waitUntil { hold.isParked })

        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)
        #expect(hold.surveys == 1, "a second prune surveyed while the first was in flight")
        hold.release()
        await first.value

        #expect(library.importedIDs == [library.ids[1]])
    }

    @Test("A held mutation gate skips the whole prune; the next prune after it frees drops the item", arguments: [0, 1])
    func heldGateSkipsPrune(heldIndex: Int) async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        let gone = library.ids[0]
        let favorite = try library.bookmarks.add(
            label: "Favorite", content: .video(bookmarkData: Data([1])), wpeOrigin: #require(library.entry(gone)).origin
        )
        library.marks.add("workshop:\(gone)")
        library.marks.add("bookmark:\(favorite.id)")
        try library.steamDeletes(0, listing: [library.ids[1]])
        let hold = GateHold()
        let held = library.ids[heldIndex]
        let mutation = Task { [repository = library.repository] in
            try await repository.withExclusiveMutation(workshopID: held) { await hold.park() }
        }
        #expect(await waitUntil { library.repository.isMutating(workshopID: held) })

        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == Set(library.ids), "a prune during a mutation removed an entry")
        #expect(library.bookmarks.bookmarks.map(\.id) == [favorite.id])
        #expect(library.marks.ids == ["workshop:\(gone)", "bookmark:\(favorite.id)"])
        #expect(library.coordinator.steamPruneBaseline?.listedIDs.contains(gone) == true, "the skipped prune advanced the baseline")

        hold.release()
        try await mutation.value
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)
        #expect(library.importedIDs == [library.ids[1]])
    }

    @Test("Pruning keeps an item the user moved out of the Steam library before Steam dropped it")
    func pruneKeepsMovedFolder() async throws {
        let library = try PruneLibrary(itemCount: 1)
        defer { await library.discard() }
        await library.ingest()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("SteamDeletedPrune-Moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.moveItem(at: library.itemFolders[0], to: outside.appendingPathComponent(library.ids[0], isDirectory: true))
        try writeAppWorkshopACF(appWorkshopACF(installed: []), steamRoot: library.steamRoot)
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == [library.ids[0]])
    }

    @Test("Pruning removes nothing while the content root can't be listed or searched", arguments: [0o000, 0o444])
    func unreadableContentRootPrunesNothing(permissions: Int) async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        try writeAppWorkshopACF(appWorkshopACF(installed: []), steamRoot: library.steamRoot)
        let contentRoot = SteamLibraryPaths.workshopContentRoot(steamRoot: library.steamRoot).path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: contentRoot)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contentRoot) }

        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        #expect(library.importedIDs == Set(library.ids))
    }

    @Test("Pruning a Steam item keeps the saved records a local copy of the same Workshop id still uses")
    func pruneKeepsLocalCopyRecords() async throws {
        let library = try PruneLibrary(itemCount: 1)
        defer { await library.discard() }
        await library.ingest()
        let id = library.ids[0]
        let localFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SteamDeletedPrune-Local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localFolder) }
        let manifest = #"{"workshopid":"\#(id)","title":"Local","type":"video","file":"video.mp4"}"#
        try Data(manifest.utf8).write(to: localFolder.appendingPathComponent("project.json"))
        try Data([0x00]).write(to: localFolder.appendingPathComponent("video.mp4"))
        guard case let .ready(_, localOrigin) = try await library.importService.importProject(folder: localFolder) else {
            Issue.record("the local copy did not import")
            return
        }
        // An earlier importedAt keeps the two entries' delete identities apart.
        library.manager.recordWPEImport(WPEHistoryEntry(origin: localOrigin, importedAt: Date(timeIntervalSinceNow: -60), lastUsedAt: nil))
        let local = library.bookmarks.add(label: "Local", content: .video(bookmarkData: Data([1])), wpeOrigin: localOrigin)
        library.marks.add("workshop:\(id)")
        library.marks.add("bookmark:\(local.id)")

        try library.steamDeletes(0, listing: [])
        await library.coordinator.pruneSteamDeletedImports(using: library.doctor)

        let history = library.manager.loadGlobalSettings().recentWPEImports
        #expect(history.count == 1)
        #expect(history.first?.origin.steamFolderItemID == nil)
        #expect(library.bookmarks.bookmarks.map(\.id) == [local.id], "the local copy's bookmark went with the Steam item")
        #expect(library.marks.ids == ["workshop:\(id)", "bookmark:\(local.id)"])
    }

    @Test("A download SteamCMD finishes prunes once and keeps the item it just downloaded")
    func successfulRunPrunesOnce() async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        try library.steamDeletes(0, listing: [library.ids[1]])
        let runs = RunCount()
        let downloads = library.downloads(counting: runs)
        let itemID = try #require(UInt64(library.ids[1]))

        downloads.download(itemID: itemID, title: "Kept", using: ScriptedDownloader(folder: library.itemFolders[1]))

        #expect(await waitUntil { downloads.phase(for: itemID) == .succeeded })
        #expect(runs.value == 1)
        #expect(library.importedIDs == [library.ids[1]])
    }

    @Test("A download SteamCMD fails still prunes once")
    func failedRunPrunesOnce() async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        try library.steamDeletes(0, listing: [library.ids[1]])
        let runs = RunCount()
        let downloads = library.downloads(counting: runs)
        let itemID = try #require(UInt64(library.ids[1]))

        downloads.download(itemID: itemID, title: "Kept", using: ScriptedDownloader())

        #expect(await waitUntil { downloads.phase(for: itemID) == .failed("scripted failure") })
        #expect(runs.value == 1)
        #expect(library.importedIDs == [library.ids[1]])
    }

    @Test("A cancelled download prunes once when SteamCMD returns; the retry the mutation gate refused does not")
    func cancelledRunPrunesOnce() async throws {
        let library = try PruneLibrary(itemCount: 2)
        defer { await library.discard() }
        await library.ingest()
        let runs = RunCount()
        let downloads = library.downloads(counting: runs)
        let itemID = try #require(UInt64(library.ids[1]))
        let cancelled = ScriptedDownloader(parks: true)
        downloads.download(itemID: itemID, title: "Kept", using: cancelled)
        #expect(await waitUntil { cancelled.isParked })

        downloads.cancel(itemID)
        downloads.download(itemID: itemID, title: "Kept", using: ScriptedDownloader())
        #expect(await waitUntil {
            if case .failed = downloads.phase(for: itemID) {
                true
            } else {
                false
            }
        })
        #expect(runs.value == 0, "a retry that never ran SteamCMD pruned")
        try library.steamDeletes(0, listing: [library.ids[1]])
        cancelled.release()

        #expect(await waitUntil { runs.value > 0 })
        #expect(library.importedIDs == [library.ids[1]], "the cancelled run's prune skipped the item Steam deleted")
        try await Task.sleep(for: .milliseconds(100))
        #expect(runs.value == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class RunCount {
    var value = 0
}

/// Holds a mutation gate open from `park()` until `release()`.
@MainActor
private final class GateHold {
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// While armed, counts each survey and parks the first after it is computed, until `release()`.
@MainActor
private final class SurveyHold {
    var isArmed = false
    private(set) var surveys = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var isParked: Bool {
        continuation != nil
    }

    func pass() async {
        guard isArmed else { return }
        surveys += 1
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isArmed = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MemoryBookmarks: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}

/// Returns the project in `folder` as SteamCMD's download, or fails without one; `parks` holds it until `release()`.
@MainActor
private final class ScriptedDownloader: WorkshopItemDownloading {
    private let folder: URL?
    private let parks: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(folder: URL? = nil, parks: Bool = false) {
        self.folder = folder
        self.parks = parks
    }

    var isParked: Bool {
        gate != nil
    }

    func downloadWorkshopItem<Imported: Sendable>(
        _: UInt64,
        onProgress _: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        if parks {
            await withCheckedContinuation { gate = $0 }
        }
        guard let folder else { return .failed(reason: "scripted failure") }
        return await .imported(onContentReady(folder))
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

/// A scratch Steam library of downloaded video items, a doctor bound to it, and a coordinator whose
/// Steam-deleted removal is the production one over injected stores.
@MainActor
private struct PruneLibrary {
    let root: URL
    /// Inside `root`, apart from the settings, so the library can be renamed away on its own.
    let steamRoot: URL
    let itemFolders: [URL]
    let steamSuite: TestScratch.DefaultsSuite
    let librarySuite: TestScratch.DefaultsSuite
    let doctor: SteamCMDDoctorService
    let manager: SettingsManager
    let importService = WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() })
    let bookmarks = BookmarkStore(persistence: MemoryBookmarks())
    let marks: LibraryBookmarkStore
    let repository = WorkshopRepositoryCoordinator()
    let coordinator: WorkshopFolderImportCoordinator

    init(itemCount: Int, holdingSurveysWith hold: SurveyHold? = nil, function: String = #function) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SteamDeletedPrune-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        self.steamRoot = steamRoot
        let firstID = UInt64.random(in: 9_000_000_000 ... 9_899_999_999)
        itemFolders = (0 ..< UInt64(itemCount)).map {
            SteamLibraryPaths.workshopContentRoot(steamRoot: steamRoot).appendingPathComponent(String(firstID + $0), isDirectory: true)
        }
        for folder in itemFolders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = #"{"workshopid":"\#(folder.lastPathComponent)","title":"Item","type":"video","file":"video.mp4"}"#
            try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data([0x00]).write(to: folder.appendingPathComponent("video.mp4"))
        }
        try writeAppWorkshopACF(appWorkshopACF(installed: itemFolders.map(\.lastPathComponent)), steamRoot: steamRoot)
        steamSuite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.SteamDeletedPrune.Steam", function: function)
        librarySuite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.SteamDeletedPrune.Library", function: function)
        doctor = SteamCMDDoctorService(defaults: steamSuite.defaults)
        doctor.workdirBookmarkData = try steamRoot.bookmarkData()
        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: librarySuite.defaults
        )
        self.manager = manager
        marks = LibraryBookmarkStore(defaults: librarySuite.defaults)
        let survey: WorkshopFolderImportCoordinator.SteamDeletedSurveying? = if let hold {
            { @Sendable entries, steamRoot, baseline, identity in
                let survey = WorkshopFolderImportCoordinator.entriesSteamDeleted(
                    entries, steamRoot: steamRoot, baseline: baseline, identity: identity
                )
                await hold.pass()
                return survey
            }
        } else {
            nil
        }
        coordinator = WorkshopFolderImportCoordinator(
            importService: importService,
            settings: manager,
            toastCenter: WorkshopToastCenter(),
            repositoryCoordinator: repository,
            defaults: steamSuite.defaults,
            removeVanishedImport: WorkshopSavedRecords.removingImport(
                bookmarks: bookmarks, libraryBookmarks: marks, history: { manager.loadGlobalSettings().recentWPEImports },
                { manager.removeWPEImport(workshopID: $0.origin.workshopID, matchingImportedAt: $0.importedAt, recordingDeleteTombstone: false) }
            ),
            surveySteamDeleted: survey
        )
    }

    var ids: [String] {
        itemFolders.map(\.lastPathComponent)
    }

    var importedIDs: Set<String> {
        Set(manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID))
    }

    func entry(_ id: String) -> WPEHistoryEntry? {
        manager.loadGlobalSettings().recentWPEImports.first { $0.origin.workshopID == id }
    }

    /// Imports the downloads, then prunes once as a SteamCMD run would, so the next prune has an acf baseline.
    func ingest() async {
        await coordinator.ingestExistingDownloads(using: doctor)
        await coordinator.pruneSteamDeletedImports(using: doctor)
    }

    /// Steam removes item `index`'s folder and rewrites its acf to list only `listing`.
    func steamDeletes(_ index: Int, listing: [String]) throws {
        try FileManager.default.removeItem(at: itemFolders[index])
        try writeAppWorkshopACF(appWorkshopACF(installed: listing), steamRoot: steamRoot)
    }

    /// Renames the library away, empties the renamed copy so no old bookmark resolves, and binds a new empty library at the old path.
    func rebuildLibrary() throws {
        let renamed = root.appendingPathComponent("Steam.bak", isDirectory: true)
        try FileManager.default.moveItem(at: steamRoot, to: renamed)
        try FileManager.default.removeItem(at: SteamLibraryPaths.workshopContentRoot(steamRoot: renamed))
        try FileManager.default.createDirectory(at: SteamLibraryPaths.workshopContentRoot(steamRoot: steamRoot), withIntermediateDirectories: true)
        try writeAppWorkshopACF(appWorkshopACF(installed: []), steamRoot: steamRoot)
        doctor.workdirBookmarkData = try steamRoot.bookmarkData()
    }

    /// Each SteamCMD run prunes through this library's coordinator, then counts.
    func downloads(counting runs: RunCount) -> WorkshopDownloadCoordinator {
        WorkshopDownloadCoordinator(
            importService: importService,
            repositoryCoordinator: repository,
            settings: manager,
            toasts: WorkshopToastCenter(),
            cancelSteamCMD: { _ in },
            afterSteamCMDRun: { [coordinator, doctor] in
                await coordinator.pruneSteamDeletedImports(using: doctor)
                runs.value += 1
            }
        )
    }

    func discard() async {
        steamSuite.discard()
        librarySuite.discard()
        await TestScratch.discard(root, flushing: manager)
    }
}
#endif
