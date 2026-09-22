import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// R-28 / 6.1b: the nav pill is centred in the window and sized by its own titles, so at 1040 the
/// fixed 220pt search field drove the trailing cluster 35.7pt into it. These pin the four corners
/// the bar has to survive.
@Suite("Edit Desk top bar budget")
struct TopBarBudgetTests {
    /// The pill at `navItem` 13: `GlassSegmentedPicker`'s editDesk shell is 3pt of outer padding,
    /// 14pt each side of every title and 2pt between them. Reproduces 6.1b's rendered 379.4 / 255.1
    /// when fed 12pt, which is what licenses reading these off the same arithmetic.
    private static let englishPill: CGFloat = 397.6
    private static let chinesePill: CGFloat = 265.9
    /// Spanish is the widest of the five, so it is the corner the budget has to survive.
    private static let spanishPill: CGFloat = 432.3
    /// `StatusCapsule`'s collapsed frame.
    private static let status: CGFloat = 118

    /// The capsule's own box: 10pt each side, the mono label plus its 8pt gap, then one 5pt dot per
    /// visible page with 4pt between them.
    private static func capsule(pages: Int, showsLabel: Bool, language: String = "en") throws -> CGFloat {
        let dots = CGFloat(pages) * 5 + CGFloat(pages - 1) * DesignTokens.Spacing.xs
        guard showsLabel else { return 20 + dots }
        return try 20 + label(language) + DesignTokens.EditDesk.Spacing.s8 + dots
    }

