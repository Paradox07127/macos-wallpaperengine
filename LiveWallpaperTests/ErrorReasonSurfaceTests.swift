#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// Source-level guards on failure surfaces that have a classified cause in
/// hand. The defect class these pin down is one-way: the call site knows which
/// of several failures happened, and the view collapses them into a single
/// fixed sentence, so "blocked host", "timed out" and "HTTP 403" all read the
/// same and none of them tells the reader what to do next.
///
/// Source probes rather than view rendering: these are branch-selection facts,
/// and a SwiftUI body cannot be interrogated for which string it chose.
@Suite("Error surfaces name their cause")
struct ErrorReasonSurfaceTests {
    /// The keyless browse route is the one that actually fails for readers
    /// whose network cannot reach the public Workshop page, and it was the one
    /// discarding `viewModel.lastError` while the keyed route reported it.
    @Test("Keyless browse failure renders the classified error, not a fixed sentence")
    func keylessBrowseFailureNamesItsCause() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")

        let start = try #require(source.range(of: "private func publicSearchFailedState"))
        let body = String(source[start.lowerBound...].prefix(1200))
        // The title comes from the shared error mapper, so every case the
        // fetch can classify reaches the reader.
        #expect(body.contains("verbatimTitle: message(for: error)"))
        // Control: a literal title in this state is exactly the regression.
        #expect(!body.contains("verbatimTitle: String("))

        // The branch has to hand the error over; taking the parameter and
        // ignoring it at the call site would satisfy the checks above alone.
        #expect(source.contains("publicSearchFailedState(error)"))
    }

    /// Both browse routes report the same failure the same way. They diverged
    /// once already, which is how the keyless side went a release naming no
    /// cause at all.
    @Test("Both browse routes route their error through one mapper")
    func bothBrowseRoutesShareTheMapper() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")

        let keyed = try #require(source.range(of: "private func errorState"))
        let keyedBody = String(source[keyed.lowerBound...].prefix(600))
        #expect(keyedBody.contains("verbatimTitle: message(for: error)"))

        // One mapper, so a new `WorkshopQueryError` case cannot be worded for
        // one route and left generic on the other.
        let mapperCount = source.components(separatedBy: "private func message(for").count - 1
        #expect(mapperCount == 1)
    }

    /// The import service localizes a sentence for each way it can refuse a
    /// project. Onboarding bound none of it, so a missing entry file and a
    /// bookmark macOS would not grant both read "try another folder".
    @Test("Onboarding scene import shows the service's own refusal reason")
    func sceneImportShowsRejectionReason() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Onboarding/PickerView.swift")

        // Binding the payload is the whole fix; `case .rejected:` discards it.
        #expect(source.contains("case let .rejected(reason):"))
        #expect(!source.contains("case .rejected:\n                    break"))
        // And the bound reason has to reach the failure line, not just a var.
        #expect(source.contains("} else if let rejection {"))
    }

    /// A reply that never came, a SteamCMD that would not launch and a refusal
    /// from Steam are three different problems with three different remedies.
    @Test("In-app Steam sign-in separates connector, launch and refusal failures")
    func signInSheetSeparatesItsFailures() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/SteamSignInSheet.swift")
        #expect(!source.contains("case .failed, .unavailable, nil:"))
        #expect(source.contains("case nil:"))
        #expect(source.contains("case .unavailable:"))
        #expect(source.contains("case .failed:"))
    }

    /// A scene library and a scene this build cannot render are both
    /// recognized; reporting them as an unsupported file sent the reader off
    /// to find a different file, which was never the problem.
    @Test("Recognized-but-unusable drops get their own verdicts")
    func dropFailuresSeparateRecognizedCases() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/DetailView.swift")
        #expect(source.contains("case sceneLibraryDrop"))
        #expect(source.contains("case sceneUnsupportedInBuild"))
        // The routing, not just the enum: both used to assign unrecognizedDrop.
        #expect(source.contains("dropFailure = .sceneLibraryDrop"))
        #expect(source.contains("dropFailure = .sceneUnsupportedInBuild"))
    }

    /// Both API-key surfaces read `apiKeyRejected`. The settings row said the
    /// key was safely stored and the setup row said "Ready", while every
    /// request using that key was being refused.
    @Test("A key Valve rejected is not described as stored or ready")
    func rejectedAPIKeyIsNotReportedAsHealthy() throws {
        let settings = try RepositoryRoot.source("LiveWallpaper/Views/Settings/WorkshopAPIKeySection.swift")
        #expect(settings.contains("services.apiKeyRejected"))

        let onboarding = try RepositoryRoot.source("LiveWallpaper/Views/Onboarding/WorkshopSetupStep.swift")
        let start = try #require(onboarding.range(of: "private var apiKeyDetail"))
        let body = String(onboarding[start.lowerBound...].prefix(900))
        // The dot already read this field; the detail line has to agree with it.
        #expect(body.contains("services.apiKeyRejected"))
    }

    /// Four surfaces rendered the word "Error" while the failing session had
    /// already put `WallpaperRuntimeError.userMessage` in the summary.
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

        // The menu bar reaches the same string through displaySource, which
        // otherwise returns the name of the wallpaper that is not playing.
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
