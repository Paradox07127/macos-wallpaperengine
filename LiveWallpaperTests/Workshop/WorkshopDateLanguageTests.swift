#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop dates and counts follow the app language")
@MainActor
struct WorkshopDateLanguageTests {
    @Test
    func detailHeaderDateUsesTheAppLanguage() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let japanese = DateFormatter()
        japanese.locale = Locale(identifier: "ja")
        japanese.dateStyle = .medium
        japanese.timeStyle = .none

        let shown = AppLanguageOverride.with(.japanese) { WorkshopDetailIdentityHeader.mediumDate(date) }

        #expect(shown == japanese.string(from: date), "the header date followed the system language, not the app's")
    }

    @Test
    func relativeDateUsesTheAppLanguage() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86400)
        let japanese = RelativeDateTimeFormatter()
        japanese.locale = Locale(identifier: "ja")
        japanese.unitsStyle = .short

        let shown = AppLanguageOverride.with(.japanese) { WorkshopRelativeDateFormatter.string(threeDaysAgo) }

        #expect(
            shown == japanese.localizedString(for: threeDaysAgo, relativeTo: Date()),
            "the relative date followed the system language, not the app's"
        )
    }

    @Test
    func compactCountUsesTheAppLanguageDecimalSeparator() {
        let shown = AppLanguageOverride.with(.spanish) { WorkshopCountFormatter.compact(1500) }

        #expect(shown == "1,5K", "the compact count took its decimal separator from the system language, not the app's")
    }

    @Test
    func detailHeaderSubscriberCountUsesTheAppLanguageDecimalSeparator() {
        let shown = AppLanguageOverride.with(.spanish) { WorkshopDetailIdentityHeader.formatSubs(1500) }

        #expect(shown.contains("1,5"), "the spelled-out subscriber count took its decimal separator from the system language: \(shown)")
    }
}
#endif
