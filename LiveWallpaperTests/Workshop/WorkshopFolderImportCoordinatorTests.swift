#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import os
import Testing

@Suite("Workshop folder import — queued requests")
@MainActor
struct WorkshopFolderImportCoordinatorTests {
    /// A library whose one project.json does not parse: the project counts as unreadable and nothing
    /// reaches settings.
    private func unreadableLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopFolderImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: project.appendingPathComponent("project.json"))
        return root
    }

    @Test(.timeLimit(.minutes(1)))
    func aFolderDroppedWhileImportingIsQueued() async throws {
        let first = try unreadableLibrary()
        let second = try unreadableLibrary()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let coordinator = WorkshopFolderImportCoordinator()
        let finished = ImportBatchLog()
        coordinator.onLocalLibraryImported = { _ in finished.batches += 1 }

        coordinator.importProjects(from: [first])
        coordinator.importProjects(from: [second])
        #expect(coordinator.isImporting)
        while coordinator.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(finished.batches == 2, "a folder that arrives mid-import must wait its turn, not vanish")
        #expect(coordinator.progress == nil)
    }

    // MARK: - Folder import and download scan share one importer

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aFolderRequestWaitsForTheDownloadScan(cancelScan: Bool) async throws {
        let steam = try SteamDownloads()
        let folder = try unreadableLibrary()
        defer {
            steam.discard()
            try? FileManager.default.removeItem(at: folder)
        }
        let gate = ValidationGate()
        let coordinator = WorkshopFolderImportCoordinator(importService: importer(parkingOn: gate))
        let finished = ImportBatchLog()
        coordinator.onLocalLibraryImported = { _ in finished.batches += 1 }

        let scan = Task { await coordinator.ingestExistingDownloads(using: steam.doctor) }
        try await settle { await gate.entries == 1 }
        coordinator.importProjects(from: [folder])
        try await Task.sleep(for: .milliseconds(300))
        #expect(finished.batches == 0, "a folder import ran while the download scan was still writing")

        if cancelScan {
            scan.cancel()
        }
        await gate.release()
        await scan.value
        try await settle { !coordinator.isImporting }
        #expect(finished.batches == 1, "the folder that waited behind the scan never ran")
    }

    @Test(.timeLimit(.minutes(1)))
    func theDownloadScanStandsAsideForAFolderImport() async throws {
        let steam = try SteamDownloads()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopFolderImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try writeVideoProject(at: folder, workshopID: "manual")
        defer {
            steam.discard()
            try? FileManager.default.removeItem(at: folder)
        }
        let gate = ValidationGate()
        let coordinator = WorkshopFolderImportCoordinator(importService: importer(parkingOn: gate))

        coordinator.importProjects(from: [folder])
        try await settle { await gate.entries == 1 }
        let scan = Task { await coordinator.ingestExistingDownloads(using: steam.doctor) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await gate.entries == 1, "the download scan imported while a folder import was still writing")

        await gate.release()
        await scan.value
        try await settle { !coordinator.isImporting }
        #expect(await gate.entries == 1, "a scan turned away mid-import ran later anyway")
    }

    @Test(.timeLimit(.minutes(1)))
    func eitherEntryRunsAgainAfterTheOtherFails() async throws {
        let steam = try SteamDownloads()
        let folder = try unreadableLibrary()
        defer {
            steam.discard()
            try? FileManager.default.removeItem(at: folder)
        }
        let gate = ValidationGate()
        await gate.release()
        let coordinator = WorkshopFolderImportCoordinator(importService: importer(parkingOn: gate))
        let finished = ImportBatchLog()
        coordinator.onLocalLibraryImported = { _ in finished.batches += 1 }

        coordinator.importProjects(from: [folder])
        try await settle { !coordinator.isImporting }
        await coordinator.ingestExistingDownloads(using: steam.doctor)
        #expect(await gate.entries == 1, "the download scan stayed locked out after a failed folder import")

        coordinator.importProjects(from: [folder])
        try await settle { !coordinator.isImporting }
        #expect(finished.batches == 2, "a folder import stayed locked out after a failed download scan")
    }

    @Test("An import returning after final flush cannot publish history", .timeLimit(.minutes(1)))
    func lateImportCannotWriteAfterTerminationFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderExit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project")
        try writeVideoProject(at: folder, workshopID: "late-exit")
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.FolderExit")
        defer { defaults.discard() }
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: defaults.defaults)
        let gate = SuccessfulValidationGate()
        let coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in await gate.park() }, makeBookmark: { Data($0.path.utf8) }),
            settings: manager
        )
        let finished = ImportBatchLog()
        coordinator.onLocalLibraryImported = { _ in finished.batches += 1 }
        coordinator.importProjects(from: [folder])
        try await settle { await gate.entries == 1 }
        #expect(await gate.entries == 1)

        let presetFolder = root.appendingPathComponent("preset")
        try writePresetProject(at: presetFolder)
        coordinator.importProjects(from: [presetFolder])
        coordinator.shutdown()
        coordinator.shutdown()
        coordinator.importProjects(from: [presetFolder])
        #expect(await manager.flushPendingWrites())
        await gate.release()
        try await settle { !coordinator.isImporting }

        #expect(manager.loadGlobalSettings().recentWPEImports.isEmpty)
        #expect(manager.loadGlobalSettings().scenePresets.isEmpty)
        #expect(finished.batches == 0)
        #expect(!manager.persistenceStatus.hasUnsavedChanges)
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("A borrowed download scan cannot publish after shutdown", .timeLimit(.minutes(1)))
    func lateDownloadScanCannotWriteAfterTerminationFlush() async throws {
        let steam = try SteamDownloads()
        defer { steam.discard() }
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.ScanExit")
        defer { defaults.discard() }
        let root = steam.root.appendingPathComponent("settings")
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root), defaults: defaults.defaults)
        let gate = SuccessfulValidationGate()
        let coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in await gate.park() }, makeBookmark: { Data($0.path.utf8) }),
            settings: manager
        )
        let scan = Task { await coordinator.ingestExistingDownloads(using: steam.doctor) }
        try await settle { await gate.entries == 1 }
        #expect(await gate.entries == 1)
        coordinator.shutdown()
        #expect(await manager.flushPendingWrites())
        await gate.release()
        await scan.value
        #expect(manager.loadGlobalSettings().recentWPEImports.isEmpty)
        #expect(!manager.persistenceStatus.hasUnsavedChanges)
        await coordinator.ingestExistingDownloads(using: steam.doctor)
        #expect(await gate.entries == 1)
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("A rescan of a library past 200 items imports nothing new", .timeLimit(.minutes(1)))
    func rescanOfLargeLibraryKeepsEveryItem() async throws {
        let itemCount = 201
        let steam = try SteamDownloads(itemCount: itemCount)
        defer { steam.discard() }
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.LargeLibraryScan")
        defer { defaults.discard() }
        let root = steam.root.appendingPathComponent("settings")
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root), defaults: defaults.defaults)
        let toastCenter = WorkshopToastCenter()
        // Real bookmarks: the scan only counts an item as known when its source bookmark resolves.
        let coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() }),
            settings: manager,
            toastCenter: toastCenter
        )

        await coordinator.ingestExistingDownloads(using: steam.doctor)
        #expect(toastCenter.lastEvent?.message == WorkshopFolderImportCoordinator.syncSummary(added: itemCount, repaired: 0))
        let firstToast = toastCenter.lastEvent?.token
        let firstImportedAt = Dictionary(
            uniqueKeysWithValues: manager.loadGlobalSettings().recentWPEImports.map { ($0.origin.workshopID, $0.importedAt) }
        )

        await coordinator.ingestBoundLibraryDownloads(using: steam.doctor)
        let recent = manager.loadGlobalSettings().recentWPEImports
        #expect(toastCenter.lastEvent?.token == firstToast, "the second scan re-imported items it had already imported")
        #expect(recent.count == itemCount)
        #expect(firstImportedAt.count == itemCount)
        for entry in recent {
            #expect(entry.importedAt == firstImportedAt[entry.origin.workshopID], "item \(entry.origin.workshopID) was re-imported")
        }
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("Completed wallpaper and preset imports survive the final flush", .timeLimit(.minutes(1)))
    func completedImportsRemainDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderSaved-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project")
        let presetFolder = root.appendingPathComponent("preset")
        try writeVideoProject(at: folder, workshopID: "saved-exit")
        try writePresetProject(at: presetFolder)
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.FolderSaved")
        defer { defaults.discard() }
        let directory = ConfigurationDirectory(root: root.appendingPathComponent("settings"))
        let manager = SettingsManager(directory: directory, defaults: defaults.defaults)
        let coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { Data($0.path.utf8) }),
            settings: manager
        )
        let finished = ImportBatchLog()
        coordinator.onLocalLibraryImported = { _ in finished.batches += 1 }
        coordinator.importProjects(from: [folder])
        coordinator.importProjects(from: [presetFolder])
        try await settle { !coordinator.isImporting }
        #expect(finished.batches == 2)
        coordinator.shutdown()
        #expect(await manager.flushPendingWrites())
        let restarted = SettingsManager(directory: directory, defaults: defaults.defaults)
        #expect(restarted.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID) == ["saved-exit"])
        #expect(restarted.loadGlobalSettings().scenePresets["3471679253"]?.baseWorkshopID == "3470764447")
        await TestScratch.discard(root, flushing: manager, restarted)
    }

    @Test("Directory discovery leaves MainActor responsive", .timeLimit(.minutes(1)))
    func blockingDiscoveryDoesNotOccupyMainActor() async throws {
        let gate = BlockingDiscoveryGate()
        defer { gate.release() }
        let coordinator = WorkshopFolderImportCoordinator(
            discoverFolders: { @Sendable _ in gate.discover(returning: []) },
            toastCenter: WorkshopToastCenter()
        )
        coordinator.importProjects(from: [FileManager.default.temporaryDirectory])
        try await settle { gate.hasStarted }
        #expect(gate.hasStarted)
        #expect(!gate.hasFinished, "MainActor could only continue after discovery stopped blocking")
        #expect(!gate.ranOnMainThread)
        gate.release()
        try await settle { !coordinator.isImporting }
        #expect(!coordinator.isImporting)
    }

    @Test("Late discovery cannot publish after shutdown", .timeLimit(.minutes(1)), arguments: [0, 1, 2])
    func lateDiscoveryCannotPublishAfterShutdown(outcome: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryExit-\(UUID())")
        let folder = root.appendingPathComponent("project")
        try writeVideoProject(at: folder, workshopID: "late-discovery")
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.DiscoveryExit")
        defer { defaults.discard() }
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: defaults.defaults)
        let gate = BlockingDiscoveryGate()
        defer { gate.release() }
        let result: [URL]? = outcome == 0 ? nil : outcome == 1 ? [] : [folder]
        let toastCenter = WorkshopToastCenter()
        let finished = ImportBatchLog()
        let coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { Data($0.path.utf8) }),
            settings: manager,
            discoverFolders: { @Sendable _ in gate.discover(returning: result) },
            toastCenter: toastCenter
        )
        coordinator.onLocalLibraryImported = { _ in finished.batches += 1 }
        coordinator.importProjects(from: [root])
        try await settle { gate.hasStarted }
        #expect(gate.hasStarted)
        #expect(!gate.hasFinished)
        coordinator.importProjects(from: [folder])
        coordinator.shutdown()
        #expect(await manager.flushPendingWrites())
        gate.release()
        try await settle { !coordinator.isImporting }
        #expect(!coordinator.isImporting)
        #expect(coordinator.progress == nil)
        #expect(toastCenter.lastEvent == nil)
        #expect(manager.loadGlobalSettings().recentWPEImports.isEmpty)
        #expect(manager.loadGlobalSettings().scenePresets.isEmpty)
        #expect(!manager.persistenceStatus.hasUnsavedChanges)
        #expect(finished.batches == 0)
        #expect(gate.calls == 1)
        await TestScratch.discard(root, flushing: manager)
    }

    // MARK: - One Workshop id, one library entry

    @Test(
        "A Workshop id already in the library from another folder is not imported again",
        .timeLimit(.minutes(1)),
        arguments: [("local", "steam"), ("steam", "local"), ("local", "local-again")]
    )
    func importOfAnIDHeldByAnotherFolderIsAConflict(existing: String, incoming: String) async throws {
        let library = try ConflictLibrary()
        try library.coordinator.importProjects(from: [library.project(existing, title: "Already held")])
        try await settle { !library.coordinator.isImporting }
        let before = library.manager.loadGlobalSettings().recentWPEImports
        #expect(before.count == 1)
        let imported = ImportBatchLog()
        library.coordinator.onLocalLibraryImported = { imported.batches += $0 }

        try library.coordinator.importProjects(from: [library.project(incoming, title: "Incoming")])
        try await settle { !library.coordinator.isImporting }

        #expect(library.manager.loadGlobalSettings().recentWPEImports == before, "a second folder holding the id was imported over or beside the first")
        #expect(imported.batches == 0)
        let toast = try #require(library.toastCenter.lastEvent)
        #expect(!toast.isSuccess)
        #expect(toast.message.contains("Already held"), "the toast did not name the item already in the library: \(toast.message)")
        await library.discard()
    }

    @Test("Re-importing the folder already in the library refreshes it", .timeLimit(.minutes(1)), arguments: ["local", "steam"])
    func reimportOfTheSameFolderIsNotAConflict(kind: String) async throws {
        let library = try ConflictLibrary()
        let folder = try library.project(kind, title: "Held")
        library.coordinator.importProjects(from: [folder])
        try await settle { !library.coordinator.isImporting }
        let imported = ImportBatchLog()
        library.coordinator.onLocalLibraryImported = { imported.batches += $0 }

        library.coordinator.importProjects(from: [folder])
        try await settle { !library.coordinator.isImporting }

        #expect(imported.batches == 1)
        #expect(library.manager.loadGlobalSettings().recentWPEImports.count == 1)
        #expect(library.toastCenter.lastEvent?.isSuccess == true)
        await library.discard()
    }

    @Test("The download scan brings in a Steam item a local copy holds, beside the copy, once", .timeLimit(.minutes(1)))
    func downloadScanImportsASteamItemOverALocalCopy() async throws {
        let steam = try SteamDownloads()
        let library = try ConflictLibrary()
        defer { steam.discard() }
        let steamFolder = steam.itemFolders[0]
        let localCopy = library.root.appendingPathComponent("Wallpapers/copy", isDirectory: true)
        try writeVideoProject(at: localCopy, workshopID: steamFolder.lastPathComponent, title: "Local copy")
        library.coordinator.importProjects(from: [localCopy])
        try await settle { !library.coordinator.isImporting }
        let before = library.manager.loadGlobalSettings().recentWPEImports
        #expect(before.count == 1)

        await library.coordinator.ingestExistingDownloads(using: steam.doctor)
        let after = library.manager.loadGlobalSettings().recentWPEImports
        #expect(after.count == 2)
        #expect(after.contains { $0.origin.steamFolderItemID == steamFolder.lastPathComponent }, "the Steam folder was not imported")
        #expect(after.contains { $0.origin == before[0].origin }, "the scan itself removed the local copy")
        let toast = library.toastCenter.lastEvent
        #expect(toast?.message == WorkshopFolderImportCoordinator.syncSummary(added: 1, repaired: 0))

        await library.coordinator.ingestBoundLibraryDownloads(using: steam.doctor)
        #expect(library.manager.loadGlobalSettings().recentWPEImports == after, "the second scan imported the Steam item again")
        #expect(library.toastCenter.lastEvent?.token == toast?.token)
        await library.discard()
    }

    @Test("The download scan skips a Steam item another Steam folder already holds, and says so once per launch", .timeLimit(.minutes(1)))
    func downloadScanReportsASteamConflictOnce() async throws {
        let steam = try SteamDownloads()
        let library = try ConflictLibrary()
        defer { steam.discard() }
        let id = steam.itemFolders[0].lastPathComponent
        let otherSteamFolder = SteamLibraryPaths.workshopContentRoot(steamRoot: library.root.appendingPathComponent("OtherSteam", isDirectory: true))
            .appendingPathComponent(id, isDirectory: true)
        try writeVideoProject(at: otherSteamFolder, workshopID: id, title: "Other Steam library")
        library.coordinator.importProjects(from: [otherSteamFolder])
        try await settle { !library.coordinator.isImporting }
        let before = library.manager.loadGlobalSettings().recentWPEImports
        #expect(before.count == 1)
        #expect(before.first?.origin.steamFolderItemID == id)

        await library.coordinator.ingestExistingDownloads(using: steam.doctor)
        #expect(library.manager.loadGlobalSettings().recentWPEImports == before)
        let toast = library.toastCenter.lastEvent
        #expect(toast?.message == WorkshopFolderImportCoordinator.syncSummary(added: 0, repaired: 0, conflicts: 1))

        await library.coordinator.ingestBoundLibraryDownloads(using: steam.doctor)
        #expect(library.toastCenter.lastEvent?.token == toast?.token, "the second scan repeated a conflict already shown")
        await library.discard()
    }

    @Test("A download scan resolves each history bookmark once, plus once per entry it adds", .timeLimit(.minutes(1)))
    func downloadScanResolvesEachEntryOnce() async throws {
        let steam = try SteamDownloads(itemCount: 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanResolves-\(UUID().uuidString)", isDirectory: true)
        let suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.ScanResolves")
        defer {
            steam.discard()
            suite.discard()
        }
        let resolves = OSAllocatedUnfairLock(initialState: 0)
        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")),
            defaults: suite.defaults,
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { data in
                    resolves.withLock { $0 += 1 }
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
                    return (url, isStale)
                },
                refreshData: { try $0.bookmarkData() }
            )
        )
        try await TestScratch.withCleanup { await TestScratch.discard(root, flushing: manager) } operation: {
            let coordinator = WorkshopFolderImportCoordinator(
                importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() }),
                settings: manager,
                toastCenter: WorkshopToastCenter(),
                defaults: suite.defaults
            )
            let downloadedIDs = steam.itemFolders.map(\.lastPathComponent)
            let wallpapers = root.appendingPathComponent("Wallpapers", isDirectory: true)
            for id in downloadedIDs + ["1001", "1002", "1003", "1004"] {
                try writeVideoProject(at: wallpapers.appendingPathComponent(id, isDirectory: true), workshopID: id)
            }
            coordinator.importProjects(from: [wallpapers])
            try await settle { !coordinator.isImporting }
            let history = manager.loadGlobalSettings().recentWPEImports
            #expect(history.count == downloadedIDs.count + 4)
            resolves.withLock { $0 = 0 }

            await coordinator.ingestExistingDownloads(using: steam.doctor)

            #expect(manager.loadGlobalSettings().recentWPEImports.count == history.count + downloadedIDs.count, "the scan did not bring the Steam items in beside their local copies")
            let count = resolves.withLock { $0 }
            #expect(count <= history.count + downloadedIDs.count, "the scan resolved \(count) bookmarks for \(history.count) history entries")
        }
    }

    // MARK: - Workshop page visits

    @Test("A Workshop visit skips the download scan while the downloads and history are unchanged", .timeLimit(.minutes(1)))
    func unchangedDownloadsAreNotRescanned() async throws {
        let scans = try CountedScans()
        await scans.visit()
        #expect(scans.manager.loadGlobalSettings().recentWPEImports.count == 1)
        _ = scans.takeResolves()

        await scans.visit()

        #expect(scans.takeResolves() == 0, "a visit rescanned downloads that had not changed")
        await scans.discard()
    }

    @Test("A Workshop visit scans again once a new item folder appears", .timeLimit(.minutes(1)))
    func aNewDownloadIsScanned() async throws {
        let scans = try CountedScans()
        await scans.visit()
        _ = scans.takeResolves()
        let newItem = SteamLibraryPaths.workshopContentRoot(steamRoot: scans.steam.root)
            .appendingPathComponent("9900000000", isDirectory: true)
        try writeVideoProject(at: newItem, workshopID: newItem.lastPathComponent)

        await scans.visit()

        #expect(scans.takeResolves() > 0, "a visit after a new download skipped the scan")
        #expect(scans.manager.loadGlobalSettings().recentWPEImports.count == 2)
        await scans.discard()
    }

    @Test("A Workshop visit after a scan with an unreadable item scans again", .timeLimit(.minutes(1)))
    func aScanWithAnUnreadableItemIsNotTreatedAsDone() async throws {
        let scans = try CountedScans()
        let broken = SteamLibraryPaths.workshopContentRoot(steamRoot: scans.steam.root)
            .appendingPathComponent("9900000001", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("project.json"))
        await scans.visit()
        #expect(scans.manager.loadGlobalSettings().recentWPEImports.count == 1)
        _ = scans.takeResolves()

        await scans.visit()

        #expect(scans.takeResolves() > 0, "a scan that could not read an item counted as finished, so the next visit skipped it")
        await scans.discard()
    }

    @Test("A Workshop visit after a cancelled scan scans again", .timeLimit(.minutes(1)))
    func aCancelledScanIsNotTreatedAsDone() async throws {
        let scans = try CountedScans(parksImports: true)
        let cancelled = Task { await scans.visit() }
        try await settle { await scans.gate.entries == 1 }
        cancelled.cancel()
        await scans.gate.release()
        await cancelled.value

        await scans.visit()

        #expect(await scans.gate.entries == 2, "a cancelled scan counted as finished, so the next visit skipped it")
        await scans.discard()
    }

    @Test("A Workshop visit that skips the scan still advances the Steam prune baseline", .timeLimit(.minutes(1)))
    func aSkippedScanStillAdvancesThePruneBaseline() async throws {
        let scans = try CountedScans()
        let id = scans.steam.itemFolders[0].lastPathComponent
        try writeAppWorkshopACF(appWorkshopACF(installed: [id]), steamRoot: scans.steam.root)
        await scans.visit()
        #expect(scans.coordinator.steamPruneBaseline?.listedIDs == [id])
        try writeAppWorkshopACF(appWorkshopACF(installed: []), steamRoot: scans.steam.root)
        _ = scans.takeResolves()

        await scans.visit()

        #expect(scans.takeResolves() == 0)
        #expect(scans.coordinator.steamPruneBaseline?.listedIDs == [], "a skipped scan left the baseline at the old acf listing")
        await scans.discard()
    }

    // MARK: - Library scan without the Workshop page

    @Test("The launch scan imports the bound library's downloads without SteamCMD", .timeLimit(.minutes(1)))
    func launchScanImportsTheBoundLibrary() async throws {
        let steam = try SteamDownloads(itemCount: 2)
        let library = try ConflictLibrary()
        defer { steam.discard() }
        #expect(!steam.doctor.hasBoundBinary)

        await library.coordinator.ingestBoundLibraryDownloads(using: steam.doctor)

        #expect(library.importedIDs == Set(steam.itemFolders.map(\.lastPathComponent)))
        await library.discard()
    }

    @Test("The launch scan skips a missing or broken library grant", .timeLimit(.minutes(1)), arguments: [false, true])
    func launchScanSkipsAnUnusableGrant(bound: Bool) async throws {
        let library = try ConflictLibrary()
        let suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.LaunchScanGrant")
        defer { suite.discard() }
        let doctor = SteamCMDDoctorService(defaults: suite.defaults, bookmarkResolver: unscopedSharedLibraryResolver())
        if bound {
            doctor.workdirBookmarkData = Data([0x01])
        }

        await library.coordinator.ingestBoundLibraryDownloads(using: doctor)

        #expect(library.importedIDs.isEmpty)
        #expect(doctor.workdirResolutionFailed == bound)
        await library.discard()
    }

    @Test("Authorizing the Steam library imports its downloads without the Workshop page", .timeLimit(.minutes(1)))
    func successfulBindScansTheLibrary() async throws {
        let steam = try SteamDownloads()
        let library = try ConflictLibrary()
        defer { steam.discard() }
        let grant = try #require(steam.doctor.workdirBookmarkData)
        steam.doctor.workdirBookmarkData = nil
        let controller = WorkshopSetupController(
            doctor: steam.doctor, defaults: steam.suite.defaults, folderImporter: library.coordinator,
            bindLibrary: { _ in steam.doctor.workdirBookmarkData = grant }
        )

        await controller.bindSteamLibrary(steam.root)

        #expect(controller.setupError == nil)
        #expect(library.importedIDs == Set(steam.itemFolders.map(\.lastPathComponent)))
        await library.discard()
    }

    @Test("A refused Steam library binding scans nothing", .timeLimit(.minutes(1)))
    func failedBindDoesNotScan() async throws {
        let steam = try SteamDownloads()
        let library = try ConflictLibrary()
        defer { steam.discard() }
        let controller = WorkshopSetupController(
            doctor: steam.doctor, defaults: steam.suite.defaults, folderImporter: library.coordinator,
            bindLibrary: { url in throw SteamCMDDoctorError.steamLibraryMissingConfig(url) }
        )

        await controller.bindSteamLibrary(steam.root)

        #expect(controller.setupError != nil)
        #expect(library.importedIDs.isEmpty, "a refused binding still scanned the previously bound library")
        await library.discard()
    }

    // MARK: - Items Steam deleted

    @Test("A Steam item Steam deleted leaves the library on the next scan without a tombstone", .timeLimit(.minutes(1)))
    func itemSteamDeletedIsRemoved() async throws {
        let scan = try await scanAfterSteamRemovedItem { _ in appWorkshopACF(installed: ["1"]) }
        #expect(scan.remaining.isEmpty, "an entry whose folder Steam deleted and no longer lists stayed in the library")
        #expect(scan.removed == [scan.itemID])
        #expect(scan.tombstones.isEmpty)
    }

    @Test("A missing folder Steam still lists stays in the library", .timeLimit(.minutes(1)))
    func itemStillInACFIsKept() async throws {
        let scan = try await scanAfterSteamRemovedItem { appWorkshopACF(installed: [$0]) }
        #expect(scan.remaining == [scan.itemID])
        #expect(scan.removed.isEmpty)
    }

    @Test("A Steam library whose content folder is gone keeps every entry", .timeLimit(.minutes(1)))
    func unpluggedLibraryKeepsEntries() async throws {
        let scan = try await scanAfterSteamRemovedItem(removingContentRoot: true) { _ in appWorkshopACF(installed: []) }
        #expect(scan.remaining == [scan.itemID])
        #expect(scan.removed.isEmpty)
    }

    @Test("A missing or truncated acf keeps every entry", .timeLimit(.minutes(1)), arguments: [false, true])
    func unreadableACFKeepsEntries(truncated: Bool) async throws {
        let scan = try await scanAfterSteamRemovedItem { _ in
            truncated ? String(appWorkshopACF(installed: ["1"]).prefix(70)) : nil
        }
        #expect(scan.remaining == [scan.itemID])
        #expect(scan.removed.isEmpty)
    }

    @Test("A missing local folder outside Steam's layout stays in the library", .timeLimit(.minutes(1)))
    func missingLocalFolderIsKept() async throws {
        let steam = try SteamDownloads()
        let library = try ConflictLibrary(removedIDs: RemovedIDs())
        defer { steam.discard() }
        let local = try library.project("local", title: "Local")
        library.coordinator.importProjects(from: [local])
        try await settle { !library.coordinator.isImporting }
        #expect(library.importedIDs == [ConflictLibrary.itemID])
        try FileManager.default.removeItem(at: local)
        try FileManager.default.removeItem(at: steam.itemFolders[0])
        try writeAppWorkshopACF(appWorkshopACF(installed: []), steamRoot: steam.root)

        await library.coordinator.ingestExistingDownloads(using: steam.doctor)

        #expect(library.importedIDs == [ConflictLibrary.itemID])
        #expect(library.removedIDs?.ids.isEmpty == true)
        await library.discard()
    }

    @Test("installedIDs reads only the WorkshopItemsInstalled block")
    func acfInstalledIDs() throws {
        let acf = appWorkshopACF(installed: ["111", "222"])
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf) == ["111", "222"])
        #expect(SteamWorkshopManifest.installedIDs(fromACF: appWorkshopACF(installed: [])) == [])
        let withoutInstalled = "\"AppWorkshop\"\n{\n\t\"appid\"\t\t\"431960\"\n}\n"
        #expect(SteamWorkshopManifest.installedIDs(fromACF: withoutInstalled) == nil)
        let installedClose = try #require(acf.range(of: "\t}\n\t\"WorkshopItemDetails\""))
        #expect(SteamWorkshopManifest.installedIDs(fromACF: String(acf[..<installedClose.lowerBound])) == nil)
    }

    private struct VanishedItemScan {
        let itemID: String
        let remaining: [String]
        let removed: [String]
        let tombstones: [String]
    }

    /// Imports one Steam download with an acf listing it, deletes its folder, writes the acf `acf(itemID)` returns (keeps the listing for nil), and scans again.
    private func scanAfterSteamRemovedItem(
        removingContentRoot: Bool = false,
        acf: (String) -> String?
    ) async throws -> VanishedItemScan {
        let steam = try SteamDownloads()
        let library = try ConflictLibrary(removedIDs: RemovedIDs())
        defer { steam.discard() }
        let folder = steam.itemFolders[0]
        let itemID = folder.lastPathComponent
        try writeAppWorkshopACF(appWorkshopACF(installed: [itemID]), steamRoot: steam.root)
        await library.coordinator.ingestExistingDownloads(using: steam.doctor)
        #expect(library.manager.loadGlobalSettings().recentWPEImports.map(\.origin.steamFolderItemID) == [itemID])
        // Records the baseline listing the item, as the prune after its download would.
        await library.coordinator.pruneSteamDeletedImports(using: steam.doctor)

        try FileManager.default.removeItem(at: removingContentRoot ? folder.deletingLastPathComponent() : folder)
        if let text = acf(itemID) {
            try writeAppWorkshopACF(text, steamRoot: steam.root)
        }
        await library.coordinator.ingestExistingDownloads(using: steam.doctor)

        let settings = library.manager.loadGlobalSettings()
        await library.discard()
        return VanishedItemScan(
            itemID: itemID,
            remaining: settings.recentWPEImports.map(\.origin.workshopID),
            removed: library.removedIDs?.ids ?? [],
            tombstones: settings.deletedWorkshopIDs
        )
    }

    private func unscopedSharedLibraryResolver() -> SecurityScopedBookmarkResolver {
        let shared = URL(fileURLWithPath: "/private/tmp/LoomscreenUnscopedLibrary", isDirectory: true)
        return SecurityScopedBookmarkResolver(
            resolveScoped: { _ in throw CocoaError(.fileReadNoPermission) },
            resolveUnscoped: { _ in (shared, false) },
            refreshData: { _ in Data() }
        )
    }

    private func importer(parkingOn gate: ValidationGate) -> WallpaperEngineImportService {
        WallpaperEngineImportService(
            validateVideo: { _ in try await gate.park() },
            makeBookmark: { url in Data(url.path.utf8) }
        )
    }

    /// Gives up after two seconds so a stuck importer fails the next expectation instead of the time limit.
    private func settle(_ done: () async -> Bool) async throws {
        for _ in 0 ..< 200 {
            if await done() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func writeVideoProject(at folder: URL, workshopID: String, title: String = "Held") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest = #"{"workshopid":"\#(workshopID)","title":"\#(title)","type":"video","file":"video.mp4"}"#
    try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
    try Data([0x00]).write(to: folder.appendingPathComponent("video.mp4"))
}

func appWorkshopACF(installed ids: [String]) -> String {
    let items = ids.map { "\t\t\"\($0)\"\n\t\t{\n\t\t\t\"size\"\t\t\"1\"\n\t\t}\n" }.joined()
    return "\"AppWorkshop\"\n{\n\t\"appid\"\t\t\"431960\"\n\t\"WorkshopItemsInstalled\"\n\t{\n\(items)\t}\n"
        + "\t\"WorkshopItemDetails\"\n\t{\n\(items)\t}\n}\n"
}

func writeAppWorkshopACF(_ text: String, steamRoot: URL) throws {
    try Data(text.utf8).write(to: steamRoot.appendingPathComponent("steamapps/workshop/appworkshop_431960.acf"))
}

/// Ids the coordinator asked to drop as deleted by Steam.
@MainActor
private final class RemovedIDs {
    var ids: [String] = []
}

private func writePresetProject(at folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest = #"{"workshopid":"3471679253","title":"Preset","dependency":"3470764447","preset":{}}"#
    try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
}

/// A scratch Steam library holding downloaded video items, and a doctor bound to it.
@MainActor
private struct SteamDownloads {
    let root: URL
    let itemFolders: [URL]
    let suite: TestScratch.DefaultsSuite
    let doctor: SteamCMDDoctorService

    init(itemCount: Int = 1, function: String = #function) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopFolderImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        let firstID = UInt64.random(in: 9_000_000_000 ... 9_899_999_999)
        itemFolders = (0 ..< UInt64(itemCount)).map {
            SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(String(firstID + $0), isDirectory: true)
        }
        for folder in itemFolders {
            try writeVideoProject(at: folder, workshopID: folder.lastPathComponent)
        }
        suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.WorkshopFolderImportCoordinator", function: function)
        doctor = SteamCMDDoctorService(defaults: suite.defaults)
        doctor.workdirBookmarkData = try root.bookmarkData()
    }

    func discard() {
        suite.discard()
        try? FileManager.default.removeItem(at: root)
    }
}

/// A coordinator over a scratch library with real bookmarks: only an entry whose folder still resolves can conflict.
@MainActor
private struct ConflictLibrary {
    static let itemID = "2585024298"
    let root: URL
    let suite: TestScratch.DefaultsSuite
    let manager: SettingsManager
    let toastCenter = WorkshopToastCenter()
    let coordinator: WorkshopFolderImportCoordinator
    /// Set when the coordinator may drop entries Steam deleted; it then removes them from `manager` without a tombstone.
    let removedIDs: RemovedIDs?

    init(removedIDs: RemovedIDs? = nil, function: String = #function) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderConflict-\(UUID().uuidString)", isDirectory: true)
        suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.FolderConflict", function: function)
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: suite.defaults)
        self.manager = manager
        self.removedIDs = removedIDs
        coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() }),
            settings: manager,
            toastCenter: toastCenter,
            defaults: suite.defaults,
            removeVanishedImport: { entry in
                guard let removedIDs else {
                    Issue.record("the scan removed \(entry.origin.workshopID) where no removal was expected")
                    return false
                }
                removedIDs.ids.append(entry.origin.workshopID)
                return manager.removeWPEImport(
                    workshopID: entry.origin.workshopID,
                    matchingImportedAt: entry.importedAt,
                    recordingDeleteTombstone: false
                )
            }
        )
    }

    /// `steam` is the item's folder in Steam's Workshop layout; any other name is a local folder whose manifest carries the id.
    func project(_ name: String, title: String) throws -> URL {
        let folder = name == "steam"
            ? SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(Self.itemID, isDirectory: true)
            : root.appendingPathComponent("Wallpapers/\(name)", isDirectory: true)
        try writeVideoProject(at: folder, workshopID: Self.itemID, title: title)
        return folder
    }

    var importedIDs: Set<String> {
        Set(manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID))
    }

    func discard() async {
        suite.discard()
        await TestScratch.discard(root, flushing: manager)
    }
}

