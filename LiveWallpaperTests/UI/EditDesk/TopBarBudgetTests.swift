import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
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
        ("Pro", true, true, 6), ("Pro 14/15", true, false, 6), ("Lite", false, true, 5), ("Lite 14/15", false, false, 5),
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
                        layout.clusterX >= pillTrailingEdge(windowWidth: windowWidth, pillWidth: pillWidth) + DesignTokens.EditDesk.Spacing.s12 - 0.001,
                        Comment(rawValue: "\(label): cluster starts at \(layout.clusterX)")
                    )
                }
            }
        }
    }

    private static let sortOrders = SavedLibraryModel.Sort.allCases
    /// No filter, then every filter whose name the sort button carries after the sort's.
    private static let filters: [SavedLibraryModel.Filter?] = [nil, .unsupported, .storage(.managed), .storage(.linked)]

    /// The real filter row laid out in one language: the glass controls have no size to add up.
    @MainActor
    private static func filterRow(language: String, sort: SavedLibraryModel.Sort, filter: SavedLibraryModel.Filter? = nil) -> NSSize {
        let row = LibraryChipsRow(
            chips: SavedLibraryModel.Chip.allCases.map { LibraryChip(id: "\($0)", title: HomePage.chipTitle($0)) },
            selection: .constant("all"),
            searchText: .constant(""),
            searchPrompt: "Search by name",
            searchShortPrompt: "Search",
            stage: EditDeskStageModel(),
            sort: .constant(sort),
            filter: .constant(filter),
            onImport: {}
        )
        return NSHostingView(rootView: row.environment(\.locale, Locale(identifier: language))).fittingSize
    }

    @MainActor
    @Test("At 1040 the filter row fits its chips, the search field at its floor, sort with any filter named, and add in all five languages")
    func filterRowFitsAt1040() throws {
        let row = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift")
        let search = try #require(row.range(of: "LibrarySearchField("), "the filter row carries no search field")
        let sort = try #require(row.range(of: "LibrarySortControl(label: sortLabel)"))
        #expect(search.upperBound <= sort.lowerBound, "the row measured below carries the field ahead of sort and add")
        let available = StageGeometry.minimumWindow.width - 2 * DesignTokens.EditDesk.Spacing.gutter
        // Laid out at its ideal width, the field can still give back everything above its floor.
        let give = DesignTokens.LibraryFilterBar.searchIdealWidth - DesignTokens.LibraryFilterBar.searchMinWidth
        #expect(
            Self.filterRow(language: "es", sort: .recentlyUsed).width > Self.filterRow(language: "en", sort: .recentlyUsed).width,
            "control: the row did not lay out in Spanish, so every language below measured English"
        )
        #expect(
            Self.filterRow(language: "en", sort: .name, filter: .unsupported).width > Self.filterRow(language: "en", sort: .name).width,
            "control: the sort button did not carry the filter's name, so no row below measured one"
        )
        for language in Self.languages {
            let widths = Self.sortOrders.flatMap { sort in Self.filters.map { Self.filterRow(language: language, sort: sort, filter: $0).width } }
            let needed = try #require(widths.max()) - give
            print("FILTERROW 1040/\(language) = needs \(needed) of \(available)")
            #expect(needed <= available, Comment(rawValue: "\(language): the row needs \(needed)pt of \(available)"))
        }
    }

    /// The placeholder the search field draws once `HomePage` has laid out the Aerials chip's row, connected, at `windowWidth`.
    @MainActor
    private static func aerialsSearchPlaceholder(_ language: AppLanguagePreference, windowWidth: CGFloat) throws -> (shown: String, fieldWidth: CGFloat) {
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable {
                return field
            }
            return view.subviews.lazy.compactMap(textField).first
        }
        return try AppLanguageOverride.with(language) {
            let row = HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
                LibraryChipsRow(
                    chips: SavedLibraryModel.Chip.allCases.map { LibraryChip(id: "\($0)", title: HomePage.chipTitle($0)) },
                    selection: .constant("\(SavedLibraryModel.Chip.aerials)"),
                    searchText: .constant(""),
                    searchPrompt: "Search by name or tag",
                    searchShortPrompt: "Search",
                    stage: EditDeskStageModel(),
                    sort: .constant(.recentlyUsed),
                    filter: .constant(nil),
                    onImport: {}
                )
                AerialsSourceControls()
            }
            let width = windowWidth - 2 * DesignTokens.EditDesk.Spacing.gutter
            let host = NSHostingView(rootView: row.frame(width: width).environment(\.locale, Locale(identifier: language.rawValue)))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 60)
            host.layoutSubtreeIfNeeded()
            let field = try #require(textField(in: host), "the row drew no search field")
            return (field.placeholderString ?? field.placeholderAttributedString?.string ?? "", field.frame.width)
        }
    }

    @MainActor
    @Test("At 1040 in Spanish, beside the Aerials controls, the search field falls back to its short prompt; at 1280 English keeps the long one")
    func searchFieldFallsBackToItsShortPrompt() throws {
        let spanish = try Self.aerialsSearchPlaceholder(.spanish, windowWidth: 1040)
        let short = try NSLocalizedString("Search", bundle: Self.bundle("es"), comment: "")
        print("SEARCHPROMPT 1040/es = \(spanish.shown) in a \(spanish.fieldWidth)pt text field")
        #expect(spanish.shown == short, Comment(rawValue: "es 1040 draws \(spanish.shown)"))

        // Control: a field wide enough keeps its long prompt, so the fallback above is a decision, not a constant.
        let english = try Self.aerialsSearchPlaceholder(.english, windowWidth: 1280)
        print("SEARCHPROMPT 1280/en = \(english.shown) in a \(english.fieldWidth)pt text field")
        #expect(english.shown == "Search by name or tag", Comment(rawValue: "en 1280 draws \(english.shown)"))
    }

    /// The row hangs a fixed `StageGeometry.chipRowGap` above the shelf's cards; a taller control closes that gap.
    @MainActor
    @Test("The filter row's glass controls stand no taller than its search field in any language")
    func filterRowGlassControlsStayWithinTheRowHeight() {
        let field = NSHostingView(rootView: LibrarySearchField(text: .constant(""), prompt: "Search by name")).fittingSize.height
        for language in Self.languages {
            for sort in Self.sortOrders {
                for filter in Self.filters {
                    let height = Self.filterRow(language: language, sort: sort, filter: filter).height
                    print("FILTERROW height \(language)/\(sort)/\(String(describing: filter)) = row \(height) field \(field)")
                    #expect(
                        height <= field,
                        Comment(rawValue: "\(language)/\(sort)/\(String(describing: filter)): the row is \(height)pt, the field \(field)pt")
                    )
                }
            }
        }
    }

    /// The cluster clears above only because it may drop the capsule; with six pages these are the
    /// corners where it has to.
    @MainActor
    @Test("Navigation spacing takes precedence over onboarding when the trailing cluster does not fit")
    func capsuleIsSpentOnlyWhereThePillLeavesNoRoom() throws {
        for (windowWidth, language, keepsCapsule) in [
            (CGFloat(1280), "en", false), (1280, "zh-Hans", true),
            (1040, "en", false), (1040, "zh-Hans", false), (1040, "es", false),
        ] {
            let pillWidth = try Self.pill(workshop: true, systemWallpaper: true, language: language)
            let capsuleWidth = try Self.capsule(pages: 6, language: language)
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
        let asked = try Self.capsule(pages: 6)
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

    /// The bar's first frame has not measured the pill yet; a capsule drawn there would vanish on the next.
    @MainActor
    @Test("Until the pill is measured the capsule is not drawn")
    func unmeasuredPillDrawsNoCapsule() throws {
        let asked = try Self.capsule(pages: 6, language: "zh-Hans")
        let unmeasured = TopBarBudget.layout(windowWidth: 1280, pillWidth: 0, capsuleWidth: asked, statusWidth: Self.status)
        #expect(!unmeasured.showsCapsule)
        // Control: the same bar with its pill measured keeps the capsule.
        let pillWidth = try Self.pill(workshop: true, systemWallpaper: true, language: "zh-Hans")
        let measured = TopBarBudget.layout(windowWidth: 1280, pillWidth: pillWidth, capsuleWidth: asked, statusWidth: Self.status)
        #expect(measured.showsCapsule)
    }

    /// The width the budget is fed has to be the box the capsule actually draws.
    @Test("The asked-for capsule width is the drawn box in all five languages")
    func capsuleWidthMatchesItsBox() throws {
        for language in Self.languages {
            let text = try NSLocalizedString("Get Started", bundle: Self.bundle(language), comment: "")
            let expected = try Self.capsule(pages: 6, language: language)
            let actual = OnboardingCapsuleFit.width(pages: 6, label: text)
            print("TOPBAR capsule \(language) = \(actual)")
            #expect(actual == expected, Comment(rawValue: "\(language): \(actual) vs \(expected)"))
        }
    }

    /// The page guide button sits in the cluster on every page, so it takes its diameter and a gap of the room.
    @Test("The page guide button is counted in the trailing cluster")
    func pageGuideButtonIsCounted() {
        let windowWidth: CGFloat = 1280, pillWidth: CGFloat = 300, capsuleWidth: CGFloat = 100
        let gap = DesignTokens.EditDesk.Spacing.s12
        let guide = DesignTokens.iconButtonDiameter(.large)
        let room = windowWidth / 2 - pillWidth / 2 - DesignTokens.Spacing.lg
        // Capsule and status alone leave 20pt spare, less than the guide and its gap take.
        let status = room - capsuleWidth - gap - 20
        let crowded = TopBarBudget.layout(
            windowWidth: windowWidth, pillWidth: pillWidth, capsuleWidth: capsuleWidth, statusWidth: status
        )
        #expect(!crowded.showsCapsule)
        let bare = TopBarBudget.layout(windowWidth: windowWidth, pillWidth: pillWidth, capsuleWidth: 0, statusWidth: status)
        #expect(bare.clusterX == windowWidth - DesignTokens.Spacing.lg - (guide + gap + status))
    }
}
