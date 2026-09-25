#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Workshop modal — bottom-row state, status line, paging and source shape")
@MainActor
struct WorkshopModalTests {
    private static let detailsPath = "LiveWallpaper/Views/Workshop/WorkshopDetailsContent.swift"
    private static let modalPath = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopModal.swift"
    private static let contractPath = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalContract.swift"
    private static let hostPath = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift"
    private static let inspectorPath = "LiveWallpaper/Views/Workshop/DetailSheet.swift"

    // MARK: Download rate

    @Test("A byte delta over a time delta is a speed; a stalled or rewound counter has none")
    func rateNeedsForwardProgressAndElapsedTime() {
        #expect(WorkshopDownloadPresentation.rate(bytes: 12_000_000, elapsed: 1) == 12_000_000)
        #expect(WorkshopDownloadPresentation.rate(bytes: 6_000_000, elapsed: 0.5) == 12_000_000)
        #expect(WorkshopDownloadPresentation.rate(bytes: 0, elapsed: 1) == nil)
        #expect(WorkshopDownloadPresentation.rate(bytes: -10, elapsed: 1) == nil)
        #expect(WorkshopDownloadPresentation.rate(bytes: 10, elapsed: 0) == nil)
    }

    @Test("The meter differences successive totals and starts over when the attempt changes")
    func meterDifferencesWithinOneAttemptOnly() {
        let first = UUID()
        let second = UUID()
        let start = Date(timeIntervalSince1970: 0)
        var meter = WorkshopDownloadRateMeter()

        meter.record(attemptID: first, downloadedBytes: 1_000_000, at: start)
        #expect(meter.bytesPerSecond == nil, "a single sample cannot be a speed")

        meter.record(attemptID: first, downloadedBytes: 3_000_000, at: start.addingTimeInterval(2))
        #expect(meter.bytesPerSecond == 1_000_000)

        meter.record(attemptID: second, downloadedBytes: 500_000, at: start.addingTimeInterval(3))
        #expect(meter.bytesPerSecond == nil, "a retry restarts the byte counter, so the old sample is not a delta")

        meter.record(attemptID: second, downloadedBytes: 1_500_000, at: start.addingTimeInterval(4))
        #expect(meter.bytesPerSecond == 1_000_000)

        meter.record(attemptID: nil, downloadedBytes: nil, at: start.addingTimeInterval(5))
        #expect(meter.bytesPerSecond == nil, "no attempt means no speed to show")
    }

    // MARK: Bottom row

