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
        defer { await TestScratch.discard(root, flushing: manager) }
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
    }

    @Test("A borrowed download scan cannot publish after shutdown", .timeLimit(.minutes(1)))
    func lateDownloadScanCannotWriteAfterTerminationFlush() async throws {
        let steam = try SteamDownloads()
        defer { steam.discard() }
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.ScanExit")
        defer { defaults.discard() }
        let root = steam.root.appendingPathComponent("settings")
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root), defaults: defaults.defaults)
        defer { await TestScratch.discard(root, flushing: manager) }
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
        defer { await TestScratch.discard(root, flushing: manager) }
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

        await coordinator.ingestExistingDownloads(using: steam.doctor)
        let recent = manager.loadGlobalSettings().recentWPEImports
        #expect(toastCenter.lastEvent?.token == firstToast, "the second scan re-imported items it had already imported")
        #expect(recent.count == itemCount)
        #expect(firstImportedAt.count == itemCount)
        for entry in recent {
            #expect(entry.importedAt == firstImportedAt[entry.origin.workshopID], "item \(entry.origin.workshopID) was re-imported")
        }
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
        defer { await TestScratch.discard(root, flushing: manager) }
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
        defer { await TestScratch.discard(root, flushing: manager, restarted) }
        #expect(restarted.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID) == ["saved-exit"])
        #expect(restarted.loadGlobalSettings().scenePresets["3471679253"]?.baseWorkshopID == "3470764447")
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
        defer { await TestScratch.discard(root, flushing: manager) }
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

private func writeVideoProject(at folder: URL, workshopID: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest = #"{"workshopid":"\#(workshopID)","title":"Held","type":"video","file":"video.mp4"}"#
    try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
    try Data([0x00]).write(to: folder.appendingPathComponent("video.mp4"))
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
    let suite: TestScratch.DefaultsSuite
    let doctor: SteamCMDDoctorService

    init(itemCount: Int = 1, function: String = #function) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopFolderImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let firstID = UInt64.random(in: 9_000_000_000 ... 9_899_999_999)
        for offset in 0 ..< UInt64(itemCount) {
            let itemID = String(firstID + offset)
            try writeVideoProject(
                at: SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(itemID, isDirectory: true),
                workshopID: itemID
            )
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
