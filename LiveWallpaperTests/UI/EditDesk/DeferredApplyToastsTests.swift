#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Workshop deferred apply toasts")
@MainActor
struct DeferredApplyToastsTests {
    private let screenName = "MPG321CX"

    @Test func settlingStatesKeepTheirDisplayNameTextAndStyle() throws {
        let cases: [(DeferredApplyCoordinator.State, String, EditDeskToastCenter.Toast.Style)] = [
            (
                .finished(ApplyReport(outcome: .applied, exitedSpanMode: false)),
                String(localized: "Applied to \(screenName)", bundle: .appLanguage),
                .success
            ),
            (
                .downloadOnly(.failed(reason: "Offline")),
                String(localized: "The download failed, so nothing was applied to \(screenName).", bundle: .appLanguage),
                .failure
            ),
            (
                .invalidated(.newerSelection),
                String(localized: "\(screenName) changed in the meantime, so the download wasn’t applied.", bundle: .appLanguage),
                .info
            ),
            (
                .invalidated(.screenUnavailable),
                String(localized: "\(screenName) is no longer connected, so the download wasn’t applied.", bundle: .appLanguage),
                .info
            ),
        ]
        for (state, text, style) in cases {
            let messages = try #require(DeferredApplyToasts.messages(for: state, screenName: screenName))
            #expect(messages.count == 1)
            #expect(messages.first?.text == text)
            #expect(messages.first?.text.contains(screenName) == true)
            #expect(messages.first?.style == style)
        }
    }

    @Test func nonToastingStatesReturnNil() {
        let entry = DeferredWallpaperApplying().entry
        let states: [DeferredApplyCoordinator.State] = [
            .waiting, .applying,
            .downloadOnly(.succeeded(entry)),
            .downloadOnly(.succeededAsPreset(baseWorkshopID: "100")),
            .downloadOnly(.cancelled),
            .invalidated(.cancelled), .invalidated(.superseded),
        ]
        for state in states {
            #expect(DeferredApplyToasts.messages(for: state, screenName: screenName) == nil)
        }
    }

    @Test func failedApplyUsesTheFailuresOwnText() throws {
        let failure = DropFailure.sceneImportRejected(reason: "Fixture rejection")
        let report = ApplyReport(outcome: .failed(failure), exitedSpanMode: false)
        let messages = try #require(DeferredApplyToasts.messages(for: .finished(report), screenName: screenName))
        #expect(messages.count == 1)
        #expect(messages.first?.text == failure.toastText)
        #expect(messages.first?.style == .failure)
    }