    private let left = ModalActions.Display(id: 1, name: "Left", frame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
    private let right = ModalActions.Display(id: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let far = ModalActions.Display(id: 3, name: "Far", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))

    /// `extra` adds displays to the right of the two every row has.
    private func row(
        installed: Bool = false, canRun: Bool = true, ticket: DeferredApplyCoordinator.State? = nil,
        queued: CGDirectDisplayID? = nil, banned: Bool = false, ready: Bool = true, busy: Bool = false,
        activeOn: Set<CGDirectDisplayID> = [], extra: [ModalActions.Display] = []
    ) -> WorkshopModalButtonRow {
        WorkshopModalButtonRow.make(
            targets: WorkshopModalTargets.make(displays: [left, right] + extra, activeOn: activeOn),
            isInstalled: installed, canRun: canRun, ticketState: ticket, queuedScreenID: queued,
            isBanned: banned, isDownloadReady: ready, isBusy: busy
        )
    }

    private func pressable(_ row: WorkshopModalButtonRow) -> [CGDirectDisplayID] {
        row.targets.filter { ModalDisplayButtons.isEnabled($0, canApply: row.canPress, mode: row.mode) }.map(\.id)
    }

    private func preparing(_ row: WorkshopModalButtonRow) -> [CGDirectDisplayID] {
        row.targets.filter(\.isPreparing).map(\.id)
    }

    private func leading(_ row: WorkshopModalButtonRow) -> CGDirectDisplayID? {
        row.targets.first(where: \.isPrimary)?.id
    }

    /// The buttons as the row draws them, left to right, and what goes under Other Displays.
    private func layout(_ row: WorkshopModalButtonRow) -> (buttons: [CGDirectDisplayID], menu: [CGDirectDisplayID]) {
        let split = ModalGeometry.applyButtons(targets: row.targets)
        return ((split.primary.map { [$0] } ?? []).map(\.id) + split.secondary.map(\.id), split.overflow.map(\.id))
    }

    @Test("An item not in the library offers download buttons and Save only; a queued display spins in place")
    func downloadRowFollowsTheQueue() {
        let idle = row()
        #expect(idle.mode == .download)
        #expect(pressable(idle) == [1, 2])
        #expect(preparing(idle).isEmpty)
        #expect(leading(idle) == 1, "with nothing queued the leftmost display leads")
        #expect(idle.extras == [.init(kind: .saveOnly)])

        let queued = row(ticket: .waiting, queued: 2, busy: true)
        #expect(leading(queued) == nil, "a queued display that took the lead would move another one under the pointer")
        #expect(layout(queued).buttons == [1, 2])
        #expect(layout(queued).menu.isEmpty)
        #expect(preparing(queued) == [2])
        #expect(pressable(queued) == [1], "the queued display is taken; the other one moves the apply there")
        #expect(queued.extras == [.init(kind: .cancelAutoApply), .init(kind: .cancelDownload)])

        // After Save only the download runs with no display queued, and a display can still be queued onto it.
        let saving = row(busy: true)
        #expect(pressable(saving) == [1, 2])
        #expect(saving.extras == [.init(kind: .cancelDownload)])
    }

    @Test("While the apply runs, or a setup step or Steam blocks the download, no display can be pressed")
    func blockedRowsPressNothing() {
        let applying = row(ticket: .applying, queued: 2)
        #expect(leading(applying) == nil)
        #expect(pressable(applying).isEmpty)
        #expect(preparing(applying) == [2])
        #expect(applying.extras.isEmpty, "cancelling now would drop the apply halfway")

        let blocked = row(ready: false)
        #expect(pressable(blocked).isEmpty)
        #expect(blocked.extras == [.init(kind: .saveOnly, isEnabled: false), .init(kind: .connectSteam)])

        let banned = row(banned: true)
        #expect(pressable(banned).isEmpty)
        #expect(banned.extras == [.init(kind: .saveOnly, isEnabled: false)])
    }

    @Test("An item in the library applies at once and ticks its display; a copy this Mac can't run greys them all")
    func installedRowApplies() {
        let installed = row(installed: true, activeOn: [1])
        #expect(installed.mode == .apply)
        #expect(pressable(installed) == [1, 2])
        #expect(installed.targets.filter(\.isApplied).map(\.id) == [1])
        #expect(installed.extras.isEmpty)
        #expect(pressable(row(installed: true, canRun: false)).isEmpty)
        // A later download of it, such as an update, can still be stopped.
        #expect(row(installed: true, busy: true).extras == [.init(kind: .cancelDownload)])
    }

    @Test("Three displays with the last one queued stay three buttons in ⌘ order, none of them under Other Displays")
    func queuedRowKeepsEveryButtonInPlace() {
        let queued = row(ticket: .waiting, queued: 3, busy: true, extra: [far])
        #expect(leading(queued) == nil)
        #expect(layout(queued).buttons == [1, 2, 3])
        #expect(layout(queued).menu.isEmpty, "the queued display fell into Other Displays")
        #expect(preparing(queued) == [3])
        // Control: with nothing queued the leftmost display leads and the other two follow it.
        #expect(leading(row(extra: [far])) == 1)
        #expect(layout(row(extra: [far])).buttons == [1, 2, 3])
    }

    @Test("A queued display unplugged mid-download is not swapped for another display, and the status line keeps its name")
    func unpluggedQueuedDisplayIsNotSwappedForAnother() {
        let unplugged = row(ticket: .waiting, queued: 3, busy: true)
        #expect(leading(unplugged) == nil, "leading with another display would say the ticket goes there")
        #expect(preparing(unplugged).isEmpty)
        #expect(pressable(unplugged) == [1, 2])
        let name = "Studio"
        #expect(presentation(.waiting, phase: .downloading, screenName: name).status
            == String(localized: "Will apply to \(name) when done", bundle: .appLanguage))
    }

