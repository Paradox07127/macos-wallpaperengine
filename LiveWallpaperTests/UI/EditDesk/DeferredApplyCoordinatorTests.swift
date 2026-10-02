#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import Testing

@Suite("Workshop deferred apply", .serialized)
@MainActor
struct DeferredApplyCoordinatorTests {
    private let manager = DeferredWallpaperApplying()

    private func owner(timeout: Duration = .seconds(1)) -> DeferredApplyCoordinator {
        DeferredApplyCoordinator(
            manager: manager,
            router: ApplyRouter(
                manager: manager, bookmarks: BookmarkStore(persistence: DeferredBookmarkPersistence()),
                sceneCapable: true, confirmationTimeout: timeout
            )
        )
    }

    private func target(_ screen: Screen) -> DeferredApplyCoordinator.Target {
        .init(screen: screen, selectionGeneration: manager.beginExplicitWallpaperSelection(for: screen))
    }

    private func doctor() throws -> SteamCMDDoctorService {
        let scratch = try TestScratch.defaultsSuite(prefix: "DeferredApplyCoordinatorTests")
        let doctor = SteamCMDDoctorService(
            defaults: scratch.defaults, operationCoordinator: SteamCMDDoctorOperationCoordinator()
        )
        doctor.username = nil
        return doctor
    }

    @Test func cancellingDownloadInvalidatesIntentWithoutApplying() async throws {
        let downloads = WorkshopDownloadCoordinator(repositoryCoordinator: WorkshopRepositoryCoordinator())
        let attempt = try #require(try downloads.download(itemID: 42, title: "Fixture", using: doctor()))
        let owner = owner()
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        #expect(downloads.isBusy(42))
        downloads.cancel(42)
        await waitUntil { ticket.state != .waiting }
        #expect(attempt.outcome == .cancelled)
        #expect(ticket.state == .invalidated(.cancelled))
        #expect(downloads.phase(for: 42) == .idle)
        #expect(manager.appliedEntries.isEmpty)
    }

    @Test func rootDownloadFailureDoesNotApply() async throws {
        let downloads = WorkshopDownloadCoordinator(repositoryCoordinator: WorkshopRepositoryCoordinator())
        let attempt = try #require(try downloads.download(itemID: 42, title: "Fixture", using: doctor()))
        let owner = owner()
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        await waitUntil { ticket.state != .waiting }
        guard case let .failed(reason)? = attempt.outcome else {
            Issue.record("Expected the unconfigured download to fail")
            return
        }
        #expect(downloads.phase(for: 42) == .failed(reason))
        #expect(ticket.state == .downloadOnly(.failed(reason: reason)))
        #expect(manager.appliedEntries.isEmpty)
    }

