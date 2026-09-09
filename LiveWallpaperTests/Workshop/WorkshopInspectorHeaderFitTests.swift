#if !LITE_BUILD
import AppKit
import CoreText
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// Does the online inspector's masthead survive its narrowest column?
///
/// The column is resizable from `Inspector.minWidth` and the sheet insets its
/// content by `Spacing.lg` on both sides, so a row has 236pt to live in. What
/// a row costs is measured here rather than eyeballed: the fonts are the ones
/// the view asks for, and the strings come out of the shipped catalog, because
/// Spanish runs wider than English everywhere and overflows first.
/// The shipped languages, outside the actor so `@Test(arguments:)` can read them.
private let shippedLocales = ["en", "zh-Hans", "zh-Hant", "ja", "es"]

@MainActor
@Suite("Workshop inspector header fit")
struct WorkshopInspectorHeaderFitTests {
    static let contentWidth = DesignTokens.Inspector.minWidth - 2 * DesignTokens.Spacing.lg

    // MARK: - Measurement

    private static func font(_ style: NSFont.TextStyle, weight: NSFont.Weight? = nil) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        guard let weight else { return base }
        return NSFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// SF Symbols are laid out by the image system, not by CoreText, so they
    /// are measured as images at the point size the view gives them.
    private static func symbolWidth(_ name: String, pointSize: CGFloat) -> CGFloat {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        else {
            Issue.record("no SF Symbol named \(name)")
            return 0
        }
        return image.size.width
    }

    // MARK: - The strings a row is built from

    /// A representative popular item: the counts and the rating are the widest
    /// shapes the formatters produce (7-figure subs, 4-figure ratings).
    enum Fixture {
        static let subs = 1_300_000
        static let views = 38400
        static let favorites = 72600
        static let ratings = 9751
        static let sizeBytes: Int64 = 176_160_768
        static let author = "🌸Becco38🌸"
        static let posted = Date(timeIntervalSince1970: 1_706_140_800)
        static let updated = Date(timeIntervalSince1970: 1_706_400_000)
    }

    private static func catalog(_ key: String, _ locale: String) throws -> String {
        let strings = try WorkshopTagTaxonomyTests.catalogStrings()
        return try #require(WorkshopTagTaxonomyTests.value(strings, key: key, locale: locale),
                            "\(key) is missing for \(locale)")
    }

    private static func fill(_ template: String, _ values: [String]) -> String {
        var result = template
        for value in values {
            guard let range = result.range(of: "%@") ?? result.range(of: "%lld") else { break }
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    private static func mediumDate(_ date: Date, _ locale: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func relativeDate(_ date: Date, _ locale: String) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - The rows, as the header composes them

    /// One laid-out row: text segments at their own font plus the fixed gaps
    /// between them, mirroring `WorkshopDetailIdentityHeader`. The structure
    /// test below is what keeps the mirror honest.
    private static func rows(for locale: String) throws -> [(name: String, width: CGFloat)] {
        let caption = font(.caption1)
        let subheadline = font(.subheadline)
        let body = font(.body)

        let author = try width(fill(catalog("by %@", locale), [Fixture.author]), subheadline)
            + 3 + symbolWidth("chevron.right", pointSize: 10)

        let ratingCount = try fill(catalog("%@ ratings", locale), [Fixture.ratings.formatted()])
        let stars = 5 * symbolWidth("star.fill", pointSize: 12) + 4
        let rating = stars
            + DesignTokens.Spacing.sm + width("4.9", body)
            + DesignTokens.Spacing.sm + width(ratingCount, caption)

        // Each fact is an atom the flow moves whole, so the row that has to fit
        // is the widest single fact, not their sum.
        let facts: [(String, String)] = [
            ("internaldrive", WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Fixture.sizeBytes)),
            ("person.2", WorkshopCountFormatter.compact(Fixture.subs)),
            ("heart", WorkshopCountFormatter.compact(Fixture.favorites)),
            ("eye", WorkshopCountFormatter.compact(Fixture.views)),
        ]
        let widestFact = facts
            .map { symbolWidth($0.0, pointSize: 10) + 3 + width($0.1, caption) }
            .max() ?? 0

        let updated = try fill(catalog("Updated %@ (%@)", locale),
                               [mediumDate(Fixture.updated, locale), relativeDate(Fixture.updated, locale)])

        return [
            ("author", author),
            ("rating", rating),
            ("widest fact", widestFact),
            ("updated", width(updated, caption)),
        ]
    }

    @Test("No masthead row is wider than the narrowest inspector", arguments: shippedLocales)
    func rowsFitTheNarrowestInspector(locale: String) throws {
        for row in try Self.rows(for: locale) {
            #expect(
                row.width <= Self.contentWidth,
                "\(locale): the \(row.name) row needs \(Int(row.width.rounded()))pt of the \(Int(Self.contentWidth))pt the inspector has"
            )
        }
    }

    /// The measurement above models the view; this is what stops the model from
    /// quietly describing a layout the header no longer has.
    @Test("The header still lays its rows out the way the measurement assumes")
    func structureMatchesTheModel() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/WorkshopDetailIdentityHeader.swift")
        let ratingRow = try #require(source.range(of: "private var ratingRow: some View {"))
        let afterRatingRow = try #require(source.range(of: "// MARK:", range: ratingRow.upperBound ..< source.endIndex))
        #expect(
            !source[ratingRow.upperBound ..< afterRatingRow.lowerBound].contains("authorLine"),
            "author and rating share a row again; measured together they need 380pt of a 236pt column"
        )
        #expect(
            source.contains("WorkshopChipFlow"),
            "the facts stopped wrapping, so the row that has to fit is their sum, not the widest one"
        )
    }
}
#endif
