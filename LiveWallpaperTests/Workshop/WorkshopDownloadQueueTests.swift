#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
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
        await TestScratch.discard(root, flushing: settings)
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