    @Test func dependencyFailureDoesNotApply() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        attempt.finish(.failed(reason: "Missing dependency 99"))
        await waitUntil { ticket.state != .waiting }
        #expect(ticket.state == .downloadOnly(.failed(reason: "Missing dependency 99")))
        #expect(manager.appliedEntries.isEmpty)
    }

    @Test func ticketCollectionObservesSettlementAndKeepsTheTicket() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        #expect(owner.tickets[42] === ticket)
        #expect(owner.tickets[42]?.state == .waiting)

        await confirmation("ticket state observed through the collection") { changed in
            withObservationTracking {
                _ = owner.tickets.values.map(\.state)
            } onChange: { @Sendable in
                changed()
            }
            attempt.finish(.failed(reason: "Offline"))
            await waitUntil { ticket.state.isSettled }
        }
        #expect(owner.tickets[42] === ticket)
        #expect(owner.tickets[42]?.state == .downloadOnly(.failed(reason: "Offline")))
        #expect(owner.ticket(for: 42) === ticket)
    }

    @Test func presetCompletionIsObservableWithoutApplying() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        let result = WorkshopDownloadOutcome.succeededAsPreset(baseWorkshopID: "100")
        attempt.finish(result)
        await waitUntil { ticket.state != .waiting }
        #expect(attempt.outcome == result)
        #expect(ticket.state == .downloadOnly(result))
        #expect(manager.appliedEntries.isEmpty)
    }

    @Test func unsupportedCompletionDoesNotApply() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        attempt.finish(.unsupported(manager.entry))
        await waitUntil { ticket.state != .waiting }
        #expect(ticket.state == .downloadOnly(.unsupported(manager.entry)))
        #expect(manager.appliedEntries.isEmpty)
    }

    @Test func changingTargetDuringDownloadAppliesOnlyToLatestScreen() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        #expect(owner.updateTarget(target(manager.second), for: ticket))
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { ticket.state != .waiting && ticket.state != .applying }
        #expect(manager.appliedScreens.map(\.id) == [manager.second.id])
        #expect(ticket.state == .finished(ApplyReport(outcome: .applied, exitedSpanMode: false)))
    }

    @Test func newerExplicitSelectionOnSameScreenInvalidatesIntent() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        manager.beginExplicitWallpaperSelection(for: manager.first)
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { ticket.state != .waiting }
        #expect(ticket.state == .invalidated(.newerSelection))
        #expect(manager.appliedEntries.isEmpty)
    }

    @Test func selectionOnAnotherScreenDoesNotInvalidateIntent() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        manager.beginExplicitWallpaperSelection(for: manager.second)
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { ticket.state != .waiting && ticket.state != .applying }
        #expect(manager.appliedScreens.map(\.id) == [manager.first.id])
    }

    @Test func closingModalTaskDoesNotCancelHostOwnedIntent() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let selectedTarget = target(manager.first)
        let modalTask = Task { owner.submit(attempt: attempt, target: selectedTarget) }
        let ticket = await modalTask.value
        modalTask.cancel()
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { ticket.state != .waiting && ticket.state != .applying }
        #expect(ticket.state == .finished(ApplyReport(outcome: .applied, exitedSpanMode: false)))
        #expect(manager.appliedEntries == [manager.entry])
    }

    @Test func unpluggedScreenInvalidatesIntent() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        manager.screens = [manager.second]
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { ticket.state != .waiting }
        #expect(ticket.state == .invalidated(.screenUnavailable))
        #expect(manager.appliedEntries.isEmpty)
    }

    @Test func successResolvesCurrentScreenAndWaitsForConfigurationConfirmation() async throws {
        let owner = owner()
        manager.confirmsImmediately = false
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let selectedTarget = target(manager.first)
        let ticket = owner.submit(attempt: attempt, target: selectedTarget)
        let refreshedScreen = DeferredWallpaperApplying.makeScreen(id: manager.first.id)
        manager.screens = [refreshedScreen, manager.second]
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { !manager.appliedEntries.isEmpty }
        #expect(ticket.id != attempt.id)
        #expect(ticket.state == .applying)
        #expect(manager.appliedScreens.first === refreshedScreen)
        #expect(manager.appliedEntries == [manager.entry])
        #expect(manager.isCurrentTransition(selectedTarget.selectionGeneration + 1, for: refreshedScreen.id))
        manager.confirm(manager.entry, on: refreshedScreen)
        await waitUntil { ticket.state != .applying }
        #expect(ticket.state == .finished(ApplyReport(outcome: .applied, exitedSpanMode: false)))
        attempt.finish(.succeeded(manager.entry))
        #expect(manager.appliedEntries.count == 1)
    }

    @Test func methodReturnWithoutConfigurationIsNotSuccess() async {
        let owner = owner(timeout: .zero)
        manager.confirmsImmediately = false
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { ticket.state != .waiting && ticket.state != .applying }
        #expect(ticket.state == .finished(ApplyReport(outcome: .failed(.applyNotConfirmed), exitedSpanMode: false)))
        #expect(manager.appliedEntries.count == 1)
    }

    @Test func newIntentForSameAttemptSupersedesOldTicket() async {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let old = owner.submit(attempt: attempt, target: target(manager.first))
        let current = owner.submit(attempt: attempt, target: target(manager.second))
        #expect(old.id != current.id)
        #expect(old.state == .invalidated(.superseded))
        #expect(!owner.updateTarget(target(manager.first), for: old))
        attempt.finish(.succeeded(manager.entry))
        await waitUntil { current.state != .waiting && current.state != .applying }
        #expect(manager.appliedScreens.map(\.id) == [manager.second.id])
    }

    @Test func oldAttemptCannotSatisfyRetryIntent() async {
        let owner = owner()
        let oldAttempt = WorkshopDownloadAttempt(itemID: 42)
        let old = owner.submit(attempt: oldAttempt, target: target(manager.first))
        let retry = WorkshopDownloadAttempt(itemID: 42)
        let current = owner.submit(attempt: retry, target: target(manager.second))
        oldAttempt.finish(.succeeded(manager.entry))
        #expect(old.state == .invalidated(.superseded))
        #expect(current.state == .waiting)
        retry.finish(.succeeded(manager.entry))
        await waitUntil { current.state != .waiting && current.state != .applying }
        #expect(manager.appliedScreens.map(\.id) == [manager.second.id])
    }

    @Test func cancelledAttemptCannotOverwriteResultAndReplaysToLateSubscribers() async {
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let early = attempt.outcomes()
        attempt.finish(.cancelled)
        attempt.finish(.succeeded(manager.entry))
        var earlyResults: [WorkshopDownloadOutcome] = []
        for await result in early {
            earlyResults.append(result)
        }
        var lateResults: [WorkshopDownloadOutcome] = []
        for await result in attempt.outcomes() {
            lateResults.append(result)
        }
        #expect(earlyResults == [.cancelled])
        #expect(lateResults == [.cancelled])
    }

    @Test func downloadReturnsSameActiveAttemptAndNewIdentityAfterCancellation() throws {
        let downloads = WorkshopDownloadCoordinator(repositoryCoordinator: WorkshopRepositoryCoordinator())
        let doctor = try doctor()
        let first = try #require(downloads.download(itemID: 42, title: "Fixture", using: doctor))
        #expect(downloads.activeAttempt(for: 42) === first)
        #expect(downloads.download(itemID: 42, title: "Fixture", using: doctor) === first)
        downloads.cancel(42)
        #expect(downloads.activeAttempt(for: 42) == nil)
        let retry = try #require(downloads.download(itemID: 42, title: "Fixture", using: doctor))
        #expect(first.id != retry.id)
        #expect(first.outcome == .cancelled)
        #expect(retry.outcome == nil)
        downloads.cancel(42)
    }

    @Test("Cancelling the initial import rejects its late ready result before library publication")
    func cancelledInitialImportCannotPublish() async throws {
        let fixture = try DownloadAttemptFixture(name: "cancelledInitialImport", startsWithDependencies: false)
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        let downloads = fixture.downloads
        let attempt = try #require(downloads.download(itemID: 420_000_042, title: "Initial", using: fixture.downloader))
        let task = try #require(downloads.downloadTaskForTesting(itemID: 420_000_042))
        let enteredImport = await fixture.waitForReimport()
        try #require(enteredImport, "\(fixture.diagnostics(for: attempt))")
        #expect(fixture.downloader.requestedIDs == [420_000_042])
        #expect(downloads.phase(for: 420_000_042) == .importing)
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports.isEmpty)

        downloads.cancel(420_000_042)
        fixture.gate.release()
        await task.value

        #expect(attempt.outcome == .cancelled)
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports.isEmpty)
        #expect(fixture.toasts.lastEvent == nil)
        #expect(downloads.phase(for: 420_000_042) == .idle)
        #expect(!downloads.isBusy(420_000_042))
        #expect(downloads.activeAttempt(for: 420_000_042) == nil)
    }

    @Test("Late dependency reimport cannot resurrect a deleted item or overwrite a retry", arguments: [false, true])
    func cancelledDependencyReimportCannotPublish(startRetry: Bool) async throws {
        let fixture = try DownloadAttemptFixture(name: "cancelledReimport-\(startRetry)")
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        let downloads = fixture.downloads
        let first = try #require(downloads.download(itemID: 420_000_042, title: "Old", using: fixture.downloader))
        let oldTask = try #require(downloads.downloadTaskForTesting(itemID: 420_000_042))
        let reachedReimport = await fixture.waitForReimport()
        try #require(reachedReimport, "\(fixture.diagnostics(for: first))")
        #expect(fixture.downloader.requestedIDs == [420_000_042, 990_000_099, 420_000_042])
        #expect(downloads.fetchingDependencies.contains(420_000_042))
        #expect(first.outcome == nil)
        let partial = try #require(fixture.settings.loadGlobalSettings().recentWPEImports.first)
        #expect(partial.origin.missingDependencyIDs == ["990000099"])
        #expect(fixture.toasts.lastEvent == nil)

        downloads.cancel(420_000_042)
        #expect(fixture.settings.removeWPEImport(workshopID: "420000042", matchingImportedAt: partial.importedAt))
        #expect(first.outcome == .cancelled)
        var retry: WorkshopDownloadAttempt?
        if startRetry {
            retry = downloads.download(itemID: 420_000_042, title: "Retry", using: fixture.downloader)
            let retryTask = try #require(downloads.downloadTaskForTesting(itemID: 420_000_042))
            // The cancelled importer still holds the existing repository lock.
            // A retry must retain its own truthful failure, never the old success.
            await retryTask.value
            guard case .failed? = retry?.outcome else {
                Issue.record("The existing repository lock should reject the overlapping mutation")
                fixture.gate.release()
                await oldTask.value
                return
            }
        }
        let phaseBeforeLateResult = downloads.phase(for: 420_000_042)
        let toastBeforeLateResult = fixture.toasts.lastEvent
        let retryOutcome = retry?.outcome
        fixture.gate.release()
        await oldTask.value

        let saved = fixture.settings.loadGlobalSettings()
        #expect(saved.recentWPEImports.isEmpty)
        #expect(saved.deletedWorkshopIDs.contains("420000042"))
        #expect(downloads.phase(for: 420_000_042) == phaseBeforeLateResult)
        #expect(fixture.toasts.lastEvent == toastBeforeLateResult)
        #expect(retry?.outcome == retryOutcome)
        #expect(first.outcome == .cancelled)
        #expect(!downloads.isBusy(420_000_042) && downloads.activeAttempt(for: 420_000_042) == nil)
        #expect(!downloads.fetchingDependencies.contains(420_000_042))
    }

    @Test("A current dependency reimport publishes the resolved library item and success once")
    func currentDependencyReimportPublishes() async throws {
        let fixture = try DownloadAttemptFixture(name: "currentReimport")
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        let attempt = try #require(fixture.downloads.download(itemID: 420_000_042, title: "Current", using: fixture.downloader))
        let task = try #require(fixture.downloads.downloadTaskForTesting(itemID: 420_000_042))
        let reachedReimport = await fixture.waitForReimport()
        try #require(reachedReimport, "\(fixture.diagnostics(for: attempt))")
        #expect(attempt.outcome == nil && fixture.toasts.lastEvent == nil)
        fixture.gate.release()
        await task.value
        guard case let .succeeded(entry)? = attempt.outcome else {
            Issue.record("Expected a resolved dependency import")
            return
        }
        #expect(entry.origin.missingDependencyIDs.isEmpty)
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports == [entry])
        #expect(fixture.downloads.phase(for: 420_000_042) == .succeeded)
        #expect(!fixture.downloads.isBusy(420_000_042))
        #expect(fixture.toasts.lastEvent?.isSuccess == true)
        #expect(fixture.toasts.lastEvent?.token == 1)
    }

    @Test("Downloading an item the library holds from a local copy fails without downloading", .timeLimit(.minutes(1)))
    func downloadOfItemHeldByLocalCopyIsRefused() async throws {
        let fixture = try DownloadAttemptFixture(name: "localCopyConflict", startsWithDependencies: false)
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        try fixture.recordLibraryEntry(in: fixture.root.appendingPathComponent("local/copy", isDirectory: true), title: "Local copy")
        fixture.gate.release()
        let attempt = try #require(fixture.downloads.download(itemID: 420_000_042, title: "Remote", using: fixture.downloader))
        let task = try #require(fixture.downloads.downloadTaskForTesting(itemID: 420_000_042))
        await task.value
        guard case let .failed(reason)? = attempt.outcome else {
            Issue.record("Expected the conflicting download to fail, got \(String(describing: attempt.outcome))")
            return
        }
        #expect(reason.contains("Local copy"))
        #expect(fixture.downloader.requestedIDs.isEmpty)
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports.map(\.origin.title) == ["Local copy"])
        #expect(fixture.toasts.lastEvent?.isSuccess == false)
    }

    @Test("Updating the library's own Steam copy of an item still downloads it", .timeLimit(.minutes(1)))
    func updateOfLibrarySteamCopyDownloads() async throws {
        let fixture = try DownloadAttemptFixture(name: "steamCopyUpdate", startsWithDependencies: false)
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        try fixture.recordLibraryEntry(in: fixture.itemFolder, title: "Steam copy")
        fixture.gate.release()
        let attempt = try #require(fixture.downloads.download(itemID: 420_000_042, title: "Steam copy", using: fixture.downloader))
        let task = try #require(fixture.downloads.downloadTaskForTesting(itemID: 420_000_042))
        await task.value
        guard case .succeeded? = attempt.outcome else {
            Issue.record("Expected the update to succeed, got \(String(describing: attempt.outcome))")
            return
        }
        #expect(fixture.downloader.requestedIDs == [420_000_042])
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports.map(\.origin.title) == ["Initial video"])
    }

    @Test("A local copy imported while the download runs keeps the download out of the library", .timeLimit(.minutes(1)))
    func localCopyImportedMidDownloadBlocksRecording() async throws {
        let fixture = try DownloadAttemptFixture(name: "midDownloadConflict", startsWithDependencies: false)
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        let attempt = try #require(fixture.downloads.download(itemID: 420_000_042, title: "Remote", using: fixture.downloader))
        let task = try #require(fixture.downloads.downloadTaskForTesting(itemID: 420_000_042))
        let enteredImport = await fixture.waitForReimport()
        try #require(enteredImport, "\(fixture.diagnostics(for: attempt))")
        try fixture.recordLibraryEntry(in: fixture.root.appendingPathComponent("local/copy", isDirectory: true), title: "Local copy")
        fixture.gate.release()
        await task.value
        guard case let .failed(reason)? = attempt.outcome else {
            Issue.record("Expected the late conflict to fail the download, got \(String(describing: attempt.outcome))")
            return
        }
        #expect(reason.contains("Local copy"))
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports.map(\.origin.title) == ["Local copy"])
        #expect(fixture.toasts.lastEvent?.isSuccess == false)
    }

    @Test("Downloading over an approved local copy records the Steam item beside it", .timeLimit(.minutes(1)))
    func downloadReplacingApprovedLocalCopyRecordsSteamItem() async throws {
        let fixture = try DownloadAttemptFixture(name: "approvedLocalCopy", startsWithDependencies: false)
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        let local = try fixture.recordLibraryEntry(in: fixture.root.appendingPathComponent("local/copy", isDirectory: true), title: "Local copy")
        fixture.gate.release()
        let attempt = try #require(fixture.downloads.download(itemID: 420_000_042, title: "Remote", using: fixture.downloader, replacing: local))
        let task = try #require(fixture.downloads.downloadTaskForTesting(itemID: 420_000_042))
        await task.value
        guard case .succeeded? = attempt.outcome else {
            Issue.record("Expected the approved download to succeed, got \(String(describing: attempt.outcome))")
            return
        }
        #expect(fixture.downloader.requestedIDs == [420_000_042])
        let history = fixture.settings.loadGlobalSettings().recentWPEImports
        #expect(history.contains { $0.origin.steamFolderItemID == "420000042" })
        #expect(history.contains { $0.origin.title == "Local copy" && $0.origin.steamFolderItemID == nil })
    }

    @Test("Another local copy imported while an approved download runs keeps it out of the library", .timeLimit(.minutes(1)))
    func otherLocalCopyImportedMidApprovedDownloadBlocksRecording() async throws {
        let fixture = try DownloadAttemptFixture(name: "approvedMidDownloadConflict", startsWithDependencies: false)
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        let copyA = try fixture.recordLibraryEntry(in: fixture.root.appendingPathComponent("local/a", isDirectory: true), title: "Copy A")
        let attempt = try #require(fixture.downloads.download(itemID: 420_000_042, title: "Remote", using: fixture.downloader, replacing: copyA))
        let task = try #require(fixture.downloads.downloadTaskForTesting(itemID: 420_000_042))
        let enteredImport = await fixture.waitForReimport()
        try #require(enteredImport, "\(fixture.diagnostics(for: attempt))")
        try fixture.recordLibraryEntry(in: fixture.root.appendingPathComponent("local/b", isDirectory: true), title: "Copy B")
        fixture.gate.release()
        await task.value
        guard case let .failed(reason)? = attempt.outcome else {
            Issue.record("Expected the unapproved copy to fail the download, got \(String(describing: attempt.outcome))")
            return
        }
        #expect(reason.contains("Copy B"))
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports.map(\.origin.title) == ["Copy B"])
        #expect(fixture.toasts.lastEvent?.isSuccess == false)
    }

    @Test("Passing a Steam entry as the replacement does not approve the download", .timeLimit(.minutes(1)))
    func steamEntryAsReplacementIsRefused() async throws {
        let fixture = try DownloadAttemptFixture(name: "steamReplacement", startsWithDependencies: false)
        defer { fixture.gate.release(); await fixture.discard(); fixture.defaults.discard() }
        try fixture.recordLibraryEntry(in: fixture.root.appendingPathComponent("local/copy", isDirectory: true), title: "Local copy")
        let steamEntry = try fixture.libraryEntry(in: fixture.itemFolder, title: "Steam copy")
        try #require(steamEntry.origin.steamFolderItemID == "420000042")
        fixture.gate.release()
        let attempt = try #require(fixture.downloads.download(itemID: 420_000_042, title: "Remote", using: fixture.downloader, replacing: steamEntry))
        let task = try #require(fixture.downloads.downloadTaskForTesting(itemID: 420_000_042))
        await task.value
        guard case let .failed(reason)? = attempt.outcome else {
            Issue.record("Expected the download to stay refused, got \(String(describing: attempt.outcome))")
            return
        }
        #expect(reason.contains("Local copy"))
        #expect(fixture.downloader.requestedIDs.isEmpty)
        #expect(fixture.settings.loadGlobalSettings().recentWPEImports.map(\.origin.title) == ["Local copy"])
    }

    @Test(.timeLimit(.minutes(1)))
    func lookupReturnsTheLiveTicketAndNothingForAnUnknownItem() {
        let owner = owner()
        let attempt = WorkshopDownloadAttempt(itemID: 42)
        let ticket = owner.submit(attempt: attempt, target: target(manager.first))
        #expect(owner.ticket(for: 42) === ticket)
        #expect(owner.ticket(for: 43) == nil)
        #expect(ticket.state == .waiting)
    }

    @Test(.timeLimit(.minutes(1)))
    func lookupKeepsSettledTicketsSoTheirResultStaysOnScreen() async {
        let owner = owner()
        let applied = WorkshopDownloadAttempt(itemID: 42)
        let appliedTicket = owner.submit(attempt: applied, target: target(manager.first))
        applied.finish(.succeeded(manager.entry))
        await waitUntil { appliedTicket.state != .waiting && appliedTicket.state != .applying }
        #expect(appliedTicket.state == .finished(ApplyReport(outcome: .applied, exitedSpanMode: false)))
        #expect(owner.ticket(for: 42) === appliedTicket)

        let unsupported = WorkshopDownloadAttempt(itemID: 43)
        let unsupportedTicket = owner.submit(attempt: unsupported, target: target(manager.second))
        unsupported.finish(.unsupported(manager.entry))
        await waitUntil { unsupportedTicket.state != .waiting }
        #expect(unsupportedTicket.state == .downloadOnly(.unsupported(manager.entry)))
        #expect(owner.ticket(for: 43) === unsupportedTicket)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledTicketIsKeptUntilTheNextSubmitForThatItem() async {
        let owner = owner()
        let cancelled = WorkshopDownloadAttempt(itemID: 42)
        let cancelledTicket = owner.submit(attempt: cancelled, target: target(manager.first))
        owner.cancel(cancelledTicket)
        #expect(cancelledTicket.state == .invalidated(.cancelled))
        #expect(owner.ticket(for: 42) === cancelledTicket)

        let retry = WorkshopDownloadAttempt(itemID: 42)
        let retryTicket = owner.submit(attempt: retry, target: target(manager.second))
        #expect(owner.ticket(for: 42) === retryTicket)
        // The replaced ticket keeps the reason it ended rather than being restamped as superseded.
        #expect(cancelledTicket.state == .invalidated(.cancelled))
        retry.finish(.succeeded(manager.entry))
        await waitUntil { retryTicket.state != .waiting && retryTicket.state != .applying }
        #expect(manager.appliedScreens.map(\.id) == [manager.second.id])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }
}

