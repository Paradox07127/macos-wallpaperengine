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
}

@MainActor
private final class GatedDownloader: WorkshopItemDownloading {
    private(set) var requestedIDs: [UInt64] = []
    private var gates: [UInt64: CheckedContinuation<Void, Never>] = [:]

    func downloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress _: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady _: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        requestedIDs.append(itemID)
        await withCheckedContinuation { gates[itemID] = $0 }
        return .failed(reason: "released by test")
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
