import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

/// Covers the floating guide, replay entry points and the separate Steam setup form.
@Suite("Edit Desk onboarding UI")
struct OnboardingUITests {
    private static let card = "LiveWallpaper/Views/EditDesk/Onboarding/OnboardingPageGuide.swift"
    private static let capsule = "LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCapsule.swift"
    private static let wizard = "LiveWallpaper/Views/EditDesk/Onboarding/SteamWizard.swift"
    private static let home = "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift"
    private static let topBar = "LiveWallpaper/Views/EditDesk/Shell/TopBar.swift"
    private static let detailTopBar = "LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift"
    private static let detailHost = "LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift"
    private static let workshopPage = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopPage.swift"

    @Test("Every page guide has unique, nonempty explanations")
    func uniqueExplanations() {
        for context in PageGuideContext.allCases {
            let messages = context.steps.map(\.message.probeKey)
            #expect(!messages.isEmpty)
            #expect(messages.allSatisfy { !$0.isEmpty })
            #expect(Set(messages).count == messages.count)
        }
    }

    @Test("Steam instructions cover prerequisites and link to the relevant settings")
    func steamSetupCoverage() {
        let steps = PageGuideContext.workshop.steps
        #expect(steps.filter { $0.settingsAnchor == .workshopConnection }.count == 3)
        #expect(steps.contains { $0.settingsAnchor == .workshopSetup })
        #expect(steps.contains { $0.settingsAnchor == .workshopAssets })
        let text = steps.map(\.message.probeKey).joined(separator: " ")
        for concept in ["SteamCMD", "library folder", "Steam Guard", "without a Steam Web API key", "Missing assets", "without signing in"] {
            #expect(text.contains(concept), Comment(rawValue: concept))
        }
    }

    @Test("Guides describe the current navigation and controls")
    func guidesMatchCurrentNavigation() {
        for context in [PageGuideContext.overview, .saved] {
            let text = context.steps.flatMap { [$0.title.probeKey, $0.message.probeKey] }.joined(separator: " ")
            for stale in ["Saved holds", "Choose a tab"] {
                #expect(!text.contains(stale), Comment(rawValue: "\(context): \(stale)"))
            }
        }
        let inspector = PageGuideContext.configuration.steps.filter { $0.target == .inspector }
        #expect(!inspector.isEmpty)
        for step in inspector {
            for control in ["Follow Cursor", "Interaction"] {
                #expect(!step.message.probeKey.contains(control), Comment(rawValue: control))
            }
        }
        for context in PageGuideContext.allCases where context != .workshop {
            let text = context.steps.map(\.message.probeKey).joined(separator: " ")
            #expect(!text.contains("Follow Cursor"), Comment(rawValue: "\(context)"))
        }
    }

    @Test("Guides name Wallpaper Automation and its three modes")
    func guidesNameWallpaperAutomation() {
        func text(_ context: PageGuideContext) -> String {
            context.steps.flatMap { [$0.title.probeKey, $0.message.probeKey] }.joined(separator: " ")
        }
        let configuration = text(.configuration)
        #expect(configuration.contains("Wallpaper Automation"))
        #expect(!configuration.contains("Playlist & Schedule"))
        let automation = text(.automation)
        for term in ["Playlist", "Daily Schedule", "Library Shuffle", "Enable Again"] {
            #expect(automation.contains(term), Comment(rawValue: term))
        }
        #expect(text(.settings).contains("opening animation"))
    }

    @Test("Guide panels stay in the window and avoid controls on all four edges")
    func floatingPanelPlacement() {
        for size in [CGSize(width: 1040, height: 640), CGSize(width: 1280, height: 800), CGSize(width: 1600, height: 1000)] {
            let targets = [CGRect(x: 400, y: 0, width: 240, height: 56),
                           CGRect(x: 0, y: 90, width: 210, height: size.height - 90),
                           CGRect(x: size.width - 372, y: 56, width: 372, height: size.height - 56),
                           CGRect(x: 0, y: size.height - 130, width: size.width, height: 130)]
            for target in targets {
                let frame = PageGuideLayout.frame(in: size, panel: CGSize(width: 380, height: 280), target: target)
                #expect(CGRect(origin: .zero, size: size).contains(frame))
                #expect(frame.minY >= PageGuideLayout.topClearance)
                #expect(!frame.intersects(target))
            }
        }
    }

    // MARK: Capsule (R-28)

    @Test("Capsule dots are one per visible page, filled for handled ones")
    func capsuleDots() {
        let pro: [OnboardingProgress.Page] = [.home, .library, .workshop, .overlay]
        #expect(OnboardingCapsuleModel.dots(visible: pro, handled: []) == [false, false, false, false])
        #expect(OnboardingCapsuleModel.dots(visible: pro, handled: [.home, .workshop]) == [true, false, true, false])
        let lite: [OnboardingProgress.Page] = [.home, .library, .overlay]
        #expect(OnboardingCapsuleModel.dots(visible: lite, handled: [.home]) == [true, false, false])
    }

    @Test("The floating guide owns the only step counter")
    func detailTopBarHasNoCapsule() throws {
        let source = try RepositoryRoot.source(Self.detailTopBar)
        #expect(!source.contains("OnboardingCapsule"))
        #expect(!source.contains("OnboardingProgress"))
    }

