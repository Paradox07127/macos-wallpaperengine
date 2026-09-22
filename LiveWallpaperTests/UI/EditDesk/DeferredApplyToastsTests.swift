#if !LITE_BUILD
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
            .downloadOnly(.unsupported), .downloadOnly(.cancelled),
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

    @Test func registeredPresetKeepsItsNameAndExistingStyle() throws {
        let report = ApplyReport(outcome: .registeredPreset(name: "Night sky"), exitedSpanMode: false)
        let messages = try #require(DeferredApplyToasts.messages(for: .finished(report), screenName: screenName))
        #expect(messages.count == 1)
        #expect(messages.first?.text == "Night sky")
        #expect(messages.first?.style == .failure)
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
