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

        // A queued intent keeps offering the same deferred apply; the target can still change.
        #expect(WorkshopModalContent.primaryActionTitle(installed: false, ticketState: .waiting, screenName: screen) == deferred)
        // A settled ticket puts the button back where it started.
        let settled = DeferredApplyCoordinator.State.finished(ApplyReport(outcome: .applied, exitedSpanMode: false))
        #expect(WorkshopModalContent.primaryActionTitle(installed: false, ticketState: settled, screenName: screen) == deferred)
    }

    // MARK: Targets

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
