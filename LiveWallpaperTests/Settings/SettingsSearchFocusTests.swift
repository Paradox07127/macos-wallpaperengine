import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Settings search lands on the row it found")
struct SettingsSearchFocusTests {
    private static let capabilities = ProductCapabilities.pro.withWorkshopOnline()
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "es"]

    private static func focus(_ page: SettingsNavigation, _ query: String) throws -> SettingsSearchFocus? {
        let item = try #require(SettingsNavigation.allItems.first { $0.destination == page })
        return item.searchFocus(matching: query, capabilities: capabilities)
    }

    @Test("The reviewed search lands on the Language row itself, in English and in Chinese")
    func languageLandsOnItsRow() throws {
        for query in ["Language", "语言"] {
            let focus = try Self.focus(.general, query)
            #expect(focus?.anchor == .generalAppearance, Comment(rawValue: query))
            #expect(focus?.rows == ["Language"], Comment(rawValue: query))
            #expect(focus?.scrollRow == "Language", Comment(rawValue: query))
        }
    }

    @Test("A name several sections share marks each of them and scrolls to the section, not to one of the rows")
    func sharedNameScrollsToTheSection() throws {
        let focus = try Self.focus(.displayDefaults, "Volume")
        #expect(focus?.anchor == .displayDefaultsVideo)
        #expect(focus?.rows == ["Volume"])
        #expect(focus?.scrollRow == nil)
    }

    @Test("Searching a section's own name leaves the emphasis on the section")
    func sectionNameStaysOnTheSection() throws {
        let focus = try Self.focus(.displayDefaults, "Video")
        #expect(focus?.anchor == .displayDefaultsVideo)
        #expect(focus?.scrollRow == nil)
    }

    @Test("A word several rows share marks all of them and scrolls to the first")
    func sharedWordMarksEveryRow() throws {
        let focus = try Self.focus(.performancePower, "pause")
        #expect(focus?.anchor == .performancePause)
        #expect(focus?.rows == [
            "Pause on full-screen apps", "Pause in Low Power Mode", "Pause when windows cover the desktop",
            "Pause on battery", "Application Pause Rules",
        ])
        #expect(focus?.scrollRow == "Pause on full-screen apps")
    }

    @Test("A page without sections still lands on its row")
    func pageWithoutSectionsLandsOnItsRow() throws {
        let focus = try Self.focus(.advanced, "Log Files")
        #expect(focus?.anchor == nil)
        #expect(focus?.rows == ["Log Files"])
        #expect(focus?.scrollRow == "Log Files")
    }

    @Test("A query that does not reach the page, or an empty one, gives it nothing to do")
    func unrelatedQueryGivesNothing() throws {
        #expect(try Self.focus(.general, "battery") == nil)
        #expect(try Self.focus(.general, "   ") == nil)
    }

    @Test("The page lands where the sidebar said and marks the row, for every indexed row name", arguments: languages)
    func pageAgreesWithTheSidebar(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        var disagreements: [String] = []
        for item in SettingsNavigation.availableItems(capabilities: Self.capabilities) {
            let names = item.searchTargets(capabilities: Self.capabilities).flatMap(\.rows) + item.rows
            for name in names {
                let query = name.localized(in: bundle)
                let result = SettingsNavigation.filteredResults(matching: query, capabilities: Self.capabilities)
                    .first { $0.destination == item.destination }
                let focus = item.searchFocus(matching: query, capabilities: Self.capabilities)
                if focus?.anchor != result?.anchor || focus?.rows.contains(name) != true {
                    disagreements.append("`\(query)` on \(item.destination.rawValue): sidebar \(String(describing: result?.anchor)), page \(String(describing: focus))")
                }
            }
        }
        #expect(disagreements.isEmpty, Comment(rawValue: "\(language): \(disagreements.count) disagree, e.g. \(disagreements.prefix(3))"))
    }
}