/// Workshop page visits over one Steam download. A scan resolves every history bookmark and a skipped visit none,
/// so `takeResolves()` tells them apart; with `parksImports`, imports park on `gate` and `gate.entries` counts them.
@MainActor
private struct CountedScans {
    let steam: SteamDownloads
    let suite: TestScratch.DefaultsSuite
    let manager: SettingsManager
    let gate: ValidationGate
    let coordinator: WorkshopFolderImportCoordinator
    private let resolves: OSAllocatedUnfairLock<Int>

    init(parksImports: Bool = false, function: String = #function) throws {
        steam = try SteamDownloads(function: function)
        suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.CountedScans", function: function)
        let resolves = OSAllocatedUnfairLock(initialState: 0)
        self.resolves = resolves
        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: steam.root.appendingPathComponent("settings")),
            defaults: suite.defaults,
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { data in
                    resolves.withLock { $0 += 1 }
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
                    return (url, isStale)
                },
                refreshData: { try $0.bookmarkData() }
            )
        )
        self.manager = manager
        let gate = ValidationGate()
        self.gate = gate
        coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(
                validateVideo: { [gate] _ in
                    if parksImports {
                        try await gate.park()
                    }
                },
                makeBookmark: { try? $0.bookmarkData() }
            ),
            settings: manager,
            toastCenter: WorkshopToastCenter(),
            defaults: suite.defaults
        )
    }

    func visit() async {
        await coordinator.ingestExistingDownloads(using: steam.doctor)
    }

    /// History bookmarks resolved since the last call.
    func takeResolves() -> Int {
        resolves.withLock { count in
            defer { count = 0 }
            return count
        }
    }

    func discard() async {
        suite.discard()
        await TestScratch.discard(steam.root.appendingPathComponent("settings"), flushing: manager)
        steam.discard()
    }
}

