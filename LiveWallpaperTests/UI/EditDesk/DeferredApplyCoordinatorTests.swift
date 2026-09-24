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
        #expect(try #require(manager.appliedScreens.first) === refreshedScreen)
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

    @Test func dependencyCompletionIsPublishedAfterChainAndKeepsLegacySuccessPhase() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Infrastructure/Workshop/WorkshopDownloadCoordinator.swift")
        let run = try slice(source, from: "var outcome: WorkshopDownloadOutcome?", to: "private func recordProgress(")
        #expect(run.contains("outcome = await fetchDependencies("))
        #expect(run.contains("if attempts[itemID] == attemptID"))
        #expect(run.contains("attempt?.finish(outcome)"))
        // The dependency stage is observable, so the modal keeps a progress bar instead of going blank.
        #expect(run.contains("fetchingDependencies.insert(itemID)"))
        let dependencyFailure = try slice(source, from: "guard report.isFullyResolved else {", to: "// Every dependency arrived")
        #expect(dependencyFailure.contains("return .failed(reason: reason)"))
        #expect(!dependencyFailure.contains("phases["))
        #expect(!dependencyFailure.contains("finish(itemID:"))
        let reimportFailure = try slice(source, from: "guard let entry = await reimportRoot(", to: "private func fetchDependency(")
        #expect(reimportFailure.contains("return .failed(reason: reason)"))
        #expect(reimportFailure.contains("return .succeeded(entry)"))
        let imports = try slice(source, from: "private func finishImport(", to: "private func finish(itemID:")
        #expect(imports.contains("finish(itemID: itemID, title: title, phase: .succeeded)"))
        #expect(imports.contains("return .succeeded(entry)"))
        #expect(imports.contains("return .unsupported(entry)"))
        #expect(
            !imports.contains("case .ready(_, let origin), .unsupported(let origin):"),
            "an item this Mac can't run shares the success card again"
        )
        #expect(imports.contains("finishUnsupported(entry, itemID: itemID, title: title)"))
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

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound ..< source.endIndex))
        return String(source[startRange.lowerBound ..< endRange.lowerBound])
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

    func setSceneWallpaper(descriptor _: SceneDescriptor, origin _: WPEOrigin?, for _: Screen) {
        Issue.record("Unexpected scene route")
    }

    func importWallpaperEngineProject(at _: URL, for _: Screen) async -> ScreenManager.WPEProjectApplyOutcome {
        Issue.record("Unexpected project route")
        return .rejected(reason: "Unexpected route")
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        beginExplicitWallpaperSelection(for: screen)
        appliedEntries.append(entry)
        appliedScreens.append(screen)
        if confirmsImmediately {
            confirm(entry, on: screen)
        }
    }

    func confirm(_ entry: WPEHistoryEntry, on screen: Screen) {
        var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(SceneDescriptor(
            workshopID: entry.origin.workshopID, cacheRelativePath: "42", entryFile: "scene.json", capabilityTier: .imageOnly
        )))
        configuration.wpeOrigin = entry.origin
        configurations[screen.id] = configuration
        NotificationCenter.default.post(
            name: .wallpaperConfigurationDidChange, object: nil, userInfo: ["screenID": screen.id]
        )
    }
}
#endif