    @Test("Pressing a display applies an installed item now, moves a queued apply, and otherwise downloads first")
    func pressFollowsTheInstalledStateAndTicket() {
        #expect(WorkshopModalPress.action(isInstalled: true, ticketState: nil) == .applyNow)
        #expect(WorkshopModalPress.action(isInstalled: false, ticketState: .waiting) == .retarget)
        #expect(WorkshopModalPress.action(isInstalled: false, ticketState: nil) == .applyWhenDownloaded)
        let settled = DeferredApplyCoordinator.State.finished(ApplyReport(outcome: .applied, exitedSpanMode: false))
        #expect(WorkshopModalPress.action(isInstalled: false, ticketState: settled) == .applyWhenDownloaded)
        #expect(WorkshopModalPress.action(isInstalled: false, ticketState: .applying) == .ignore)
        #expect(WorkshopModalPress.action(isInstalled: true, ticketState: .applying) == .ignore)
    }

    @Test("Targets and the default stay spatially stable when applied state changes")
    func targetsShareTheLibraryModalsOrdering() {
        let targets = WorkshopModalTargets.make(displays: [right, left], activeOn: [1])
        #expect(targets.map(\.id) == [1, 2])
        #expect(targets.map(\.shortcutIndex) == [1, 2])
        #expect(targets.first(where: \.isPrimary)?.id == 1)
        #expect(targets.first?.isApplied == true)
        #expect(targets.last?.isApplied == false)

        let allBusy = WorkshopModalTargets.make(displays: [left, right], activeOn: [1, 2])
        #expect(allBusy.first(where: \.isPrimary)?.id == 1, "with nowhere free the leftmost display is still the default")
    }

    // MARK: Status line

    private func presentation(
        _ ticketState: DeferredApplyCoordinator.State?, phase: WorkshopDownloadCoordinator.DownloadPhase,
        fetching: Bool = false, fraction: Double? = nil, installed: Bool = false, screenName: String = "",
        blocker: String? = nil
    ) -> WorkshopDownloadPresentation {
        WorkshopDownloadPresentation.make(
            ticketState: ticketState, screenName: screenName, wallpapersOn: true, phase: phase,
            isFetchingDependencies: fetching, fraction: fraction, downloadedBytes: nil, totalBytes: nil,
            bytesPerSecond: nil, isInstalled: installed, blocker: blocker
        )
    }

    @Test("A download with an apply queued says where it will land; without one it only downloads")
    func queuedDownloadNamesItsDisplay() {
        let name = "Studio"
        let queued = presentation(.waiting, phase: .downloading, fraction: 0.42, screenName: name)
        #expect(queued.status == String(localized: "Will apply to \(name) when done", bundle: .appLanguage))
        #expect(queued.progress == .fraction(0.42))
        #expect(queued.detail.hasPrefix("42%"), Comment(rawValue: queued.detail))
        // Control: the same transfer with nothing queued.
        let plain = presentation(nil, phase: .downloading, fraction: 0.42, screenName: name)
        #expect(plain.status == String(localized: "Downloading…", bundle: .appLanguage))
    }

    @Test("A download saved without an apply reports the library; a preset, a gone entry or a queued apply does not")
    func savedDownloadReportsTheLibrary() {
        let added = String(localized: "Added to your library.", bundle: .appLanguage)
        let saved = presentation(nil, phase: .succeeded, installed: true)
        #expect(saved.status == added)
        #expect(!saved.isFailure)
        #expect(presentation(.invalidated(.cancelled), phase: .succeeded, installed: true).status == added, "Cancel Auto-Apply keeps the download")
        #expect(presentation(nil, phase: .succeededAsPreset(baseWorkshopID: "1")).status.isEmpty)
        #expect(presentation(nil, phase: .succeeded, installed: false).status.isEmpty)
        #expect(presentation(.waiting, phase: .succeeded, installed: true).status.isEmpty)
    }

