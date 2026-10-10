#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Workshop download queue", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WorkshopDownloadQueueTests {
    private let first: UInt64 = 910_000_001
    private let second: UInt64 = 910_000_002

    private let downloader = GatedDownloader()
    private let downloads = WorkshopDownloadCoordinator(
        repositoryCoordinator: WorkshopRepositoryCoordinator(),
        toasts: WorkshopToastCenter()
    )

    private func makeQueue() -> WorkshopDownloadQueue {
        WorkshopDownloadQueue(downloads: downloads)
    }

    private func request(_ itemID: UInt64) -> WorkshopDownloadQueue.Request {
        WorkshopDownloadQueue.Request(itemID: itemID, title: String(itemID), replacesLocalCopy: false, doctor: downloader)
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

    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    @Test("Requests the next item only after the current one ends")
    func runsOneAtATime() async {
        let queue = makeQueue()
        queue.enqueue([request(first), request(second)])

        #expect(await waitUntil { downloader.requestedIDs == [first] })
        await settle()
        #expect(downloader.requestedIDs == [first])

        downloader.release(first)
        #expect(await waitUntil { downloader.requestedIDs == [first, second] })
        downloader.releaseAll()
        #expect(await waitUntil { queue.current == nil && queue.pending.isEmpty })
    }

    @Test("A removed item is never requested")
    func removedItemIsSkipped() async {
        let queue = makeQueue()
        queue.enqueue([request(first), request(second)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })

        queue.remove(second)
        #expect(!queue.isQueued(second))
        #expect(downloads.cancelledItems.contains(second))
        downloader.release(first)

        #expect(await waitUntil { queue.current == nil && queue.pending.isEmpty && downloads.phase(for: first) != .downloading })
        await settle()
        #expect(downloader.requestedIDs == [first])
        downloader.releaseAll()
    }

    @Test("Cancelling the current item resets it and moves on")
    func cancellingCurrentAdvances() async {
        let queue = makeQueue()
        queue.enqueue([request(first), request(second)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })

        queue.cancel(first)
        #expect(downloads.phase(for: first) == .idle)
        #expect(await waitUntil { downloader.requestedIDs == [first, second] })
        downloader.releaseAll()
        #expect(await waitUntil { queue.current == nil && queue.pending.isEmpty })
    }

    @Test("Cancelling a download started outside the queue stops it")
    func cancellingOutsideDownloadStopsIt() async {
        let queue = makeQueue()
        downloads.download(itemID: first, title: String(first), using: downloader)
        #expect(await waitUntil { downloader.requestedIDs == [first] })

        queue.cancel(first)
        #expect(downloads.phase(for: first) == .idle)
        #expect(!downloads.isBusy(first))
        downloader.releaseAll()
    }

    @Test("A failed download retains its title and reason and retries through the queue")
    func failedDownloadCanRetry() async {
        let queue = makeQueue()
        queue.enqueue([request(first)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })
        downloader.release(first)
        #expect(await waitUntil { queue.current == nil && downloads.phase(for: first) == .failed("released by test") })
        #expect(downloads.titles[first] == String(first))
        #expect(downloads.downloadOrder == [first])

        downloads.forgetSettledPhase(first)
        #expect(downloads.phase(for: first) == .failed("released by test"))
        queue.retry(first, using: downloader)
        #expect(await waitUntil { downloader.requestedIDs == [first, first] })
        #expect(downloads.downloadOrder == [first])
        downloader.releaseAll()
        #expect(await waitUntil { queue.current == nil && queue.pending.isEmpty })
    }

    @Test("Dismissing history keeps the result and allows a future download to reappear")
    func dismissingHistoryPreservesResult() async {
        let queue = makeQueue()
        queue.enqueue([request(first)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })
        downloads.removeFromHistory(first)
        #expect(downloads.downloadOrder == [first], "a running download must stay visible")

        downloader.release(first)
        #expect(await waitUntil { queue.current == nil && downloads.phase(for: first) == .failed("released by test") })
        #expect(downloads.hasFailedDownloadsInHistory)
        downloads.removeFromHistory(first)
        #expect(downloads.downloadOrder.isEmpty)
        #expect(!downloads.hasFailedDownloadsInHistory)
        #expect(downloads.titles[first] == nil)
        #expect(downloads.retryRequest(for: first) == nil)
        #expect(downloads.phase(for: first) == .failed("released by test"))

        queue.enqueue([request(first)])
        #expect(await waitUntil { downloader.requestedIDs == [first, first] })
        #expect(downloads.downloadOrder == [first])
        #expect(downloads.titles[first] == String(first))
        downloader.releaseAll()
        #expect(await waitUntil { queue.current == nil && queue.pending.isEmpty })
    }

    @Test("Failures survive restart until dismissed or retried, and a failed retry persists again")
    func failedHistorySurvivesRestart() async throws {
        let suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.FailedDownloadHistory")
        defer { suite.discard() }
        func restoredDownloads() -> WorkshopDownloadCoordinator {
            WorkshopDownloadCoordinator(
                repositoryCoordinator: WorkshopRepositoryCoordinator(), toasts: WorkshopToastCenter(),
                historyDefaults: suite.defaults
            )
        }
        let original = restoredDownloads()
        let originalQueue = WorkshopDownloadQueue(downloads: original)
        originalQueue.enqueue([request(first)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })
        downloader.release(first)
        #expect(await waitUntil { originalQueue.current == nil })

        let restored = restoredDownloads()
        #expect(restored.downloadOrder == [first])
        #expect(restored.titles[first] == String(first))
        #expect(restored.phase(for: first) == .failed("released by test"))
        let restoredQueue = WorkshopDownloadQueue(downloads: restored)
        restoredQueue.retry(first, using: downloader)
        #expect(await waitUntil { downloader.requestedIDs == [first, first] })
        #expect(restoredDownloads().downloadOrder.isEmpty, "Retry must remove the saved failure")
        downloader.release(first)
        #expect(await waitUntil { restoredQueue.current == nil })

        let failedAgain = restoredDownloads()
        #expect(failedAgain.phase(for: first) == .failed("released by test"))
        #expect(failedAgain.downloadOrder == [first])
        failedAgain.removeFromHistory(first)
        #expect(restoredDownloads().downloadOrder.isEmpty, "X must remove the saved failure")
    }

    @Test("A malformed saved failure is skipped without losing the readable ones")
    func malformedFailureDoesNotDropTheOthers() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.FailedDownloadHistory")
        defer { suite.discard() }
        let saved = #"[{"itemID":\#(first),"title":"Kept","reason":"saved reason","replacesLocalCopy":false},{"itemID":\#(second),"title":"Broken"}]"#
        suite.defaults.set(Data(saved.utf8), forKey: "workshop.failedDownloadHistory")
        let restored = WorkshopDownloadCoordinator(
            repositoryCoordinator: WorkshopRepositoryCoordinator(), toasts: WorkshopToastCenter(),
            historyDefaults: suite.defaults
        )
        #expect(restored.downloadOrder == [first])
        #expect(restored.titles[first] == "Kept")
        #expect(restored.phase(for: first) == .failed("saved reason"))
    }

    @Test("An approved copy whose bookmark was refreshed stays approved; a later re-import does not")
    func approvalSurvivesBookmarkRefresh() {
        func entry(bookmark: UInt8, importedAt: Date) -> WPEHistoryEntry {
            let origin = WPEOrigin(
                workshopID: String(second), title: "Copy", originalType: .video,
                sourceFolderBookmark: Data([bookmark]), cacheRelativePath: nil, previewFileName: nil
            )
            return WPEHistoryEntry(origin: origin, importedAt: importedAt, lastUsedAt: nil)
        }
        let importedAt = Date(timeIntervalSinceReferenceDate: 1000)
        let approved = entry(bookmark: 1, importedAt: importedAt)
        #expect(WorkshopDownloadCoordinator.isApproved(entry(bookmark: 2, importedAt: importedAt), approved))
        #expect(!WorkshopDownloadCoordinator.isApproved(entry(bookmark: 1, importedAt: importedAt.addingTimeInterval(1)), approved))
    }

    @Test("Enqueueing the same item twice requests it once")
    func duplicateEnqueueRequestsOnce() async {
        let queue = makeQueue()
        queue.enqueue([request(first), request(first)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })
        queue.enqueue([request(first)])

        downloader.release(first)
        #expect(await waitUntil { queue.current == nil && queue.pending.isEmpty && downloads.phase(for: first) != .downloading })
        await settle()
        #expect(downloader.requestedIDs == [first])
        downloader.releaseAll()
    }

    @Test("Cancelling a queued item also stops the same item started outside the queue")
    func cancellingQueuedItemStopsOutsideDownload() async {
        let queue = makeQueue()
        queue.enqueue([request(first), request(second)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })
        downloads.download(itemID: second, title: String(second), using: downloader)
        #expect(await waitUntil { downloader.requestedIDs == [first, second] })

        queue.cancel(second)

        #expect(!queue.isQueued(second))
        #expect(!downloads.isBusy(second), "the outside download kept running after its queued request was cancelled")
        downloader.releaseAll()
        #expect(await waitUntil { queue.current == nil && queue.pending.isEmpty })
    }

    @Test("A queued item another entry point already downloaded is not downloaded again")
    func queuedItemFinishedElsewhereIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadQueue-\(UUID().uuidString)", isDirectory: true)
        let suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.WorkshopDownloadQueue")
        let settings = SettingsManager(directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: suite.defaults)
        defer {
            suite.discard()
        }
        let folder = SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(String(second), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"workshopid":"\#(second)","title":"Item","type":"video","file":"video.mp4"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        try Data([0x00]).write(to: folder.appendingPathComponent("video.mp4"))
        downloader.folders[second] = folder
        let downloads = WorkshopDownloadCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() }),
            repositoryCoordinator: WorkshopRepositoryCoordinator(),
            settings: settings,
            toasts: WorkshopToastCenter(),
            cancelSteamCMD: { _ in }
        )
        let queue = WorkshopDownloadQueue(downloads: downloads)

        queue.enqueue([request(first), request(second)])
        #expect(await waitUntil { downloader.requestedIDs == [first] })
        downloads.download(itemID: second, title: String(second), using: downloader)
        #expect(await waitUntil { downloader.requestedIDs == [first, second] })
        downloader.release(second)
        #expect(await waitUntil { downloads.phase(for: second) == .succeeded })

        downloader.release(first)
        #expect(await waitUntil { queue.pending.isEmpty && downloads.phase(for: first) != .downloading })
        await settle()
        #expect(downloader.requestedIDs == [first, second], "the queue downloaded an item that already finished")
        downloader.releaseAll()
        #expect(await waitUntil { queue.current == nil })
        downloads.removeFromHistory(second)
        #expect(!downloads.downloadOrder.contains(second))
        #expect(downloads.phase(for: second) == .succeeded)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path))
        await TestScratch.discard(root, flushing: settings)
    }

    @Test("Queued replacement keeps the approved copy while it waits", arguments: [false, true])
    func queuedReplacementKeepsApproval(copyChanges: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QueuedApproval-\(UUID())", isDirectory: true)
        let suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.QueuedApproval")
        let settings = SettingsManager(directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: suite.defaults)
        let downloads = WorkshopDownloadCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() }),
            repositoryCoordinator: WorkshopRepositoryCoordinator(), settings: settings,
            toasts: WorkshopToastCenter(), cancelSteamCMD: { _ in }
        )
        let queue = WorkshopDownloadQueue(downloads: downloads)
        try await TestScratch.withCleanup {
            queue.cancel(first)
            queue.cancel(second)
            downloader.releaseAll()
            _ = await waitUntil { queue.current == nil && queue.pending.isEmpty }
            await TestScratch.discard(root, flushing: settings)
            suite.discard()
        } operation: {
            @MainActor func recordLocalCopy(_ title: String) throws {
                let folder = root.appendingPathComponent(title, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let origin = try WPEOrigin(
                    workshopID: String(second), title: title, originalType: .video,
                    sourceFolderBookmark: folder.bookmarkData(), cacheRelativePath: nil, previewFileName: nil
                )
                settings.recordWPEImport(WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil))
            }
            try recordLocalCopy("Copy A")
            let approved = try #require(downloads.localCopyToReplace(for: second))
            let remote = SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(String(second), isDirectory: true)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try Data(#"{"workshopid":"\#(second)","title":"Remote","type":"video","file":"video.mp4"}"#.utf8)
                .write(to: remote.appendingPathComponent("project.json"))
            try Data([0]).write(to: remote.appendingPathComponent("video.mp4"))
            downloader.folders[second] = remote
            queue.enqueue([
                request(first),
                .init(itemID: second, title: "Remote", replacesLocalCopy: true, doctor: downloader, approvedReplacement: approved),
            ])
            try #require(await waitUntil { downloader.requestedIDs == [first] })
            if copyChanges {
                try recordLocalCopy("Copy B")
            }
            downloader.release(first)
            if copyChanges {
                try #require(await waitUntil { queue.current == nil && queue.pending.isEmpty })
                guard case let .failed(reason) = downloads.phase(for: second) else {
                    Issue.record("The queued download approved the changed copy")
                    return
                }
                #expect(reason.contains("Copy B"))
                #expect(downloader.requestedIDs == [first])
                #expect(settings.loadGlobalSettings().recentWPEImports.map(\.origin.title) == ["Copy B"])
            } else {
                try #require(await waitUntil { downloader.requestedIDs == [first, second] })
                downloader.release(second)
                try #require(await waitUntil { queue.current == nil && queue.pending.isEmpty })
                #expect(downloads.phase(for: second) == .succeeded)
            }
        }
    }

    @Test("A queued row shows Queued instead of a finished phase's action")
    func queuedRowShowsQueued() {
        for phase: WorkshopDownloadCoordinator.DownloadPhase in [.idle, .failed("x"), .succeeded] {
            #expect(PasteRowCard.downloadStatus(phase: phase, isQueued: true, canDownload: false) == .queued)
        }
        #expect(PasteRowCard.downloadStatus(phase: .failed("x"), isQueued: false, canDownload: true) == .retry(reason: "x"))
        #expect(PasteRowCard.downloadStatus(phase: .downloading, isQueued: true, canDownload: false) == .inProgress(importing: false))
    }
}

@MainActor
private final class GatedDownloader: WorkshopItemDownloading {
    private(set) var requestedIDs: [UInt64] = []
    /// Items imported from these folders once released; others fail.
    var folders: [UInt64: URL] = [:]
    private var gates: [UInt64: CheckedContinuation<Void, Never>] = [:]

    func downloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress _: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        requestedIDs.append(itemID)
        await withCheckedContinuation { gates[itemID] = $0 }
        guard let folder = folders[itemID] else { return .failed(reason: "released by test") }
        return await .imported(onContentReady(folder))
    }

    func release(_ itemID: UInt64) {
        gates.removeValue(forKey: itemID)?.resume()
    }

    func releaseAll() {
        for itemID in Array(gates.keys) {
            release(itemID)
        }
    }
}
#endif
