import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// R-28 / 6.1b: the nav pill is centred in the window and sized by its own titles, and the trailing
/// cluster gets what is left beside it. These pin that cluster at 1040 and 1280 in all five languages.
@Suite("Edit Desk top bar budget")
struct TopBarBudgetTests {
    /// `StatusCapsule`'s collapsed frame.
    private static let status: CGFloat = 118

    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "es"]

    /// Pro on macOS 26 carries six pages; Pro before 26 and Lite on 26 five; Lite before 26 four.
    /// `pages` is how many dots the onboarding capsule draws: Lite has no Workshop step.
    private static let configurations: [(name: String, workshop: Bool, systemWallpaper: Bool, pages: Int)] = [
        ("Pro", true, true, 4), ("Pro 14/15", true, false, 4), ("Lite", false, true, 3), ("Lite 14/15", false, false, 3),
    ]

    private static func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    /// The capsule's own box: 10pt each side, the mono label plus its 8pt gap, then one 5pt dot per
    /// visible page with 4pt between them.
    private static func capsule(pages: Int, language: String = "en") throws -> CGFloat {
        let dots = CGFloat(pages) * 5 + CGFloat(pages - 1) * DesignTokens.Spacing.xs
        return try 20 + label(language) + DesignTokens.EditDesk.Spacing.s8 + dots
    }

    private static func label(_ language: String) throws -> CGFloat {
        let text = try NSLocalizedString("Get Started", bundle: bundle(language), comment: "")
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// `NavPill` at `navItem` 13, off its own item list: `GlassSegmentedPicker`'s editDesk shell is
    /// 3pt of outer padding, 14pt each side of every title and 2pt between them. Fed 12pt, the same
    /// arithmetic reproduces 6.1b's rendered 379.4 / 255.1.
    @MainActor
    private static func pill(workshop: Bool, systemWallpaper: Bool, language: String) throws -> CGFloat {
        let bundle = try bundle(language)
        let items = NavPill.items(workshopAvailable: workshop, systemWallpaperAvailable: systemWallpaper)
        let titles = items.map { page in
            let title = NSLocalizedString(NavPill.title(for: page).probeKey, bundle: bundle, comment: "")
            return (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        }
        return 2 * 3 + titles.reduce(0) { $0 + $1 + 2 * 14 } + 2 * CGFloat(items.count - 1)
    }

    private func pillTrailingEdge(windowWidth: CGFloat, pillWidth: CGFloat) -> CGFloat {
        windowWidth / 2 + pillWidth / 2
    }

    @MainActor
    @Test("The trailing cluster clears the pill at 1040 and 1280 in all five languages, for Pro and Lite, on macOS 26 and before")
    func clusterClearsEveryPill() throws {
        for configuration in Self.configurations {
            for language in Self.languages {
                let pillWidth = try Self.pill(
                    workshop: configuration.workshop, systemWallpaper: configuration.systemWallpaper, language: language
                )
                for windowWidth in [CGFloat(1040), 1280] {
                    let capsuleWidth = try Self.capsule(pages: configuration.pages, language: language)
                    let layout = TopBarBudget.layout(
                        windowWidth: windowWidth, pillWidth: pillWidth, capsuleWidth: capsuleWidth, statusWidth: Self.status
                    )
                    let label = "\(configuration.name) \(Int(windowWidth))/\(language)"
                    print("TOPBAR \(label) = pill \(pillWidth) clusterX \(layout.clusterX) capsule \(layout.showsCapsule) overflow \(layout.overflow)")
                    #expect(layout.overflow == 0, Comment(rawValue: "\(label): overflow \(layout.overflow)"))
                    #expect(
                        layout.clusterX >= pillTrailingEdge(windowWidth: windowWidth, pillWidth: pillWidth) - 0.001,
                        Comment(rawValue: "\(label): cluster starts at \(layout.clusterX)")
                    )
                }
            }
        }
    }

    /// The row as its parts lay out inside the shelf chrome's gutters: each `FilterChip` is its
    /// caption title plus 10pt a side, 8pt between parts, a 12pt spacer, the search field at its
    /// floor, the widest sort title with its 2pt-spaced ▾, and + Import with 10pt a side.
    @MainActor
    @Test("At 1040 the filter row fits its chips, the search field at its floor, sort and import in all five languages")
    func filterRowFitsAt1040() throws {
        let row = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift")
        let search = try #require(row.range(of: "LibrarySearchField("), "the filter row carries no search field")
        let sort = try #require(row.range(of: "\n            sortControl\n"))
        #expect(search.upperBound <= sort.lowerBound, "the sum below reads the field ahead of sort and import")
        let available = StageGeometry.minimumWindow.width - 2 * DesignTokens.EditDesk.Spacing.gutter
        let gap = DesignTokens.EditDesk.Spacing.s8
        let caption = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        func width(_ text: String, size: CGFloat) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
        }
        for language in Self.languages {
            let bundle = try Self.bundle(language)
            func localized(_ key: String) -> String {
                NSLocalizedString(key, bundle: bundle, comment: "")
            }
            let chips = SavedLibraryModel.Chip.allCases.map { width(localized(HomePage.chipTitle($0).probeKey), size: caption) + 2 * 10 }
            // Sort and + Import set `EditDesk.Typography.chip`, 12pt.
            let sortTitle = try #require(["Recently Used", "Name", "Type"].map { width(localized($0), size: 12) }.max())
            let sort = sortTitle + 2 + width("▾", size: 12)
            let importButton = width(localized("+ Import"), size: 12) + 2 * 10
            let needed = chips.reduce(0, +) + CGFloat(chips.count - 1) * gap
                + gap + DesignTokens.EditDesk.Spacing.s12 + gap
                + DesignTokens.LibraryFilterBar.searchMinWidth + gap + sort + gap + importButton
            print("FILTERROW 1040/\(language) = needs \(needed) of \(available)")
            #expect(needed <= available, Comment(rawValue: "\(language): the row needs \(needed)pt of \(available)"))
        }
    }

    /// The cluster clears above only because it may drop the capsule; with six pages these are the
    /// corners where it has to.
    @MainActor
    @Test("1040 English and Spanish are the corners that have to spend the capsule")
    func capsuleIsSpentOnlyWhereThePillLeavesNoRoom() throws {
        for (windowWidth, language, keepsCapsule) in [
            (CGFloat(1280), "en", true), (1280, "zh-Hans", true),
            (1040, "en", false), (1040, "zh-Hans", true), (1040, "es", false),
        ] {
            let pillWidth = try Self.pill(workshop: true, systemWallpaper: true, language: language)
            let capsuleWidth = try Self.capsule(pages: 4, language: language)
            let layout = TopBarBudget.layout(
                windowWidth: windowWidth, pillWidth: pillWidth, capsuleWidth: capsuleWidth, statusWidth: Self.status
            )
            #expect(
                layout.showsCapsule == keepsCapsule,
                Comment(rawValue: "\(Int(windowWidth))/\(language): showsCapsule \(layout.showsCapsule)")
            )
        }
    }

    /// The loop dropping the capsule could have formed: that frees width, and if that width fed the
    /// decision the capsule would be handed back and taken away every frame. The budget asks for a
    /// width instead of measuring one, so the verdict is a fixed point.
    @MainActor
    @Test("Dropping the capsule does not make it fit again")
    func capsuleDropIsAFixedPoint() throws {
        let pillWidth = try Self.pill(workshop: true, systemWallpaper: true, language: "en")
        let asked = try Self.capsule(pages: 4)
        let dropped = TopBarBudget.layout(windowWidth: 1040, pillWidth: pillWidth, capsuleWidth: asked, statusWidth: Self.status)
        #expect(!dropped.showsCapsule)
        // What the bar feeds back next frame: the same asked-for width, because it is derived from
        // the pages and the label, not from the capsule's frame.
        let again = TopBarBudget.layout(windowWidth: 1040, pillWidth: pillWidth, capsuleWidth: asked, statusWidth: Self.status)
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
        for language in Self.languages {
            let text = try NSLocalizedString("Get Started", bundle: Self.bundle(language), comment: "")
            let expected = try Self.capsule(pages: 4, language: language)
            let actual = OnboardingCapsuleFit.width(pages: 4, label: text)
            print("TOPBAR capsule \(language) = \(actual)")
            #expect(actual == expected, Comment(rawValue: "\(language): \(actual) vs \(expected)"))
        }
    }

    @Test("The bar spends the budget on the onboarding capsule")
    func topBarConsumesTheBudget() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/TopBar.swift")
        #expect(source.contains("TopBarBudget.layout("))
        #expect(source.contains("if budget.showsCapsule {"))
    }
}
