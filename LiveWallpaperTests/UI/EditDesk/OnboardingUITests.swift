import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

/// Pins SCREENS.md S9 (card geometry, capsule, Steam wizard) and the mount points R-27/R-28/R-30 fix.
@Suite("Edit Desk onboarding UI")
struct OnboardingUITests {
    private static let card = "LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCard.swift"
    private static let capsule = "LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCapsule.swift"
    private static let wizard = "LiveWallpaper/Views/EditDesk/Onboarding/SteamWizard.swift"
    private static let home = "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift"
    private static let topBar = "LiveWallpaper/Views/EditDesk/Shell/TopBar.swift"
    private static let detailTopBar = "LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift"
    private static let detailHost = "LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift"
    private static let workshopPage = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopPage.swift"

    // MARK: Card geometry (SCREENS S9)

    @Test("Card metrics are the S9 numbers and the stage inset is derived from them")
    func cardMetrics() {
        #expect(OnboardingCardMetrics.headerTop == 56)
        #expect(OnboardingCardMetrics.cardTop == 110)
        #expect(OnboardingCardMetrics.cardHeight == 170)
        #expect(OnboardingCardMetrics.gutter == 24)
        #expect(OnboardingCardMetrics.messageMaxWidth == 540)
        #expect(OnboardingCardMetrics.primaryButtonHeight == 30)
        // R-27: the arrangement gives up the card's band plus one gutter, nothing more.
        #expect(OnboardingCardMetrics.stageTopInset == 304)
        #expect(
            OnboardingCardMetrics.stageTopInset
                == OnboardingCardMetrics.cardTop + OnboardingCardMetrics.cardHeight + OnboardingCardMetrics.gutter
        )
    }

    @Test("Every page's card carries a timing, a title, a message, at least one button and a footnote")
    func cardContent() {
        for page in OnboardingProgress.Page.allCases {
            let content = OnboardingCardContent.of(page)
            #expect(!content.buttons.isEmpty, Comment(rawValue: "\(page) has no action"))
            #expect(content.buttons.count <= 2, Comment(rawValue: "\(page) has more than the two S9 buttons"))
            #expect(content.buttons.first?.isPrimary == true, Comment(rawValue: "\(page) leads with a secondary button"))
            #expect(content.buttons.dropFirst().allSatisfy { !$0.isPrimary })
        }
        #expect(OnboardingCardContent.of(.home).buttons.count == 2)
        #expect(OnboardingCardContent.of(.library).buttons.count == 1)
        #expect(OnboardingCardContent.of(.workshop).buttons.count == 2)
        #expect(OnboardingCardContent.of(.overlay).buttons.count == 1)
    }

    @Test("The step line counts within the visible pages, so Lite reads n / 3")
    func stepLine() {
        #expect(OnboardingCardContent.stepText(step: 3, total: 4) == "STEP 3 / 4")
        #expect(OnboardingCardContent.stepText(step: 3, total: 3) == "STEP 3 / 3")
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

    /// 1040 library page: 16pt page padding, a 220pt search field, the 118pt status capsule and
    /// 12pt gaps leave the centred nav pill no room for the capsule's label.
    @Test("The label is dropped on the search-bearing page below the design width")
    func capsuleFit() {
        #expect(!OnboardingCapsuleFit.showsLabel(windowWidth: 1040, showsSearch: true))
        #expect(OnboardingCapsuleFit.showsLabel(windowWidth: 1280, showsSearch: true))
        #expect(OnboardingCapsuleFit.showsLabel(windowWidth: 1040, showsSearch: false))
        #expect(OnboardingCapsuleFit.labelMinimumWidth == StageGeometry.designWindow.width)
    }

    @Test("The detail top bar stays out of it — the overlay card carries its own step line")
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

    // MARK: Mount points (R-27)

    @Test("The overview card hangs in the home ZStack, gated on a resting stage with nothing over it")
    func homeCardMount() throws {
        let source = try RepositoryRoot.source(Self.home)
        #expect(source.contains("OnboardingCard(page: .home"))
        #expect(source.contains("router.page == .home && stage.progress == 0 && !interactionLock"))
        #expect(source.contains("promptImport"))
        #expect(source.contains("router.libraryFocus = .aerials"))
    }

    @Test("The library card rides the wallpaper grid's scroll view, above the real tiles")
    func libraryCardMount() throws {
        let source = try RepositoryRoot.source(Self.home)
        let grid = try #require(source.range(of: "private var wallpaperGrid: some View {"))
        let tail = String(source[grid.upperBound...])
        let cardIndex = try #require(tail.range(of: "OnboardingCard(page: .library"))
        let emptyIndex = try #require(tail.range(of: "IllustratedEmptyState("))
        #expect(cardIndex.lowerBound < emptyIndex.lowerBound, "the card must precede the grid's own content")
    }

    @Test("The workshop card sits under the top bar and ahead of BrowsePane, which it must not cover")
    func workshopCardMount() throws {
        let source = try RepositoryRoot.source(Self.workshopPage)
        #expect(source.contains("OnboardingCard(page: .workshop"))
        let cardIndex = try #require(source.range(of: "\n            onboardingCard\n"))
        let browseIndex = try #require(source.range(of: "BrowsePane("))
        #expect(cardIndex.lowerBound < browseIndex.lowerBound)
        // R-27: browsing stays available while the card is up.
        #expect(source.contains("showsOnboardingCard ? OnboardingCardMetrics.blockHeight"))
    }

    @Test("The overlay card mounts in the detail host's overlay section and records on a persisted object")
    func overlayCardMount() throws {
        let source = try RepositoryRoot.source(Self.detailHost)
        #expect(source.contains("OnboardingCard(page: .overlay"))
        #expect(source.contains("section == .overlay"))
        #expect(source.contains("session.onObjectPersisted = { progress?.record(.overlay) }"))
        #expect(source.contains("setClockEnabled(true)"))
    }

    @Test("Every card host reads the progress as an optional, so an uninjected host does not trap")
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
        #expect(!source.contains("SteamConnectorClient.signInSteamAccount"), "that call belongs to SteamSignInSheet")
        #expect(!source.contains("SecureField"), "the wizard must not grow its own password field")
        // GAP §3.6: the Web API key and the engine assets stay in Settings.
        #expect(!source.contains("SteamWebAPIKeyEntrySheet"))
        #expect(!source.contains("engineAssets"))
    }

    @Test("The workshop page presents the wizard and no longer keeps the old onboarding sheet")
    func wizardReplacesTheOldSheet() throws {
        let source = try RepositoryRoot.source(Self.workshopPage)
        #expect(source.contains("SteamWizard("))
        #expect(!source.contains("OnboardingSheet("), "two onboarding sheets must not coexist")
        #expect(!source.contains("isShowingOnboarding"))
        #expect(!source.contains("onboardingShown"))
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