@MainActor
final class DeferredBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}

private final class DeferredTestNSScreen: NSScreen {
    var displayID: UInt32 = 1
    override var frame: NSRect {
        NSRect(x: CGFloat(displayID) * 800, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Deferred Apply Test"
    }
}

@MainActor
final class DeferredWallpaperApplying: WallpaperApplying, DeferredApplyScreenResolving {
    static func makeScreen(id: CGDirectDisplayID) -> Screen {
        let nsScreen = DeferredTestNSScreen()
        nsScreen.displayID = id
        return Screen(nsScreen: nsScreen)
    }

    let first = DeferredWallpaperApplying.makeScreen(id: 1)
    let second = DeferredWallpaperApplying.makeScreen(id: 2)
    lazy var screens = [first, second]
    private let transitions = PlaybackTransitionRegistry()
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]
    var appliedEntries: [WPEHistoryEntry] = []
    var appliedScreens: [Screen] = []
    var confirmsImmediately = true
    let entry = WPEHistoryEntry(
        origin: WPEOrigin(
            workshopID: "42", title: "Fixture", originalType: .scene,
            sourceFolderBookmark: Data(), cacheRelativePath: "42", previewFileName: nil
        ), importedAt: Date(timeIntervalSince1970: 1)
    )

    @discardableResult
    func beginExplicitWallpaperSelection(for screen: Screen) -> Int {
        transitions.bumpTransition(for: screen.id)
    }