    @Test func sceneAttemptFailureLeavesTheToastToItsFailureCard() {
        let attempt = ApplyReport(outcome: .prepareFailed(reason: "Fixture", attemptID: UUID()), exitedSpanMode: false)
        #expect(DeferredApplyToasts.messages(for: .finished(attempt), screenName: screenName) == [])
        let other = ApplyReport(outcome: .prepareFailed(reason: "Fixture", attemptID: nil), exitedSpanMode: false)
        #expect(
            DeferredApplyToasts.messages(for: .finished(other), screenName: screenName)
                == [.init(text: "Fixture", style: .failure, persists: true)]
        )
    }

    @Test("A download that did not end up on the chosen display stays until dismissed; a success fades")
    func notAppliedResultsPersist() throws {
        let notApplied: [DeferredApplyCoordinator.State] = [
            .downloadOnly(.failed(reason: "Offline")),
            .invalidated(.newerSelection),
            .invalidated(.screenUnavailable),
            .finished(ApplyReport(outcome: .failed(.applyNotConfirmed), exitedSpanMode: false)),
            .finished(ApplyReport(outcome: .prepareFailed(reason: "Fixture", attemptID: nil), exitedSpanMode: false)),
        ]
        for state in notApplied {
            let messages = try #require(DeferredApplyToasts.messages(for: state, screenName: screenName))
            #expect(messages.last?.persists == true, Comment(rawValue: "\(state)"))
        }
        let applied = ApplyReport(outcome: .applied, exitedSpanMode: false)
        let success = try #require(DeferredApplyToasts.messages(for: .finished(applied), screenName: screenName))
        #expect(success.last?.persists == false)

        // The centre keeps a persistent toast, even an info one, past its usual 1.8s.
        let center = EditDeskToastCenter(now: { Date(timeIntervalSince1970: 0) })
        center.post("Not applied", style: .info, persistent: true)
        center.reap(at: Date(timeIntervalSince1970: 60))
        #expect(center.toasts.count == 1)
    }

    @Test("Result toasts carry the target display, so they open it and replace its failure like the home page's")
    func resultToastsNameTheirDisplay() throws {
        let target: CGDirectDisplayID = 7
        func screenID(of state: DeferredApplyCoordinator.State) throws -> CGDirectDisplayID? {
            try #require(DeferredApplyToasts.messages(for: state, screenName: screenName, screenID: target)).last?.screenID
        }
        #expect(try screenID(of: .finished(ApplyReport(outcome: .applied, exitedSpanMode: false))) == target)
        #expect(try screenID(of: .finished(ApplyReport(outcome: .failed(.applyNotConfirmed), exitedSpanMode: false))) == target)
        #expect(try screenID(of: .downloadOnly(.failed(reason: "Offline"))) == target)
        #expect(try screenID(of: .invalidated(.newerSelection)) == target)
        // Control: a preset changes no display and a disconnected display has nothing to open.
        #expect(try screenID(of: .finished(ApplyReport(outcome: .registeredPreset(name: "Night"), exitedSpanMode: false))) == nil)
        #expect(try screenID(of: .invalidated(.screenUnavailable)) == nil)
        let span = ApplyReport(outcome: .applied, exitedSpanMode: true)
        #expect(try #require(DeferredApplyToasts.messages(for: .finished(span), screenName: screenName, screenID: target)).first?.screenID == nil)
    }

    @Test("A download this Mac can't run says why and where it wasn't applied, and stays")
    func unsupportedDownloadSaysWhyAndWhere() throws {
        let entry = WPEHistoryEntry(origin: WPEOrigin(
            workshopID: "789", title: "Visualizer", originalType: .scene, sourceFolderBookmark: Data([4]),
            cacheRelativePath: nil, previewFileName: nil, resourceLocation: .unsupported, requiresWindowsPlugin: true
        ), importedAt: .distantPast)
        let messages = try #require(
            DeferredApplyToasts.messages(for: .downloadOnly(.unsupported(entry)), screenName: screenName, screenID: 7)
        )
        let reason = String(localized: "This wallpaper only works on Windows", bundle: .appLanguage)
        #expect(messages.count == 1)
        #expect(messages.first?.text == String(
            localized: "Downloaded, but it can't run on this Mac (\(reason)). Not applied to \(screenName).",
            bundle: .appLanguage
        ))
        #expect(messages.first?.style == .failure)
        #expect(messages.first?.persists == true)
        #expect(messages.first?.screenID == 7)
    }

    @Test("With wallpapers turned off, an applied download says it was saved, as the home page does")
    func appliedWhileWallpapersAreOffSaysItWasSaved() throws {
        let report = ApplyReport(outcome: .applied, exitedSpanMode: false)
        let off = try #require(DeferredApplyToasts.messages(for: .finished(report), screenName: screenName, wallpapersOn: false))
        #expect(off.last?.text == ApplyOutcome.appliedText(on: screenName, wallpapersOn: false))
        // Control: with wallpapers on it still says applied.
        let on = try #require(DeferredApplyToasts.messages(for: .finished(report), screenName: screenName, wallpapersOn: true))
        #expect(on.last?.text == ApplyOutcome.appliedText(on: screenName))
    }

    @Test("A registered preset says where it went and that the wallpaper stayed, as the home page does")
    func registeredPresetSaysTheWallpaperDidNotChange() throws {
        let report = ApplyReport(outcome: .registeredPreset(name: "Night sky"), exitedSpanMode: false)
        let messages = try #require(DeferredApplyToasts.messages(for: .finished(report), screenName: screenName))
        #expect(messages.count == 1)
        #expect(messages.first?.text == String(
            localized: "Added “\("Night sky")” to Presets. The wallpaper wasn't changed.", bundle: .appLanguage
        ))
        #expect(messages.first?.style == .info)
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(home.contains("toasts.post(ApplyOutcome.registeredPresetText(name), style: .info)"))
    }

    @Test("A display unplugged before the download landed is named from the ticket, not left blank")
    func unpluggedDisplayIsNamedFromTheTicket() throws {
        let unplugged = DeferredWallpaperApplying.makeScreen(id: 3)
        unplugged.customName = "Studio"
        let target = DeferredApplyCoordinator.Target(screen: unplugged, selectionGeneration: 0)
        let remaining = [DeferredWallpaperApplying.makeScreen(id: 1)]
        let name = DeferredApplyToasts.screenName(for: target, in: remaining)
        let messages = try #require(DeferredApplyToasts.messages(for: .invalidated(.screenUnavailable), screenName: name))
        #expect(messages.first?.text == String(
            localized: "\("Studio") is no longer connected, so the download wasn’t applied.", bundle: .appLanguage
        ))
        // Control: a display still connected is named as it is now.
        let connected = DeferredWallpaperApplying.makeScreen(id: 3)
        connected.customName = "Studio Left"
        #expect(DeferredApplyToasts.screenName(for: target, in: remaining + [connected]) == "Studio Left")
    }

    @Test("A recorded apply's success line carries its undo step, so that one toast offers Undo")
    func appliedLineCarriesItsUndoStep() throws {
        let stepID = UUID()
        let report = ApplyReport(outcome: .applied, exitedSpanMode: true, undoStepID: stepID)
        let messages = try #require(DeferredApplyToasts.messages(for: .finished(report), screenName: screenName))
        #expect(messages.map(\.undoStepID) == [nil, stepID], "only the Applied line may offer Undo")
    }

    @Test func exitingSpanPrependsAnInformationalToast() throws {
        let outcomes: [ApplyOutcome] = [.applied, .failed(.applyNotConfirmed), .registeredPreset(name: "Night sky")]
        for outcome in outcomes {
            let report = ApplyReport(outcome: outcome, exitedSpanMode: true)
            let messages = try #require(DeferredApplyToasts.messages(for: .finished(report), screenName: screenName))
            let withoutSpan = ApplyReport(outcome: outcome, exitedSpanMode: false)
            let outcomeMessages = try #require(DeferredApplyToasts.messages(for: .finished(withoutSpan), screenName: screenName))
            #expect(messages.count == 2)
            #expect(messages.first?.text == String(localized: "Left span mode", bundle: .appLanguage))
            #expect(messages.first?.style == .info)
            #expect(Array(messages.dropFirst()) == outcomeMessages)
        }
    }
}
#endif
