#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Workshop modal — bottom-bar arithmetic, wording and source shape")
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

    // MARK: Primary button

    @Test("The primary button applies now when the item is in the library and defers otherwise")
    func primaryActionTitleFollowsInstalledStateAndTicket() {
        let screen = "MPG321CX"
        let installed = WorkshopModalContent.primaryActionTitle(installed: true, ticketState: nil, screenName: screen)
        let deferred = WorkshopModalContent.primaryActionTitle(installed: false, ticketState: nil, screenName: screen)
        let applying = WorkshopModalContent.primaryActionTitle(installed: false, ticketState: .applying, screenName: screen)

        #expect(installed.contains(screen))
        #expect(deferred.contains(screen))
        #expect(installed != deferred, "applying now and applying after a download must not read alike")
        #expect(!applying.contains(screen), "while the apply runs the button reports progress, not a target")
        #expect(applying != installed)

        // A queued apply says where it will land; the target can still change and the title follows it.
        let queued = WorkshopModalContent.primaryActionTitle(installed: false, ticketState: .waiting, screenName: screen)
        #expect(queued.contains(screen))
        #expect(queued != deferred, "a queued apply reads like an offer to queue one")
        // A settled ticket puts the button back where it started.
        let settled = DeferredApplyCoordinator.State.finished(ApplyReport(outcome: .applied, exitedSpanMode: false))
        #expect(WorkshopModalContent.primaryActionTitle(installed: false, ticketState: settled, screenName: screen) == deferred)
    }

    @Test("While an apply is queued the second button cancels it; otherwise it only saves")
    func secondaryButtonCancelsTheQueuedApply() {
        let saveOnly = WorkshopModalContent.secondaryActionTitle(ticketState: nil)
        let queued = WorkshopModalContent.secondaryActionTitle(ticketState: .waiting)
        #expect(saveOnly == String(localized: "Save only", bundle: .appLanguage))
        #expect(queued == String(localized: "Cancel Auto-Apply", bundle: .appLanguage))
        #expect(queued != saveOnly)
        let settled = DeferredApplyCoordinator.State.finished(ApplyReport(outcome: .applied, exitedSpanMode: false))
        #expect(WorkshopModalContent.secondaryActionTitle(ticketState: settled) == saveOnly)
    }

    @Test("While the apply runs the second button is off: pressing it would drop the apply halfway")
    func secondaryButtonIsOffWhileTheApplyRuns() {
        #expect(!WorkshopModalContent.isSecondaryEnabled(ticketState: .applying, isBanned: false, isDownloadReady: true))
        // Control: a queued apply stays cancellable without a ready setup, and an idle item follows the download gate.
        #expect(WorkshopModalContent.isSecondaryEnabled(ticketState: .waiting, isBanned: false, isDownloadReady: false))
        #expect(WorkshopModalContent.isSecondaryEnabled(ticketState: nil, isBanned: false, isDownloadReady: true))
        #expect(!WorkshopModalContent.isSecondaryEnabled(ticketState: nil, isBanned: false, isDownloadReady: false))
    }

    @Test("A blocked download names the missing setup step and dims both download buttons")
    func blockedDownloadSaysWhichStepIsMissing() {
        let blocker = "Authorize your Steam library folder first."
        func bar(isInstalled: Bool) -> WorkshopDownloadPresentation {
            WorkshopDownloadPresentation.make(
                ticketState: nil, settledScreenName: "", wallpapersOn: true, phase: .idle, isFetchingDependencies: false,
                fraction: nil, downloadedBytes: nil, totalBytes: nil, bytesPerSecond: nil,
                isInstalled: isInstalled, unsupportedOrigin: nil, blocker: blocker
            )
        }
        #expect(bar(isInstalled: false).status == blocker)
        #expect(!WorkshopModalContent.canDownload(isBanned: false, isDownloadReady: false))
        #expect(WorkshopModalContent.canDownload(isBanned: false, isDownloadReady: true))
        #expect(!WorkshopModalContent.canDownload(isBanned: true, isDownloadReady: true))
        // Control: an item already in the library applies without downloading, so the blocker is not its business.
        #expect(bar(isInstalled: true).status.isEmpty)
    }

    @Test("While required items download the bar keeps an indeterminate bar and says so; an item that can't run says why")
    func dependencyStageKeepsShowingProgress() {
        func bar(
            _ ticketState: DeferredApplyCoordinator.State?, phase: WorkshopDownloadCoordinator.DownloadPhase, fetching: Bool
        ) -> WorkshopDownloadPresentation {
            WorkshopDownloadPresentation.make(
                ticketState: ticketState, settledScreenName: "", wallpapersOn: true, phase: phase,
                isFetchingDependencies: fetching, fraction: nil, downloadedBytes: nil, totalBytes: nil,
                bytesPerSecond: nil, isInstalled: false, unsupportedOrigin: nil, blocker: nil
            )
        }
        let dependencies = bar(.waiting, phase: .importing, fetching: true)
        #expect(dependencies.progress == .indeterminate)
        #expect(dependencies.status == String(localized: "Downloading required items…", bundle: .appLanguage))
        // Control: a finished transfer outside the dependency stage leaves the bar empty.
        #expect(bar(.waiting, phase: .succeeded, fetching: false) == WorkshopDownloadPresentation())

        let entry = WPEHistoryEntry(origin: WPEOrigin(
            workshopID: "789", title: "Visualizer", originalType: .scene, sourceFolderBookmark: Data([4]),
            cacheRelativePath: nil, previewFileName: nil, resourceLocation: .unsupported, requiresWindowsPlugin: true
        ), importedAt: .distantPast)
        let reason = String(localized: "This wallpaper only works on Windows", bundle: .appLanguage)
        let unsupported = bar(.downloadOnly(.unsupported(entry)), phase: .succeeded, fetching: false)
        #expect(unsupported.status == String(localized: "Can't run on this Mac: \(reason)", bundle: .appLanguage))
        #expect(unsupported.isFailure)
    }

    @Test("A later transfer of the same item shows its live progress over the last ticket's result")
    func liveTransferOutranksASettledTicket() {
        let entry = WPEHistoryEntry(origin: WPEOrigin(
            workshopID: "789", title: "Visualizer", originalType: .scene, sourceFolderBookmark: Data([4]),
            cacheRelativePath: nil, previewFileName: nil, resourceLocation: .unsupported, requiresWindowsPlugin: true
        ), importedAt: .distantPast)
        func bar(
            _ ticketState: DeferredApplyCoordinator.State, phase: WorkshopDownloadCoordinator.DownloadPhase, fetching: Bool
        ) -> WorkshopDownloadPresentation {
            WorkshopDownloadPresentation.make(
                ticketState: ticketState, settledScreenName: "", wallpapersOn: true, phase: phase,
                isFetchingDependencies: fetching, fraction: 0.25, downloadedBytes: nil, totalBytes: nil,
                bytesPerSecond: nil, isInstalled: true, unsupportedOrigin: entry.origin, blocker: nil
            )
        }
        let settled = DeferredApplyCoordinator.State.downloadOnly(.unsupported(entry))
        let downloading = bar(settled, phase: .downloading, fetching: false)
        #expect(downloading.progress == .fraction(0.25))
        #expect(downloading.status == String(localized: "Downloading…", bundle: .appLanguage))
        #expect(!downloading.isFailure)
        #expect(bar(settled, phase: .importing, fetching: false).status == String(localized: "Importing…", bundle: .appLanguage))
        #expect(
            bar(settled, phase: .importing, fetching: true).status
                == String(localized: "Downloading required items…", bundle: .appLanguage)
        )
        let applied = DeferredApplyCoordinator.State.finished(ApplyReport(outcome: .applied, exitedSpanMode: false))
        #expect(bar(applied, phase: .downloading, fetching: false).progress == .fraction(0.25))
        // Control: with nothing of the item in flight the bar reports the ticket's result.
        let reason = String(localized: "This wallpaper only works on Windows", bundle: .appLanguage)
        #expect(bar(settled, phase: .succeeded, fetching: false).status == String(localized: "Can't run on this Mac: \(reason)", bundle: .appLanguage))
    }

    @Test("An item already in the library stays installed while it downloads again; its dependency stage does not")
    func libraryEntryStaysInstalledThroughALaterDownload() {
        #expect(WorkshopModalContent.isInstalled(hasLibraryEntry: true, isDownloading: true, isFetchingDependencies: false))
        // Control: this attempt's root joins the library before its parts, so the dependency stage is not installed yet.
        #expect(!WorkshopModalContent.isInstalled(hasLibraryEntry: true, isDownloading: true, isFetchingDependencies: true))
        #expect(WorkshopModalContent.isInstalled(hasLibraryEntry: true, isDownloading: false, isFetchingDependencies: false))
        #expect(!WorkshopModalContent.isInstalled(hasLibraryEntry: false, isDownloading: true, isFetchingDependencies: false))
    }

    // MARK: Targets

    @Test("A reopened modal points at the queued apply's display before the session's own choice")
    func queuedTicketDecidesTheReopenedTarget() {
        let left = ModalActions.Display(id: 1, name: "Left", frame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        let right = ModalActions.Display(id: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let targets = WorkshopModalTargets.make(displays: [left, right], activeOn: [], covers: [:])
        #expect(WorkshopModalTargets.resolvedTarget(selected: nil, queued: 2, in: targets) == 2)
        #expect(WorkshopModalTargets.resolvedTarget(selected: 1, queued: 2, in: targets) == 2)
        // Control: with nothing queued the session's choice wins, then the leftmost display.
        #expect(WorkshopModalTargets.resolvedTarget(selected: 2, queued: nil, in: targets) == 2)
        #expect(WorkshopModalTargets.resolvedTarget(selected: nil, queued: nil, in: targets) == 1)
    }

    @Test("A queued display unplugged mid-download keeps its name and is not swapped for another display")
    func unpluggedQueuedDisplayIsNotSwappedForAnother() {
        let left = ModalActions.Display(id: 1, name: "Left", frame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        let right = ModalActions.Display(id: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let targets = WorkshopModalTargets.make(displays: [left, right], activeOn: [], covers: [:])
        let unplugged = DeferredWallpaperApplying.makeScreen(id: 3)
        unplugged.customName = "Studio"
        let queued = DeferredApplyCoordinator.Target(screen: unplugged, selectionGeneration: 0)

        let resolved = WorkshopModalTargets.resolvedTarget(selected: 1, queued: queued.screenID, in: targets)
        #expect(resolved == nil, "highlighting another display would say the ticket goes there")
        let name = WorkshopModalTargets.targetName(queued: queued, resolved: resolved, in: targets)
        #expect(name == "Studio")
        #expect(WorkshopModalContent.primaryActionTitle(installed: false, ticketState: .waiting, screenName: name).contains("Studio"))

        // Control: a queued display still connected is highlighted and named as the strip shows it.
        let connected = DeferredApplyCoordinator.Target(screen: DeferredWallpaperApplying.makeScreen(id: 2), selectionGeneration: 0)
        #expect(WorkshopModalTargets.resolvedTarget(selected: 1, queued: connected.screenID, in: targets) == 2)
        #expect(WorkshopModalTargets.targetName(queued: connected, resolved: 2, in: targets) == "Right")
    }

    @Test("Targets and the default stay spatially stable when applied state changes")
    func targetsShareTheLibraryModalsOrdering() {
        let left = ModalActions.Display(id: 1, name: "Left", frame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        let right = ModalActions.Display(id: 2, name: "Right", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

        let targets = WorkshopModalTargets.make(displays: [right, left], activeOn: [1], covers: [:])
        #expect(targets.map(\.id) == [1, 2])
        #expect(targets.map(\.shortcutIndex) == [1, 2])
        #expect(targets.first(where: \.isPrimary)?.id == 1)
        #expect(targets.first?.isApplied == true)
        #expect(targets.last?.isApplied == false)
        // The aspect ratio exists so the float strip can size the thumbnail: 16:9 → 149×84, 16:10 → 134×84.
        #expect(FloatLayerGeometry.thumbnailWidth(aspect: targets.last?.aspectRatio ?? 0) == 149)
        #expect(FloatLayerGeometry.thumbnailWidth(aspect: targets.first?.aspectRatio ?? 0) == 134)

        let allBusy = WorkshopModalTargets.make(displays: [left, right], activeOn: [1, 2], covers: [:])
        #expect(allBusy.first(where: \.isPrimary)?.id == 1, "with nowhere free the leftmost display is still the default")
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
        let details = try RepositoryRoot.source(Self.detailsPath)
        #expect(has("var matureReveal: MatureRevealState?", in: details))
        #expect(details.components(separatedBy: "matureReveal: matureReveal").count - 1 >= 2,
                "both the dependencies and the presets section must get the page's reveal state")
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
        #expect(has("matureReveal: matureReveal", in: modal))
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

    @Test("The Workshop modal builds on the shared chrome and spends ⌘n on picking a target")
    func modalUsesTheChromeAndBindsTargetShortcutToSelection() throws {
        let source = try RepositoryRoot.source(Self.modalPath)
        #expect(has("EditDeskModalChrome(", in: source), "the modal does not build on the shared chrome")
        #expect(!has("modalScrim", in: source), "the modal paints its own scrim")
        #expect(!has("ModalGeometry.panelFrame(", in: source), "the modal measures its own panel")
        #expect(has("onTargetShortcut:", in: source))
        // ⌘n picks the display the download will land on; it never applies anything by itself.
        #expect(has("actions.selectTarget(", in: source))
        #expect(!has("applyTo", in: source), "⌘n reaches an apply instead of the target selection")
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
