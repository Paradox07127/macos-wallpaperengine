#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop dates and counts follow the app language")
@MainActor
struct WorkshopDateLanguageTests {
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
}
#endif