    @Test("A blocked download names the missing setup step and dims both download buttons")
    func blockedDownloadSaysWhichStepIsMissing() {
        let blocker = "Authorize your Steam library folder first."
        #expect(presentation(nil, phase: .idle, installed: false, blocker: blocker).status == blocker)
        #expect(!WorkshopModalContent.canDownload(isBanned: false, isDownloadReady: false))
        #expect(WorkshopModalContent.canDownload(isBanned: false, isDownloadReady: true))
        #expect(!WorkshopModalContent.canDownload(isBanned: true, isDownloadReady: true))
        // Control: an item already in the library applies without downloading, so the blocker is not its business.
        #expect(presentation(nil, phase: .idle, installed: true, blocker: blocker).status.isEmpty)
    }

    @Test("While required items download the line keeps an indeterminate bar and says so; an item that can't run leaves it to the notice")
    func dependencyStageKeepsShowingProgress() {
        let dependencies = presentation(.waiting, phase: .importing, fetching: true)
        #expect(dependencies.progress == .indeterminate)
        #expect(dependencies.status == String(localized: "Downloading required items…", bundle: .appLanguage))
        // Control: a finished transfer outside the dependency stage leaves the line empty.
        #expect(presentation(.waiting, phase: .succeeded) == WorkshopDownloadPresentation())

        let entry = WPEHistoryEntry(origin: WPEOrigin(
            workshopID: "789", title: "Visualizer", originalType: .scene, sourceFolderBookmark: Data([4]),
            cacheRelativePath: nil, previewFileName: nil, resourceLocation: .unsupported, requiresWindowsPlugin: true
        ), importedAt: .distantPast)
        let unsupported = presentation(.downloadOnly(.unsupported(entry)), phase: .succeeded, installed: true)
        #expect(unsupported == WorkshopDownloadPresentation(), "the right column's notice already says why this Mac can't run it")
    }

