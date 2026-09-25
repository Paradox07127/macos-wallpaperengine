import Foundation
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// The host process runs under the system locale (en-US), so a Chinese result is only
/// possible if the API really honours the requested locale.
@Suite("App language runtime probe")
struct AppLanguageRuntimeProbeTests {
    private static let key = "All set"
    private static let zhHans = "全部就绪"

    /// So every English result below is a routing problem, not a missing string.
    @Test("Control — the zh-Hans bundle has the translation")
    func controlBundleLookupWorks() {
        let viaBundle = AppLanguagePreference.simplifiedChinese
            .localizationBundle()
            .localizedString(forKey: Self.key, value: nil, table: nil)
        #expect(viaBundle == Self.zhHans)
    }

    @Test("String(localized:) ignores the app preference")
    func plainStringLocalizedIgnoresPreference() {
        let value = String(localized: String.LocalizationValue(Self.key))
        #expect(value != Self.zhHans, "got \(value)")
    }

    @Test("Candidate A — String(localized:locale:) does NOT re-route")
    func candidateExplicitLocaleIsIgnored() {
        let value = String(
            localized: String.LocalizationValue(Self.key),
            locale: Locale(identifier: "zh-Hans")
        )
        #expect(value != Self.zhHans, "the locale argument started working — got \(value)")
    }

    @Test("Candidate B — String(localized:bundle:)")
    func candidateExplicitBundle() {
        let value = String(
            localized: String.LocalizationValue(Self.key),
            bundle: AppLanguagePreference.simplifiedChinese.localizationBundle()
        )
        #expect(value == Self.zhHans, "String(localized:bundle:) returned \(value)")
    }

    /// Guards the whole fix: if this ever returns English again, every localized string in the
    /// app is silently back on the system language.
    @Test("Bundle.appLanguage routes String(localized:) to the picked language")
    func appLanguageBundleRoutes() {
        // Pick the language here rather than assume it: the host reads the
        // app's real preference, which is whatever this Mac happens to be set to.
        AppLanguageOverride.with(.simplifiedChinese) {
            let value = String(localized: String.LocalizationValue(Self.key), bundle: .appLanguage)
            #expect(value == Self.zhHans, "Bundle.appLanguage returned \(value)")
        }
    }

    @Test("Candidate C — LocalizedStringResource with an explicit locale")
    func candidateLocalizedStringResource() {
        let resource = LocalizedStringResource(
            String.LocalizationValue(Self.key),
            locale: Locale(identifier: "zh-Hans")
        )
        let value = String(localized: resource)
        #expect(value == Self.zhHans, "LocalizedStringResource returned \(value)")
    }

    /// Can't live in the package's own tests: that process's `Bundle.main` does not carry
    /// the app target's compiled `Localizable.xcstrings`, so routing is only observable here.
    @Test("Inline HTML source display name follows the app language preference")
    func inlineHTMLSourceDisplayNameFollowsAppLanguage() {
        AppLanguageOverride.with(.simplifiedChinese) {
            #expect(HTMLSource.inline("<html></html>").displayName == "内嵌网页内容")
        }
    }

    /// The bundle only picks the table; the `locale:` argument picks the plural rule. With an
    /// English app on a Chinese Mac that argument defaults to Chinese, which has no `one`.
    @Test("String(localized:bundle:locale:) picks the plural variant by the locale argument")
    func pluralVariantFollowsLocaleArgument() {
        let english = AppLanguagePreference.english.localizationBundle()
        let spanish = AppLanguagePreference.spanish.localizationBundle()
        func wallpapers(_ count: Int, _ bundle: Bundle, _ locale: String) -> String {
            String(localized: "\(count) wallpapers", bundle: bundle, locale: Locale(identifier: locale))
        }
        #expect(wallpapers(1, english, "en") == "1 wallpaper")
        #expect(wallpapers(2, english, "en") == "2 wallpapers")
        #expect(wallpapers(3094, english, "en") == "3,094 wallpapers")
        #expect(wallpapers(1, spanish, "es") == "1 fondo de pantalla")
        #expect(wallpapers(2, spanish, "es") == "2 fondos de pantalla")
        #expect(wallpapers(1, english, "zh-Hans") == "1 wallpapers")
        #expect(wallpapers(1, spanish, "zh-Hans") == "1 fondos de pantalla")
        #expect(String(localized: "\(1) wallpapers", bundle: english) == wallpapers(1, english, Locale.current.identifier))
    }

    @MainActor
    @Test("Text picks the plural variant by its \\.locale environment")
    func textPluralVariantFollowsEnvironmentLocale() {
        func wallpapers(_ count: Int, _ locale: String) -> String {
            var environment = EnvironmentValues()
            environment.locale = Locale(identifier: locale)
            return Text("\(count) wallpapers")._resolveText(in: environment)
        }
        #expect(wallpapers(1, "en") == "1 wallpaper")
        #expect(wallpapers(2, "en") == "2 wallpapers")
        #expect(wallpapers(3094, "en") == "3,094 wallpapers")
        #expect(wallpapers(1, "es") == "1 fondo de pantalla")
        #expect(wallpapers(2, "es") == "2 fondos de pantalla")
        #expect(wallpapers(1, "zh-Hans") == "1 个壁纸")
    }

    /// The form a few call sites use: the catalog value comes back as a raw format that
    /// `String(format:)` fills in later, with no locale.
    @Test("A raw plural format passed to String(format:) keeps its variants")
    func rawPluralFormatKeepsVariants() {
        let english = String(localized: "Copied to %lld / %lld displays", bundle: AppLanguagePreference.english.localizationBundle())
        let spanish = String(localized: "Copied to %lld / %lld displays", bundle: AppLanguagePreference.spanish.localizationBundle())
        #expect(String(format: english, Int64(1), Int64(1)) == "Copied to 1 / 1 display")
        #expect(String(format: english, Int64(1), Int64(2)) == "Copied to 1 / 2 displays")
        #expect(String(format: spanish, Int64(1), Int64(1)) == "Copiado a 1 / 1 pantalla")
        #expect(String(format: spanish, Int64(2), Int64(3)) == "Copiado a 2 / 3 pantallas")
    }
}
