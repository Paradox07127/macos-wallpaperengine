#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop dates follow the app language")
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
}
#endif