    @Test("The shared top bar carries the capsule ahead of the page's own trailing control")
    func topBarHostsTheCapsule() throws {
        let source = try RepositoryRoot.source(Self.topBar)
        #expect(source.contains("OnboardingCapsule("))
        let capsuleIndex = try #require(source.range(of: "OnboardingCapsule("))
        let trailingIndex = try #require(source.range(of: "trailing()"))
        #expect(capsuleIndex.lowerBound < trailingIndex.lowerBound, "the capsule must precede the Steam menu")
        let statusIndex = try #require(source.range(of: "\n            status\n"))
        #expect(capsuleIndex.lowerBound < statusIndex.lowerBound, "the capsule must sit left of StatusCapsule")
    }

    @Test("Tutorials never reserve space in the actual page layout")
    func noEmbeddedTutorials() throws {
        for path in [Self.home, Self.workshopPage, Self.detailHost,
                     "LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift",
                     "LiveWallpaper/Views/EditDesk/Detail/DisplayDetail.swift"] {
            let source = try RepositoryRoot.source(path)
            #expect(!source.contains("OnboardingCard("))
            #expect(!source.contains("OnboardingCardMetrics"))
            #expect(!source.contains("onboardingInset"))
        }
    }

    @Test("Optional progress environments allow hosts outside the tutorial")
    func optionalEnvironment() throws {
        for path in [Self.card, Self.capsule, Self.home, Self.topBar, Self.detailHost, Self.workshopPage] {
            let source = try RepositoryRoot.source(path)
            guard source.contains("@Environment(OnboardingProgress.self)") else { continue }
            #expect(
                source.contains("@Environment(OnboardingProgress.self) private var progress: OnboardingProgress?"),
                Comment(rawValue: "\(path) reads the progress non-optionally")
            )
        }
    }

    // MARK: Steam wizard (R-30)

    @Test("The wizard is a plain sheet at 446×526, not the 880×560 modal chrome")
    func wizardGeometry() throws {
        #expect(SteamWizardMetrics.size == CGSize(width: 446, height: 526))
        let source = try RepositoryRoot.source(Self.wizard)
        #expect(!source.contains("EditDeskModalChrome"), "the chrome is pinned to 880×560")
        #expect(source.contains("SteamWizardMetrics.size"))
    }

    @Test("The wizard reuses the existing sign-in state machine and setup controller, not a second one")
    func wizardReusesExistingMachines() throws {
        let source = try RepositoryRoot.source(Self.wizard)
        #expect(source.contains("SteamSignInSheet {"))
        #expect(source.contains("adoptSignedInAccount"))
        #expect(source.contains("WorkshopSetupController"))
        #expect(source.contains("WorkshopFolderImportCoordinator.shared.importProjects(from:"))
        // The library grant and the standard-location scan go through the Settings row's own entry points.
        #expect(source.contains("authorizeSteamLibrary(startingAtScannedPath: true)"))
        #expect(source.contains("setupController.prepare()"))
        #expect(source.contains("SteamCMDSetupSheet(onConfirmManagedInstall:"))
        #expect(source.contains("isShowingInstall = true"))
        #expect(!source.contains("OnboardingProgress"))
        #expect(!source.contains("steps(progress)"))
        #expect(!source.contains("SteamConnectorClient.signInSteamAccount"), "that call belongs to SteamSignInSheet")
        #expect(!source.contains("SecureField"), "the wizard must not grow its own password field")
        // Optional API keys and scene resources have dedicated Settings destinations.
        #expect(!source.contains("SteamWebAPIKeyEntrySheet"))
        #expect(!source.contains("engineAssets"))
    }

    @Test("The wizard's primary step is the first thing a download still lacks")
    @MainActor
    func wizardStepFollowsTheFirstBlocker() {
        let table: [(SteamCMDDoctorService.DownloadBlocker?, Bool, SteamWizardStep)] = [
            (.steamCMD, false, .installSteamCMD),
            (.library, false, .chooseLibrary),
            (.account, false, .signIn),
            (.session, false, .signIn),
            (nil, false, .signIn),
            (nil, true, .done),
        ]
        for (blocker, isConfirmed, expected) in table {
            #expect(
                SteamWizardStep.make(blocker: blocker, isConfirmed: isConfirmed) == expected,
                Comment(rawValue: "\(String(describing: blocker)), confirmed \(isConfirmed)")
            )
        }
    }

    @Test("The workshop page presents the Steam wizard")
    func workshopPagePresentsTheWizard() throws {
        let source = try RepositoryRoot.source(Self.workshopPage)
        #expect(source.contains("SteamWizard("))
    }

    // MARK: Tokens

    @Test("No token-bypass literals in the files this package owns")
    func noTokenBypassLiterals() throws {
        for path in [Self.card, Self.capsule, Self.wizard] {
            let source = try RepositoryRoot.source(path)
            #expect(!source.contains(".font(.system("), "\(path) has an inline .font(.system( literal")
            #expect(!source.contains("Color(red:"), "\(path) has a literal Color(red:")
            #expect(
                source.range(of: #"cornerRadius:\s*[0-9]"#, options: .regularExpression) == nil,
                "\(path) has a literal cornerRadius"
            )
        }
    }
}