    func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        transitions.isCurrentTransition(generation, for: screenID)
    }

    func screen(withID id: CGDirectDisplayID) -> Screen? {
        screens.first { $0.id == id }
    }

    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurations[screen.id]
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        configurations[screen.id]?.videoDisplayMode = mode
    }

    func applyBookmark(_: WallpaperBookmark, to _: Screen) {
        Issue.record("Unexpected bookmark route")
    }

    func setVideo(url _: URL, bookmarkData _: Data, packageEntryName _: String?, for _: Screen) {
        Issue.record("Unexpected video route")
    }

    func setHTMLWallpaperPreservingConfig(source _: HTMLSource, for _: Screen) {
        Issue.record("Unexpected HTML route")
    }

    func applyScheme(_: ScreenScheme, to _: Screen) {
        Issue.record("Unexpected scheme route")
    }

    func captureCover(forBookmark _: UUID, from _: Screen) {
        Issue.record("Unexpected cover capture")
    }

    func replaceWallpaperQueue(_: [WallpaperQueueEntry], for _: Screen) {}

    func cancelPreparation(for _: Screen) {}

    func isCurrentPreparation(generation _: Int?, attemptID _: UUID?, on _: Screen) -> Bool {
        false
    }

    private var revisions: [CGDirectDisplayID: UInt64] = [:]

    func configurationRevision(for screen: Screen) -> UInt64 {
        revisions[screen.id] ?? 0
    }

    func beginSceneApply(
        descriptor _: SceneDescriptor, origin _: WPEOrigin?, for _: Screen,
        completion: @escaping @MainActor (ApplyOutcome) -> Void
    ) -> RuntimePreparationWork? {
        Issue.record("Unexpected scene route")
        completion(.failed(.applyNotConfirmed))
        return nil
    }

    func importWallpaperEngineProject(at _: URL, for _: Screen) async -> ScreenManager.WPEProjectApplyOutcome {
        Issue.record("Unexpected project route")
        return .rejected(reason: "Unexpected route")
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async -> WallpaperFailureSnapshot? {
        beginExplicitWallpaperSelection(for: screen)
        appliedEntries.append(entry)
        appliedScreens.append(screen)
        if confirmsImmediately {
            confirm(entry, on: screen)
        }
        return nil
    }

    func confirm(_ entry: WPEHistoryEntry, on screen: Screen) {
        var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(SceneDescriptor(
            workshopID: entry.origin.workshopID, cacheRelativePath: "42", entryFile: "scene.json", capabilityTier: .imageOnly
        )))
        configuration.wpeOrigin = entry.origin
        configurations[screen.id] = configuration
        revisions[screen.id, default: 0] += 1
        NotificationCenter.default.post(
            name: .wallpaperConfigurationDidChange, object: nil, userInfo: ["screenID": screen.id]
        )
    }
}

