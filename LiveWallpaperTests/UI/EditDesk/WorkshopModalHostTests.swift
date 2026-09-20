#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The fake already carries both members the wiring asks for; this is the declaration.
extension DeferredWallpaperApplying: WorkshopApplyTargetSelecting {}

@MainActor
private final class FakeWorkshopDownloads {
    private(set) var startCount = 0
    private(set) var cancelledItems: [UInt64] = []
    private var attempts: [UInt64: WorkshopDownloadAttempt] = [:]

    /// Mirrors `WorkshopDownloadCoordinator.download`: a second press while one is in flight hands
    /// back the attempt already running.
    func start(_ itemID: UInt64) -> WorkshopDownloadAttempt? {
        startCount += 1
        if let existing = attempts[itemID] {
            return existing
        }
        let attempt = WorkshopDownloadAttempt(itemID: itemID)
        attempts[itemID] = attempt
        return attempt
    }

    func active(_ itemID: UInt64) -> WorkshopDownloadAttempt? {
        attempts[itemID]
    }

    func cancel(_ itemID: UInt64) {
        cancelledItems.append(itemID)
        attempts.removeValue(forKey: itemID)?.finish(.cancelled)
    }

    var services: WorkshopModalWiring.Downloads {
        .init(start: { [self] in start($0) }, active: { [self] in active($0) }, cancel: { [self] in cancel($0) })
    }
}

@Suite("Workshop modal host — download, defer, retarget and reopen", .serialized)
@MainActor
struct WorkshopModalHostTests {
    private let manager = DeferredWallpaperApplying()
    private let downloads = FakeWorkshopDownloads()

    private func wiring() -> WorkshopModalWiring {
        WorkshopModalWiring(
            downloads: downloads.services,
            deferredApply: DeferredApplyCoordinator(
                manager: manager,
                router: ApplyRouter(
                    manager: manager, bookmarks: BookmarkStore(persistence: DeferredBookmarkPersistence()),
                    sceneCapable: true, confirmationTimeout: .seconds(1)
                )
            ),
            screens: manager
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func applyingAfterDownloadStartsOneDownloadAndOneIntent() async {
        let wiring = wiring()
        let ticket = wiring.applyWhenDownloaded(itemID: 42, to: manager.first.id)
        #expect(ticket != nil)
        #expect(downloads.startCount == 1)
        #expect(ticket?.target.screenID == manager.first.id)
        #expect(ticket?.state == .waiting)
        #expect(manager.isCurrentTransition(ticket?.target.selectionGeneration ?? -1, for: manager.first.id))

        // Pressing again reuses the attempt already in flight rather than starting a second download.
        wiring.applyWhenDownloaded(itemID: 42, to: manager.first.id)
        #expect(downloads.startCount == 1)

        downloads.active(42)?.finish(.succeeded(manager.entry))
        await waitUntil { wiring.ticket(for: 42)?.state.isSettled == true }
        #expect(manager.appliedScreens.map(\.id) == [manager.first.id], "the download must land on exactly one display")
    }

    @Test(.timeLimit(.minutes(1)))
    func retargetingMovesAWaitingIntentAndIsRefusedOnceTheApplyRuns() async {
        let wiring = wiring()
        manager.confirmsImmediately = false
        let ticket = wiring.applyWhenDownloaded(itemID: 42, to: manager.first.id)
        // Someone changes the second display before the retarget, so its counter is ahead of the
        // first's: carrying the old generation over would no longer read as current there.
        manager.beginExplicitWallpaperSelection(for: manager.second)

        #expect(wiring.retarget(itemID: 42, to: manager.second.id))
        #expect(ticket?.target.screenID == manager.second.id)
        #expect(
            manager.isCurrentTransition(ticket?.target.selectionGeneration ?? -1, for: manager.second.id),
            "retargeting must stamp a fresh generation on the display it moved to"
        )

        downloads.active(42)?.finish(.succeeded(manager.entry))
        await waitUntil { ticket?.state == .applying }
        #expect(!wiring.retarget(itemID: 42, to: manager.first.id), "an apply already running cannot change display")
        #expect(ticket?.target.screenID == manager.second.id)
        #expect(manager.appliedScreens.map(\.id) == [manager.second.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func saveOnlyDownloadsWithoutAnIntentAndDropsOneAlreadyQueued() {
        let wiring = wiring()
        wiring.saveOnly(itemID: 42)
        #expect(downloads.startCount == 1)
        #expect(wiring.ticket(for: 42) == nil, "Save only must not queue an apply")

        let ticket = wiring.applyWhenDownloaded(itemID: 42, to: manager.first.id)
        #expect(ticket?.state == .waiting)
        wiring.saveOnly(itemID: 42)
        #expect(ticket?.state == .invalidated(.cancelled), "Save only drops the queued apply")
        #expect(downloads.cancelledItems.isEmpty, "Save only leaves the download running")
        #expect(downloads.active(42) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func reopeningFindsTheLiveIntentAndTheSettledResult() async {
        let wiring = wiring()
        let ticket = wiring.applyWhenDownloaded(itemID: 42, to: manager.first.id)
        #expect(wiring.ticket(for: 42) === ticket, "a reopened modal renders the intent it left behind")
        #expect(wiring.ticket(for: 43) == nil)

        downloads.active(42)?.finish(.succeeded(manager.entry))
        await waitUntil { wiring.ticket(for: 42)?.state.isSettled == true }
        #expect(wiring.ticket(for: 42)?.state == .finished(ApplyReport(outcome: .applied, exitedSpanMode: false)))

        // Cancelling the download after the fact drops the ticket too, and the download with it.
        let retry = wiring.applyWhenDownloaded(itemID: 42, to: manager.second.id)
        wiring.cancelDownload(itemID: 42)
        #expect(retry?.state == .invalidated(.cancelled))
        #expect(downloads.cancelledItems == [42])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }
}
#endif
