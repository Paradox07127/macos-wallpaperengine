import Foundation
import Testing
@testable import LiveWallpaperCore

/// Which string-lookup APIs actually follow the in-app language preference?
///
/// The app picks its language through SwiftUI's `\.locale` environment
/// (`AppLanguageScope`). `Text(LocalizedStringKey)` reads that environment, but
/// anything that produces a plain `String` resolves at evaluation time against
/// `Locale.current` — the *system* language. This suite pins down which of the
/// candidate replacements actually re-routes, so the fix is not chosen from
/// blog posts.
///
/// The host process runs under the system locale (en-US here), so "returns
/// Chinese" is only possible if the API really honours the requested locale.
@Suite("App language runtime probe")
struct AppLanguageRuntimeProbeTests {
    private static let key = "All set"
    private static let zhHans = "全部就绪"

    /// Control: the catalog really does ship a zh-Hans translation, so every
    /// English result below is a routing problem, not a missing string.
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

    /// Measured 2026-08-29: the `locale:` argument is accepted and then ignored —
    /// the result still comes back in the system language. The obvious fix is
    /// the one that does not work, so this is pinned rather than left to memory.
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

    /// The shape the 710 call sites were rewritten to. Guards the whole fix:
    /// if this ever returns English again, every `String(localized:)` in the app
    /// is silently back on the system language.
    @Test("Bundle.appLanguage routes String(localized:) to the picked language")
    func appLanguageBundleRoutes() {
        let value = String(localized: String.LocalizationValue(Self.key), bundle: .appLanguage)
        #expect(value == Self.zhHans, "Bundle.appLanguage returned \(value)")
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
}