    @Test("A later transfer of the same item shows its live progress over the last ticket's result")
    func liveTransferOutranksASettledTicket() {
        let settled = DeferredApplyCoordinator.State.downloadOnly(.failed(reason: "Offline"))
        let downloading = presentation(settled, phase: .downloading, fraction: 0.25, installed: true)
        #expect(downloading.progress == .fraction(0.25))
        #expect(downloading.status == String(localized: "Downloading…", bundle: .appLanguage))
        #expect(!downloading.isFailure)
        #expect(presentation(settled, phase: .importing, installed: true).status == String(localized: "Importing…", bundle: .appLanguage))
        #expect(
            presentation(settled, phase: .importing, fetching: true, installed: true).status
                == String(localized: "Downloading required items…", bundle: .appLanguage)
        )
        let applied = DeferredApplyCoordinator.State.finished(ApplyReport(outcome: .applied, exitedSpanMode: false))
        #expect(presentation(applied, phase: .downloading, fraction: 0.25, installed: true).progress == .fraction(0.25))
        // Control: with nothing of the item in flight the line reports the ticket's result.
        let result = presentation(settled, phase: .succeeded, installed: true)
        #expect(result.status == "Offline")
        #expect(result.isFailure)
    }

    @Test("An item already in the library stays installed while it downloads again; its dependency stage does not")
    func libraryEntryStaysInstalledThroughALaterDownload() {
        #expect(WorkshopModalContent.isInstalled(hasLibraryEntry: true, isDownloading: true, isFetchingDependencies: false))
        // Control: this attempt's root joins the library before its parts, so the dependency stage is not installed yet.
        #expect(!WorkshopModalContent.isInstalled(hasLibraryEntry: true, isDownloading: true, isFetchingDependencies: true))
        #expect(WorkshopModalContent.isInstalled(hasLibraryEntry: true, isDownloading: false, isFetchingDependencies: false))
        #expect(!WorkshopModalContent.isInstalled(hasLibraryEntry: false, isDownloading: true, isFetchingDependencies: false))
    }

    // MARK: Paging and rows

    @Test("← → walk the loaded page and stop at its ends; an item opened from outside it has neither")
    func pagingStaysOnTheLoadedPage() {
        let page: [UInt64] = [10, 20, 30]
        let middle = WorkshopModalPaging.neighbours(of: 20, in: page)
        #expect(middle.previous == 10 && middle.next == 30)
        let first = WorkshopModalPaging.neighbours(of: 10, in: page)
        #expect(first.previous == nil && first.next == 20)
        let last = WorkshopModalPaging.neighbours(of: 30, in: page)
        #expect(last.previous == 20 && last.next == nil)
        // A required item opened from the right column is not on the page.
        let outside = WorkshopModalPaging.neighbours(of: 99, in: page)
        #expect(outside.previous == nil && outside.next == nil)
    }

    private func item(posted: Date) throws -> WorkshopQueryItem {
        try WorkshopQueryItem(
            id: 42, rawTitle: "Rain", shortDescription: "", creatorID: "76561198000000000", creatorPersonaName: "kaze",
            previewImageURL: nil, fileSizeBytes: 95_500_000, timeUpdated: posted,
            subscriptionCount: 2900, viewCount: 1300, favoriteCount: 134,
            rating: .score(0.68, votesUp: 36, votesDown: 17), timeCreated: posted, tags: ["Scene", "3840 x 2160"],
            visibility: .public, isBanned: false,
            steamCommunityURL: #require(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=42"))
        )
    }

    @Test("The rows are Steam's plus the day an installed copy arrived, dated in the language handed in")
    func factsAddTheImportDateInTheGivenLocale() throws {
        let day = try #require(Calendar(identifier: .gregorian).date(
            from: DateComponents(timeZone: .current, year: 2026, month: 9, day: 19, hour: 12)
        ))
        let item = try item(posted: day)
        let english = WorkshopModalContent.facts(item: item, importedAt: day, now: day, locale: Locale(identifier: "en_US"))
        #expect(english.map(\.kind) == [.type, .author, .rating, .size, .resolution, .stats, .posted, .imported])
        #expect(english.first { $0.kind == .imported }?.value == "Sep 19, 2026")
        #expect(english.first { $0.kind == .posted }?.value == "Sep 19, 2026")
        let chinese = WorkshopModalContent.facts(item: item, importedAt: day, now: day, locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.first { $0.kind == .imported }?.value == "2026年9月19日")
        // Control: an item not in the library has no import row.
        let online = WorkshopModalContent.facts(item: item, importedAt: nil, now: day, locale: Locale(identifier: "en_US"))
        #expect(!online.contains { $0.kind == .imported })
    }

    // MARK: Source contract

    /// `#expect(source.contains(…))` prints the whole file when it fails; this keeps a miss to one line.
    private func has(_ needle: String, in source: String) -> Bool {
        source.contains(needle)
    }

    @Test("The shared details column has no hero, no scroll view, no download control and no mature gate")
    func detailsColumnIsBodyOnly() throws {
        let source = try RepositoryRoot.source(Self.detailsPath)
        #expect(!has("ScrollView", in: source), "the shared column scrolls itself instead of letting its host do it")
        #expect(!has("AnimatedGIFThumbnail", in: source), "the shared column draws its own hero")
        #expect(!has("downloadButton", in: source), "the shared column owns a download control")
        #expect(!has("MatureContentSettings", in: source), "the shared column carries its own mature gate")
        #expect(has("WorkshopDetailIdentityHeader(", in: source))
        #expect(has("DetailRequiredItemsSection(", in: source))
        #expect(has("DetailPresetsSection(", in: source))
        #expect(has("CollapsibleDescription(", in: source))
    }

    /// R-24 ④: one reveal set for the card, the hero, the dependency rows and the preset rows.
    @Test("Dependencies and presets read the page's reveal state when the host hands them one")
    func theWholeColumnSharesOneRevealSet() throws {
        for path in [
            "LiveWallpaper/Views/Workshop/DetailRequiredItemsSection.swift",
            "LiveWallpaper/Views/Workshop/DetailPresetsSection.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(has("var matureReveal: MatureRevealState?", in: source), Comment(rawValue: path))
            #expect(has("matureReveal?.isRevealed(", in: source), Comment(rawValue: path))
            // nil keeps the old inspector on its own ephemeral set.
            #expect(has("@State private var revealedIDs", in: source), Comment(rawValue: path))
        }
        let modal = try RepositoryRoot.source(Self.modalPath)
        #expect(modal.components(separatedBy: "matureReveal: matureReveal").count - 1 >= 2,
                "both the dependencies and the presets section must get the page's reveal state")
        let host = try RepositoryRoot.source(Self.hostPath)
        #expect(has("matureReveal: session.matureReveal", in: host))
    }

    @Test("The Workshop inspector draws the shared column rather than a second copy of it")
    func inspectorReusesTheSharedColumn() throws {
        let source = try RepositoryRoot.source(Self.inspectorPath)
        #expect(has("WorkshopDetailsContent(", in: source))
        #expect(!has("DetailRequiredItemsSection(", in: source), "the inspector still builds the required-items block itself")
        #expect(!has("DetailPresetsSection(", in: source), "the inspector still builds the presets block itself")
        // The hero, the scroll view and the download control stay behind in the inspector.
        #expect(has("AnimatedGIFThumbnail(", in: source))
        #expect(has("downloadButton", in: source))
    }

    @Test("The Workshop modal builds on the library modal's chrome, layout and buttons, and ⌘n presses a display's button")
    func modalSharesTheLibraryLayout() throws {
        let source = try RepositoryRoot.source(Self.modalPath)
        #expect(has("EditDeskModalChrome(", in: source), "the modal does not build on the shared chrome")
        #expect(has("WallpaperDetailLayout(", in: source), "the modal lays itself out instead of using the shared layout")
        #expect(has("ModalDisplayButtons(", in: source), "the modal draws its own bottom buttons")
        #expect(!has("WorkshopDetailsContent(", in: source), "the modal still draws the inspector's column")
        #expect(has("collapsedLineLimit: 4", in: source), "the description is not cut to four lines")
        #expect(!has("modalScrim", in: source), "the modal paints its own scrim")
        #expect(!has("ModalGeometry.panelFrame(", in: source), "the modal measures its own panel")
        #expect(has("onTargetShortcut:", in: source))
        #expect(has("actions.press(", in: source), "⌘n does not press the display's button")
        #expect(!has("selectTarget", in: source), "⌘n still only picks the display a download lands on")
    }

    @Test("The host pages the loaded items, routes a press through the one decision and dates rows in the app's language")
    func hostRoutesThroughTheContract() throws {
        let host = try RepositoryRoot.source(Self.hostPath)
        #expect(has("WorkshopModalPaging.neighbours(", in: host), "← → do not walk the loaded page")
        #expect(has("WorkshopModalPress.action(", in: host), "a press does not go through the one decision")
        #expect(has("WorkshopModalButtonRow.make(", in: host))
        #expect(has("locale: AppLanguagePreference.current.locale", in: host), "the rows are dated in the system's language, not the app's")
    }

    @Test("No token-bypass literals in the files this package adds")
    func noTokenBypassLiterals() throws {
        for path in [Self.detailsPath, Self.modalPath, Self.contractPath, Self.hostPath] {
            let source = try RepositoryRoot.source(path)
            #expect(!has(".font(.system(", in: source), "\(path) has an inline .font(.system( literal")
            #expect(!has("Color(red:", in: source), "\(path) has a literal Color(red:")
            #expect(
                source.range(of: #"cornerRadius:\s*[0-9]"#, options: .regularExpression) == nil,
                "\(path) has a literal cornerRadius"
            )
        }
    }
}
#endif
