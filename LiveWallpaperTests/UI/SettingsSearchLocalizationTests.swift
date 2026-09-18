import Foundation
@testable import LiveWallpaper
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
}