/// Parks every video validation until released; afterwards each one fails at once, so nothing is recorded.
private actor ValidationGate {
    private(set) var entries = 0
    private var parked: [CheckedContinuation<Void, any Error>] = []
    private var isReleased = false

    func park() async throws {
        entries += 1
        guard !isReleased else { throw CancellationError() }
        try await withCheckedThrowingContinuation { parked.append($0) }
    }

    func release() {
        isReleased = true
        for continuation in parked {
            continuation.resume(throwing: CancellationError())
        }
        parked = []
    }
}

private actor SuccessfulValidationGate {
    private(set) var entries = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        entries += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class BlockingDiscoveryGate: Sendable {
    private struct State {
        var calls = 0
        var finished = false
        var ranOnMainThread = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let semaphore = DispatchSemaphore(value: 0)

    var hasStarted: Bool {
        state.withLock { $0.calls > 0 }
    }

    var hasFinished: Bool {
        state.withLock { $0.finished }
    }

    var ranOnMainThread: Bool {
        state.withLock { $0.ranOnMainThread }
    }

    var calls: Int {
        state.withLock { $0.calls }
    }

    func discover(returning result: [URL]?) -> [URL]? {
        state.withLock {
            $0.calls += 1
            $0.ranOnMainThread = Thread.isMainThread
        }
        // A timeout makes the synchronous negative control fail without hanging the host.
        _ = semaphore.wait(timeout: .now() + 2)
        state.withLock { $0.finished = true }
        return result
    }

    func release() {
        semaphore.signal()
    }
}

@MainActor
private final class ImportBatchLog {
    var batches = 0
}
#endif