    private static func label(_ language: String) throws -> CGFloat {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let text = NSLocalizedString("Get Started", bundle: bundle, comment: "")
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func pillTrailingEdge(windowWidth: CGFloat, pillWidth: CGFloat) -> CGFloat {
        windowWidth / 2 + pillWidth / 2
    }

    @Test("The library cluster clears the centred pill at 1040 and 1280 in English and Chinese")
    func libraryClusterClearsThePill() throws {
        for (windowWidth, pillWidth, language) in [
            (CGFloat(1280), Self.englishPill, "en"), (1280, Self.chinesePill, "zh-Hans"),
            (1280, Self.spanishPill, "es"),
            (1040, Self.englishPill, "en"), (1040, Self.chinesePill, "zh-Hans"),
            (1040, Self.spanishPill, "es"),
        ] {
            // The search-bearing page below the design width spends the capsule's label first.
            let showsLabel = OnboardingCapsuleFit.showsLabel(windowWidth: windowWidth, showsSearch: true)
            let capsuleWidth = try Self.capsule(pages: 4, showsLabel: showsLabel, language: language)
            let layout = TopBarBudget.layout(
                windowWidth: windowWidth, pillWidth: pillWidth, showsSearch: true,
                capsuleWidth: capsuleWidth, statusWidth: Self.status
            )
            let label = "\(Int(windowWidth))/\(language)"
            print(
                "TOPBAR \(label) = search \(layout.searchWidth) clusterX \(layout.clusterX)"
                    + " capsule \(layout.showsCapsule) overflow \(layout.overflow)"
            )
            #expect(
                layout.searchWidth >= DesignTokens.LibraryFilterBar.searchMinWidth,
                Comment(rawValue: "\(label): search \(layout.searchWidth) is under the field's own floor")
            )
            #expect(layout.searchWidth <= TopBarBudget.idealSearchWidth)
            #expect(layout.overflow == 0, Comment(rawValue: "\(label): overflow \(layout.overflow)"))
            #expect(
                layout.clusterX >= pillTrailingEdge(windowWidth: windowWidth, pillWidth: pillWidth) - 0.001,
                Comment(rawValue: "\(label): cluster starts at \(layout.clusterX)")
            )
        }
    }

    /// The cluster clears above only because it may drop the capsule; these are the corners where
    /// shrinking the search field alone is not enough.
    @Test("1040 English and both Spanish corners are the ones that have to spend the capsule")
    func capsuleIsSpentOnlyWhereTheFieldRunsOut() throws {
        for (windowWidth, pillWidth, language, keepsCapsule) in [
            (CGFloat(1280), Self.englishPill, "en", true), (1280, Self.chinesePill, "zh-Hans", true),
            (1280, Self.spanishPill, "es", false),
            (1040, Self.englishPill, "en", false), (1040, Self.chinesePill, "zh-Hans", true),
            (1040, Self.spanishPill, "es", false),
        ] {
            let showsLabel = OnboardingCapsuleFit.showsLabel(windowWidth: windowWidth, showsSearch: true)
            let capsuleWidth = try Self.capsule(pages: 4, showsLabel: showsLabel, language: language)
            let layout = TopBarBudget.layout(
                windowWidth: windowWidth, pillWidth: pillWidth, showsSearch: true,
                capsuleWidth: capsuleWidth, statusWidth: Self.status
            )
            #expect(
                layout.showsCapsule == keepsCapsule,
                Comment(rawValue: "\(Int(windowWidth))/\(language): showsCapsule \(layout.showsCapsule)")
            )
        }
    }

    /// The loop the fourth move could have formed: dropping the capsule frees width, and if that
    /// width fed the decision the capsule would be handed back and taken away every frame. The
    /// budget asks for a width instead of measuring one, so the verdict is a fixed point.
    @Test("Dropping the capsule does not make it fit again")
    func capsuleDropIsAFixedPoint() throws {
        let asked = try Self.capsule(pages: 4, showsLabel: false)
        let dropped = TopBarBudget.layout(
            windowWidth: 1040, pillWidth: Self.englishPill, showsSearch: true,
            capsuleWidth: asked, statusWidth: Self.status
        )
        #expect(!dropped.showsCapsule)
        // What the bar feeds back next frame: the same asked-for width, because it is derived from
        // the pages and the label, not from the capsule's frame.
        let again = TopBarBudget.layout(
            windowWidth: 1040, pillWidth: Self.englishPill, showsSearch: true,
            capsuleWidth: asked, statusWidth: Self.status
        )
        #expect(again == dropped)
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/TopBar.swift")
        #expect(source.contains("capsuleWidth: OnboardingCapsuleFit.width("))
        #expect(
            !source.contains("capsuleWidth = $0"),
            "a measured capsule frame is what closes the loop"
        )
    }

    /// The width the budget is fed has to be the box the capsule actually draws.
    @Test("The asked-for capsule width is the drawn box in all five languages")
    func capsuleWidthMatchesItsBox() throws {
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "es"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let text = NSLocalizedString("Get Started", bundle: bundle, comment: "")
            for showsLabel in [true, false] {
                let expected = try Self.capsule(pages: 4, showsLabel: showsLabel, language: language)
                let actual = OnboardingCapsuleFit.width(pages: 4, label: showsLabel ? text : nil)
                print("TOPBAR capsule \(language) label=\(showsLabel) = \(actual)")
                #expect(actual == expected, Comment(rawValue: "\(language): \(actual) vs \(expected)"))
            }
        }
    }

    @Test("Once onboarding is done, even 1040 English clears with the search field still over its floor")
    func finishedOnboardingClearsAt1040() {
        let layout = TopBarBudget.layout(
            windowWidth: 1040, pillWidth: Self.englishPill, showsSearch: true,
            capsuleWidth: 0, statusWidth: Self.status
        )
        print("TOPBAR 1040/en-noCapsule = search \(layout.searchWidth) overflow \(layout.overflow)")
        #expect(layout.overflow == 0, Comment(rawValue: "overflow \(layout.overflow)"))
        #expect(layout.searchWidth > DesignTokens.LibraryFilterBar.searchMinWidth)
        #expect(layout.searchWidth < TopBarBudget.idealSearchWidth, "1040 has to shrink the field, not keep 220")
        #expect(layout.clusterX >= pillTrailingEdge(windowWidth: 1040, pillWidth: Self.englishPill) - 0.001)
    }

    @Test("A page without a search field keeps the whole cluster fixed and asks for no width")
    func pagesWithoutSearch() throws {
        let capsuleWidth = try Self.capsule(pages: 4, showsLabel: true)
        let layout = TopBarBudget.layout(
            windowWidth: 1040, pillWidth: Self.englishPill, showsSearch: false,
            capsuleWidth: capsuleWidth, statusWidth: Self.status
        )
        #expect(layout.searchWidth == 0)
        #expect(layout.overflow == 0, Comment(rawValue: "overflow \(layout.overflow)"))
    }

    @Test("The bar spends the budget rather than a fixed field width")
    func topBarConsumesTheBudget() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/TopBar.swift")
        #expect(source.contains("TopBarBudget.layout("))
        #expect(source.contains("minWidth: budget.searchWidth"))
        #expect(!source.contains("searchFieldWidth"), "a fixed field width is what 6.1b measured the overlap against")
    }

    @Test("A wide window hands the field its full 220 rather than stretching it")
    func wideWindowStopsAtTheIdealWidth() throws {
        let capsuleWidth = try Self.capsule(pages: 4, showsLabel: true)
        let layout = TopBarBudget.layout(
            windowWidth: 1920, pillWidth: Self.englishPill, showsSearch: true,
            capsuleWidth: capsuleWidth, statusWidth: Self.status
        )
        #expect(layout.searchWidth == TopBarBudget.idealSearchWidth)
        #expect(layout.overflow == 0)
    }
}
