import Foundation
import Testing
@testable import LiveWallpaperCore

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
        let previous = UserDefaults.standard.string(forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppLanguagePreference.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLanguagePreference.storageKey)
            }
        }
        AppLanguagePreference.save(.simplifiedChinese)
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

    /// Can't live in the package's own tests: that process's `Bundle.main` does not carry
    /// the app target's compiled `Localizable.xcstrings`, so routing is only observable here.
    @Test("Inline HTML source display name follows the app language preference")
    func inlineHTMLSourceDisplayNameFollowsAppLanguage() {
        let previous = UserDefaults.standard.string(forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppLanguagePreference.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLanguagePreference.storageKey)
            }
        }

        AppLanguagePreference.save(.simplifiedChinese)
        #expect(HTMLSource.inline("<html></html>").displayName == "内嵌网页内容")
    }
}
