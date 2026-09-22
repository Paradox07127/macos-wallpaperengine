#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// Source probes rather than view rendering: these are branch-selection facts, and a
/// SwiftUI body cannot be interrogated for which string it chose.
@Suite("Error surfaces name their cause")
struct ErrorReasonSurfaceTests {
    @Test("Keyless browse failure renders the classified error, not a fixed sentence")
    func keylessBrowseFailureNamesItsCause() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")

        let start = try #require(source.range(of: "private func publicSearchFailedState"))
        let body = String(source[start.lowerBound...].prefix(1200))
        #expect(body.contains("verbatimTitle: message(for: error)"))
        // Control: a literal title in this state is exactly the regression.
        #expect(!body.contains("verbatimTitle: String("))

        // The branch has to hand the error over; taking the parameter and
        // ignoring it at the call site would satisfy the checks above alone.
        #expect(source.contains("publicSearchFailedState(error)"))
    }

    @Test("Both browse routes route their error through one mapper")
    func bothBrowseRoutesShareTheMapper() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")

        let keyed = try #require(source.range(of: "private func errorState"))
        let keyedBody = String(source[keyed.lowerBound...].prefix(600))
        #expect(keyedBody.contains("verbatimTitle: message(for: error)"))

        let mapperCount = source.components(separatedBy: "private func message(for").count - 1
        #expect(mapperCount == 1)
    }

    @Test("Onboarding scene import shows the service's own refusal reason")
    func sceneImportShowsRejectionReason() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Onboarding/PickerView.swift")

        #expect(source.contains("case let .rejected(reason):"))
        #expect(!source.contains("case .rejected:\n                    break"))
        #expect(source.contains("} else if let rejection {"))
    }

    @Test("In-app Steam sign-in separates connector, launch and refusal failures")
    func signInSheetSeparatesItsFailures() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/SteamSignInSheet.swift")
        #expect(!source.contains("case .failed, .unavailable, nil:"))
        #expect(source.contains("case nil:"))
        #expect(source.contains("case .unavailable:"))
        #expect(source.contains("case .failed:"))
    }

    @Test("Recognized-but-unusable drops get their own verdicts")
    func dropFailuresSeparateRecognizedCases() throws {
        let failures = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Support/DropFailure.swift")
        #expect(failures.contains("case sceneLibraryDrop"))
        #expect(failures.contains("case sceneUnsupportedInBuild"))
        // The routing, not just the enum.
        let router = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Support/ApplyRouter.swift")
        #expect(router.contains("return .failed(.sceneLibraryDrop)"))
        #expect(router.contains("return .failed(.sceneUnsupportedInBuild)"))
        // And the surface that speaks the verdict to the user.
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(home.contains("toasts.post(failure.toastText, style: .failure)"))
    }

    @Test("A key Valve rejected is not described as stored or ready")
    func rejectedAPIKeyIsNotReportedAsHealthy() throws {
        let settings = try RepositoryRoot.source("LiveWallpaper/Views/Settings/WorkshopAPIKeySection.swift")
        #expect(settings.contains("services.apiKeyRejected"))

        let onboarding = try RepositoryRoot.source("LiveWallpaper/Views/Onboarding/WorkshopSetupStep.swift")
        let start = try #require(onboarding.range(of: "private var apiKeyDetail"))
        let body = String(onboarding[start.lowerBound...].prefix(900))
        #expect(body.contains("services.apiKeyRejected"))
    }

    @Test("Wallpaper failure surfaces render the runtime error, not the word Error")
    func wallpaperFailureSurfacesReadTheSubtitle() throws {
        // Sliced from the branch rather than matched with its whitespace: the
        // assertion is "this branch reads the subtitle", not how it is laid out.
        let header = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/Header.swift")
        let headerBranch = try #require(header.range(of: "case .error:"))
        #expect(String(header[headerBranch.lowerBound...].prefix(500))
            .contains("wallpaperSessionSummary.subtitle"))

        // Anchored on the function: ContentView has three `case .error:`
        // branches and only this one speaks to the reader.
        let content = try RepositoryRoot.source("LiveWallpaper/Views/ContentView.swift")
        let accessibility = try #require(content.range(of: "private func accessibilityValue"))
        #expect(String(content[accessibility.lowerBound...].prefix(600))
            .contains("summary.subtitle"))

        let menuBar = try RepositoryRoot.source("LiveWallpaper/Views/MenuBarContent.swift")
        let start = try #require(menuBar.range(of: "private func displaySource"))
        let body = String(menuBar[start.lowerBound...].prefix(1400))
        let errorBranch = try #require(body.range(of: "summary.activity == .error"))
        let nameBranch = try #require(body.range(of: "currentVideoDisplayName"))
        // Precedence is the fix: below the name lookups it would never fire.
        #expect(errorBranch.lowerBound < nameBranch.lowerBound)
    }
}
#endif
