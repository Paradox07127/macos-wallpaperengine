#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
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

    @Test(.timeLimit(.minutes(1)))
    func aFolderRequestWaitsForTheDownloadScan() async throws {
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

/// A scratch Steam library holding one downloaded video item, and a doctor bound to it.
@MainActor
private struct SteamDownloads {
    let root: URL
    let suite: TestScratch.DefaultsSuite
    let doctor: SteamCMDDoctorService

    init(function: String = #function) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopFolderImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let itemID = String(UInt64.random(in: 9_000_000_000 ... 9_999_999_999))
        try writeVideoProject(
            at: SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(itemID, isDirectory: true),
            workshopID: itemID
        )
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

@MainActor
private final class ImportBatchLog {
    var batches = 0
}
#endif