/// Deliberately ignores cancellation like an already-running file/decode operation.
@MainActor
private final class DownloadImportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var released = false

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class DownloadFixtureSource: WorkshopItemDownloading {
    let root: URL
    private(set) var requestedIDs: [UInt64] = []

    init(root: URL) {
        self.root = root
    }

    func downloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress _: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        requestedIDs.append(itemID)
        do {
            let folder = root.appendingPathComponent(String(itemID), isDirectory: true)
            if itemID == 990_000_099 {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(#"{"workshopid":"990000099","type":"application","file":"unused","title":"Dependency"}"#.utf8)
                    .write(to: folder.appendingPathComponent("project.json"))
                // The dependency arrives; the second read now has a playable local
                // payload. Validation is the real importer's controlled await.
                let parent = root.appendingPathComponent("420000042", isDirectory: true)
                try Data(#"{"workshopid":"420000042","type":"video","file":"video.mp4","title":"Resolved"}"#.utf8)
                    .write(to: parent.appendingPathComponent("project.json"))
                try Data([0]).write(to: parent.appendingPathComponent("video.mp4"))
            }
            return await .imported(onContentReady(folder))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}

@MainActor
private final class DownloadAttemptFixture {
    let root: URL
    let defaults: TestScratch.DefaultsSuite
    let settings: SettingsManager
    let toasts: WorkshopToastCenter
    let gate: DownloadImportGate
    let downloader: DownloadFixtureSource
    let downloads: WorkshopDownloadCoordinator

    init(name: String, startsWithDependencies: Bool = true) throws {
        let defaults = try TestScratch.defaultsSuite("DeferredApplyCoordinatorTests.\(name)")
        self.defaults = defaults
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-attempt-\(UUID())", isDirectory: true)
        self.root = root
        let content = SteamLibraryPaths.workshopContentRoot(steamRoot: root)
        let item = content.appendingPathComponent("420000042", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            let manifest = startsWithDependencies
                ? #"{"workshopid":"420000042","title":"Needs dependency","type":"scene","file":"scene.json","dependencies":["990000099"]}"#
                : #"{"workshopid":"420000042","title":"Initial video","type":"video","file":"video.mp4"}"#
            try Data(manifest.utf8).write(to: item.appendingPathComponent("project.json"))
            let project = try WallpaperEngineProject.read(from: item)
            let expectedDependencies = startsWithDependencies ? ["990000099"] : []
            try #require(project.dependencyWorkshopIDs == expectedDependencies, "Fixture must survive the real manifest ID validator")
            if !startsWithDependencies {
                try Data([0]).write(to: item.appendingPathComponent("video.mp4"))
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let settings = SettingsManager(directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: defaults.defaults)
        self.settings = settings
        let toasts = WorkshopToastCenter()
        self.toasts = toasts
        let gate = DownloadImportGate()
        self.gate = gate
        downloader = DownloadFixtureSource(root: content)
        let importer = WallpaperEngineImportService(
            validateVideo: { _ in await gate.wait() },
            makeBookmark: { try? $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        )
        downloads = WorkshopDownloadCoordinator(
            importService: importer, repositoryCoordinator: WorkshopRepositoryCoordinator(),
            settings: settings, toasts: toasts, cancelSteamCMD: { _ in }
        )
    }

    var itemFolder: URL {
        downloader.root.appendingPathComponent("420000042", isDirectory: true)
    }

    func libraryEntry(in folder: URL, title: String) throws -> WPEHistoryEntry {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let origin = try WPEOrigin(
            workshopID: "420000042", title: title, originalType: .video,
            sourceFolderBookmark: #require(ResourceUtilities.createBookmark(for: folder)),
            cacheRelativePath: nil, previewFileName: nil
        )
        return WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
    }

    /// Returns the entry as stored, so it can be handed back as a download's approved replacement.
    @discardableResult
    func recordLibraryEntry(in folder: URL, title: String) throws -> WPEHistoryEntry {
        try settings.recordWPEImport(libraryEntry(in: folder, title: title))
        return try #require(settings.loadGlobalSettings().recentWPEImports.first { $0.origin.title == title })
    }

    func waitForReimport() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while !gate.entered, downloads.isBusy(420_000_042), ContinuousClock.now < deadline {
            await Task.yield()
        }
        return gate.entered
    }

    func diagnostics(for attempt: WorkshopDownloadAttempt) -> String {
        let outcome = switch attempt.outcome {
        case nil: "pending"
        case .succeeded?: "succeeded"
        case .succeededAsPreset?: "preset"
        case .unsupported?: "unsupported"
        case .cancelled?: "cancelled"
        case let .failed(reason)?: "failed: \(reason)"
        }
        let partial = settings.loadGlobalSettings().recentWPEImports.map {
            "\($0.origin.workshopID):missing=\($0.origin.missingDependencyIDs)"
        }
        return "Import gate was not reached: phase=\(downloads.phase(for: 420_000_042)); outcome=\(outcome); requestedIDs=\(downloader.requestedIDs); partialHistory=\(partial)"
    }

    func discard() async {
        await TestScratch.discard(root, flushing: settings)
    }
}

#endif
