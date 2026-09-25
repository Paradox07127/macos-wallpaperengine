import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// Bundles are resolved explicitly rather than by flipping the process-wide app
/// language, which is global state shared with other suites.
@Suite("Settings search indexes every supported language")
struct SettingsSearchLocalizationTests {
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "es"]

    private func bundle(for language: String) throws -> Bundle {
        let path = try #require(
            Bundle.main.path(forResource: language, ofType: "lproj"),
            "\(language).lproj missing from the app bundle"
        )
        return try #require(Bundle(path: path), "\(language).lproj is not a loadable bundle")
    }

    @Test("Every navigation title is searchable in its own language", arguments: languages)
    func titlesAreSearchableInEachLanguage(language: String) throws {
        let bundle = try bundle(for: language)

        for item in SettingsNavigation.allItems {
            let localizedTitle = item.title.localized(in: bundle)
            #expect(
                !localizedTitle.isEmpty,
                Comment(rawValue: "\(language): `\(item.title)` resolved to an empty string")
            )
            // One index carries every language, so this asserts cross-language search:
            // the zh title must be findable even when the app runs in English.
            let haystack = item.searchableText()
            #expect(
                haystack.localizedCaseInsensitiveContains(localizedTitle),
                Comment(rawValue: "\(language): searching `\(localizedTitle)` cannot find \(item.destination.rawValue)")
            )
        }
    }

    @Test("The English key stays searchable in every language", arguments: languages)
    func englishKeyStaysSearchable(language: String) throws {
        // The index no longer varies by language; resolving the bundle still asserts
        // that this language ships at all.
        _ = try bundle(for: language)

        for item in SettingsNavigation.allItems {
            #expect(item.searchableText().localizedCaseInsensitiveContains(item.title))
        }
    }

    /// Without this, the suite would pass against an index that never localized anything.
    @Test("Non-English catalogs really do translate the titles", arguments: ["zh-Hans", "zh-Hant", "ja", "es"])
    func nonEnglishTitlesDifferFromKeys(language: String) throws {
        let bundle = try bundle(for: language)
        let translated = SettingsNavigation.allItems.filter { item in
            item.title.localized(in: bundle) != item.title
        }
        #expect(
            !translated.isEmpty,
            Comment(rawValue: "\(language) resolved every title back to its English key")
        )
    }

    /// Several sections can share a row name (Volume, Frame Rate), so any section carrying
    /// the queried text in this language is a correct landing.
    @Test("Every indexed row name finds its own section", arguments: languages)
    func everyRowNameFindsItsSection(language: String) throws {
        let bundle = try bundle(for: language)
        let capabilities = ProductCapabilities.pro.withWorkshopOnline()

        // Only pages this OS offers: System Wallpaper needs macOS 26, and search never returns it before that.
        for item in SettingsNavigation.availableItems(capabilities: capabilities) {
            let targets = item.searchTargets(capabilities: capabilities)
            var sections: [(anchor: SettingsSearchAnchor?, names: [String])] = targets.map { ($0.anchor, [$0.label] + $0.rows) }
            sections.append((nil, item.rows))
            for section in sections {
                for name in section.names {
                    let query = name.localized(in: bundle)
                    let result = SettingsNavigation.filteredResults(matching: query, capabilities: capabilities)
                        .first { $0.destination == item.destination }
                    guard let result else {
                        Issue.record(Comment(rawValue: "\(language): `\(query)` (\(name)) finds no result on \(item.destination.rawValue)"))
                        continue
                    }
                    let sameName = targets.filter { target in
                        ([target.label] + target.rows).contains {
                            $0.localized(in: bundle).localizedCaseInsensitiveCompare(query) == .orderedSame
                        }
                    }
                    let expected: [SettingsSearchAnchor?] = section.anchor == nil ? [nil] : sameName.map(\.anchor)
                    #expect(
                        expected.contains(result.anchor),
                        Comment(rawValue: "\(language): `\(query)` (\(name)) lands on \(result.anchor?.rawValue ?? "the page"), not \(section.anchor?.rawValue ?? "the page")")
                    )
                }
            }
        }
    }

    /// The style keywords are hand-written strings; this is what keeps them equal to the catalog's names.
    @Test("The shelf's current style names reach the Shelf style section", arguments: languages)
    func shelfStyleNamesReachTheShelfSection(language: String) throws {
        let bundle = try bundle(for: language)
        for style in ["Facing In", "Crate", "Folders", "Fan", "Focus Row"] {
            let query = style.localized(in: bundle)
            let anchor = SettingsNavigation.filteredResults(matching: query, capabilities: .pro)
                .first { $0.destination == .general }?.anchor
            #expect(
                anchor == .generalAppearance,
                Comment(rawValue: "\(language): `\(query)` (\(style)) lands on \(anchor?.rawValue ?? "nothing")")
            )
        }
    }

    @Test("A retired shelf style name no longer reaches General")
    func retiredShelfStyleNamesAreNotIndexed() {
        for query in ["cover flow", "封面流"] {
            let reachesGeneral = SettingsNavigation.filteredResults(matching: query, capabilities: .pro)
                .contains { $0.destination == .general }
            #expect(!reachesGeneral, Comment(rawValue: "`\(query)` still reaches General"))
        }
    }

    @Test("Every settings row title is indexed and every indexed name is catalogued")
    func everySettingRowIsIndexed() throws {
        let capabilities = ProductCapabilities.pro.withWorkshopOnline()
        let indexed = Set(SettingsNavigation.allItems.flatMap { item in
            item.rows + item.searchTargets(capabilities: capabilities).flatMap { [$0.label] + $0.rows }
        })

        var titles: [String] = []
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views/Settings") {
            let source = try String(contentsOf: file, encoding: .utf8)
            titles += try Self.captures(Self.settingRowTitle, in: source).flatMap { try Self.captures(Self.literal, in: $0) }
            titles += try Self.captures(Self.tileTitle, in: source) + Self.captures(Self.sectionHeader, in: source)
        }
        #expect(titles.count > 60, Comment(rawValue: "The scan found \(titles.count) titles; its patterns or directory drifted"))

        let missing = Set(titles).subtracting(indexed).sorted()
        #expect(
            missing.isEmpty,
            Comment(rawValue: "\(missing.count) titles are not indexed: \(missing.prefix(8).joined(separator: ", "))")
        )

        let uncatalogued = try indexed.subtracting(Self.catalogKeys()).sorted()
        #expect(
            uncatalogued.isEmpty,
            Comment(rawValue: "Indexed names missing from Localizable.xcstrings: \(uncatalogued.joined(separator: ", "))")
        )

        for action in GlobalShortcutAction.allCases {
            let result = SettingsNavigation.filteredResults(matching: action.displayName, capabilities: capabilities)
                .first { $0.destination == .shortcuts }
            #expect(
                result?.anchor == .shortcutsGlobal,
                Comment(rawValue: "`\(action.displayName)` does not reach Global Shortcuts")
            )
        }
    }

    /// The one test here that flips the app language: the hint reads `Bundle.appLanguage`, which no bundle argument reaches.
    @Test("A hint that matches neither a name nor a keyword shows the localized section label")
    func fallbackHintIsLocalized() {
        AppLanguageOverride.with(.simplifiedChinese) {
            let expected = "Video".localized(in: .appLanguage)
            #expect(expected != "Video", "zh-Hans did not translate Video, so the check below proves nothing")

            // "video" is the section's label and "fps" one of its keywords; no single name or keyword holds both.
            let result = SettingsNavigation.filteredResults(matching: "video fps", capabilities: .pro)
                .first { $0.destination == .displayDefaults }
            #expect(result?.anchor == .displayDefaultsVideo)
            #expect(result?.matchHint == expected)
        }
    }

    private static let literal = #""((?:[^"\\\n]|\\.)*)""#
    /// Group 1 is the whole `title:` argument, so both branches of a ternary are read.
    private static let settingRowTitle = #"SettingRow\([^{]*?\btitle:\s*((?:"(?:[^"\\\n]|\\.)*"|[^,)"\n])*)"#
    private static let tileTitle = #"StorageDashboardTile\(\s*title:\s*"# + literal
    private static let sectionHeader = #"SettingsSearchSectionHeader\(\s*"# + literal

    private static func captures(_ pattern: String, in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    private static func catalogKeys() throws -> Set<String> {
        let data = try RepositoryRoot.data("LiveWallpaper/Resources/Localizable.xcstrings")
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        return Set(strings.keys)
    }
}
