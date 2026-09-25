import Foundation
import Testing

@Suite("Plural count copy")
struct PluralCountCopyTests {
    /// Nouns whose count is never 1 where the app shows them.
    private static let exemptNouns: Set<String> = ["cores", "seconds", "bytes", "points", "pixels"]

    /// Counted keys that stay one form, and why.
    private static let exemptKeys: [String: String] = [
        "%@ stars": "one decimal place, and 1.0 is CLDR `other` in English and Spanish",
        "%@ favorites": "compact count from 1,000 up; below that the %lld key is used",
        "%@ views": "compact count from 1,000 up; below that the %lld key is used",
        "%@ subscribers": "compact count from 1,000 up; below that the %lld key is used",
        "%@ subs": "no call site",
        "All %@ time-based wallpaper rules will be cleared. The current wallpaper stays applied.": "no call site",
        "Deletes %@ scratch items · %@ created by test runs in the container's tmp folder. Nothing else reads them.": "no call site",
        "Skipped %lld displays that changed afterward.": "only for 2 or more; one display gets a message naming it",
        "Created a playlist of %lld videos on %@": "only a drop of 2 or more videos becomes a playlist",
        "Showing the top %lld of %lld presets.": "the total is only shown when it exceeds the one or more loaded",
    ]

    private static let functionWords: Set<String> = [
        "a", "all", "an", "and", "are", "as", "at", "be", "been", "by", "each", "every", "for", "from", "had", "has",
        "have", "if", "in", "into", "is", "it", "its", "less", "more", "no", "not", "of", "on", "or", "per", "so",
        "than", "that", "the", "then", "these", "this", "those", "to", "via", "was", "were", "with",
    ]
    /// Words ending in s that are not plural nouns.
    private static let notPlural: Set<String> = [
        "across", "afterwards", "always", "does", "ends", "has", "is", "its", "perhaps", "plus", "starts", "this",
        "towards", "unless", "was",
    ]

    /// The plural noun a count placeholder counts, up to two words after it ("%lld saved bookmarks").
    static func countedNoun(in key: String) -> String? {
        for match in key.matches(of: #/%(?:\d+\$)?(?:lld|ld|d|llu|lu|u|@) /#) {
            var rest = key[match.range.upperBound...]
            for _ in 0 ..< 3 {
                guard let word = rest.prefixMatch(of: /[A-Za-z][A-Za-z'-]*/)?.output else { break }
                let text = String(word)
                if functionWords.contains(text.lowercased()) {
                    break
                }
                if text.wholeMatch(of: /[A-Za-z'-]*[a-z]s/) != nil, !text.hasSuffix("ss"), !notPlural.contains(text.lowercased()) {
                    return text
                }
                rest = rest[word.endIndex...]
                guard rest.first == " " else { break }
                rest = rest.dropFirst()
            }
        }
        return nil
    }

    @Test("A count followed by a plural noun has one and other forms in English and Spanish")
    func countedNounsVaryByPlural() throws {
        #expect(Self.countedNoun(in: "Restored %lld saved bookmarks.") == "bookmarks")
        #expect(Self.countedNoun(in: "Copied to %lld / %lld displays") == "displays")
        #expect(Self.countedNoun(in: "Couldn't add %@ to Bookmarks.") == nil)
        #expect(Self.countedNoun(in: "Time slot %@ starts and ends at the same hour.") == nil)
        #expect(Self.countedNoun(in: "%lld FPS") == nil)

        let catalog = try JSONDecoder().decode(Catalog.self, from: RepositoryRoot.data("LiveWallpaper/Resources/Localizable.xcstrings"))
        var counted = 0
        var singularMissing: [String] = []
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) {
            guard let noun = Self.countedNoun(in: key), !Self.exemptNouns.contains(noun.lowercased()), Self.exemptKeys[key] == nil else { continue }
            counted += 1
            for locale in ["en", "es"] where !Set(["one", "other"]).isSubset(of: entry.localizations?[locale]?.pluralForms ?? []) {
                singularMissing.append("\(key) [\(locale)]")
            }
        }

        #expect(counted > 30, "Only \(counted) counted keys matched — the scan stopped matching")
        #expect(singularMissing.isEmpty, "No one form, so a count of 1 reads \"1 wallpapers\": \(singularMissing.joined(separator: "; "))")
        let stale = Self.exemptKeys.keys.filter { key in catalog.strings[key] == nil || Self.countedNoun(in: key) == nil }
        #expect(stale.isEmpty, "Exempt keys no longer in the catalog or no longer counted: \(stale.sorted())")
    }

    @Test("A count is never hedged with (s)")
    func countsAreNotHedged() throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: RepositoryRoot.data("LiveWallpaper/Resources/Localizable.xcstrings"))
        let hedged = catalog.strings.keys.filter { $0.contains(#/%(?:\d+\$)?(?:lld|ld|d|llu|lu|u|@) [A-Za-z'-]+\(s\)/#) }
        #expect(hedged.isEmpty, "Hedged with (s) where a plural form belongs: \(hedged.sorted())")
    }

    private struct Catalog: Decodable {
        let strings: [String: Entry]

        struct Entry: Decodable {
            let localizations: [String: Localization]?
        }

        struct Localization: Decodable {
            let variations: Variations?
            let substitutions: [String: Substitution]?

            /// The plural forms written, whether for the whole value or in a substitution.
            var pluralForms: Set<String> {
                Set((variations?.plural ?? [:]).keys).union((substitutions ?? [:]).values.flatMap { ($0.variations?.plural ?? [:]).keys })
            }
        }

        struct Variations: Decodable {
            let plural: [String: Form]?
        }

        struct Form: Decodable {}

        struct Substitution: Decodable {
            let variations: Variations?
        }
    }
}
