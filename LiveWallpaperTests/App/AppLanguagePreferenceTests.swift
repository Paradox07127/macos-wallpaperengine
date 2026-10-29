import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("App language preference", .serialized) @MainActor
struct AppLanguagePreferenceTests {
    @Test("Language choices include system and all nine supported locales")
    func languageChoicesExposeSupportedLocales() {
        #expect(AppLanguagePreference.allCases == [.system, .english, .simplifiedChinese, .traditionalChinese, .japanese, .spanish, .german, .french, .korean, .brazilianPortuguese])
        #expect(AppLanguagePreference.german.localeIdentifier == "de")
        #expect(AppLanguagePreference.french.localeIdentifier == "fr")
        #expect(AppLanguagePreference.korean.localeIdentifier == "ko")
        #expect(AppLanguagePreference.brazilianPortuguese.localeIdentifier == "pt-BR")
        #expect(AppLanguagePreference.system.localeIdentifier == nil)
        #expect(AppLanguagePreference.english.localeIdentifier == "en")
        #expect(AppLanguagePreference.simplifiedChinese.localeIdentifier == "zh-Hans")
        #expect(AppLanguagePreference.traditionalChinese.localeIdentifier == "zh-Hant")
        #expect(AppLanguagePreference.japanese.localeIdentifier == "ja")
        #expect(AppLanguagePreference.spanish.localeIdentifier == "es")
        #expect(AppLanguagePreference.menuCases == [
            .system, .german, .english, .spanish, .french, .japanese, .korean,
            .brazilianPortuguese, .simplifiedChinese, .traditionalChinese,
        ])
        #expect(Set(AppLanguagePreference.menuCases) == Set(AppLanguagePreference.allCases))
    }

    @Test("Language menu names stay in that language")
    func languageMenuUsesEndonyms() {
        #expect(AppLanguagePreference.german.endonym == "Deutsch")
        #expect(AppLanguagePreference.french.endonym == "Français")
        #expect(AppLanguagePreference.korean.endonym == "한국어")
        #expect(AppLanguagePreference.brazilianPortuguese.endonym == "Português (Brasil)")
        #expect(AppLanguagePreference.system.endonym == nil)
        #expect(AppLanguagePreference.english.endonym == "English")
        #expect(AppLanguagePreference.simplifiedChinese.endonym == "简体中文")
        #expect(AppLanguagePreference.traditionalChinese.endonym == "繁體中文")
        #expect(AppLanguagePreference.japanese.endonym == "日本語")
        #expect(AppLanguagePreference.spanish.endonym == "Español")
    }

    @Test("App UI languages map to official Wallpaper Engine language codes")
    func wallpaperEngineLanguageCodesFollowTheResolvedUILanguage() {
        #expect(AppLanguagePreference.german.wallpaperEngineLanguageCode() == "de-de")
        #expect(AppLanguagePreference.french.wallpaperEngineLanguageCode() == "fr-fr")
        #expect(AppLanguagePreference.korean.wallpaperEngineLanguageCode() == "ko-kr")
        #expect(AppLanguagePreference.brazilianPortuguese.wallpaperEngineLanguageCode() == "pt-br")
        #expect(AppLanguagePreference.english.wallpaperEngineLanguageCode() == "en-us")
        #expect(AppLanguagePreference.simplifiedChinese.wallpaperEngineLanguageCode() == "zh-chs")
        #expect(AppLanguagePreference.traditionalChinese.wallpaperEngineLanguageCode() == "zh-cht")
        #expect(AppLanguagePreference.japanese.wallpaperEngineLanguageCode() == "ja-jp")
        #expect(AppLanguagePreference.spanish.wallpaperEngineLanguageCode() == "es-es")
        #expect(AppLanguagePreference.system.wallpaperEngineLanguageCode(
            preferredLocalization: "zh-Hant"
        ) == "zh-cht")
        #expect(AppLanguagePreference.system.wallpaperEngineLanguageCode(
            preferredLocalization: "es-MX"
        ) == "es-es")
        #expect(AppLanguagePreference.system.wallpaperEngineLanguageCode(
            preferredLocalization: "pt_BR"
        ) == "pt-br")
        #expect(AppLanguagePreference.system.wallpaperEngineLanguageCode(
            preferredLocalization: "nl"
        ) == "en-us")
    }

    @Test("Settings reset clears the saved language")
    func settingsResetClearsSavedLanguage() async throws {
        // Assert on the manager's own domain, not `AppLanguagePreference.current`: that global
        // reads `.standard`, so driving it from here would run the wipe on the user's defaults.
        let scratch = try TestScratch.defaultsSuite("AppLanguagePreferenceTests.reset")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLanguageReset-\(UUID().uuidString)", isDirectory: true)

        let manager = SettingsManager(directory: ConfigurationDirectory(root: root), defaults: defaults)
        defaults.set(AppLanguagePreference.simplifiedChinese.rawValue, forKey: AppLanguagePreference.storageKey)

        manager.cleanAllSettings(applyLoginSetting: false)

        #expect(defaults.object(forKey: AppLanguagePreference.storageKey) == nil)
        await TestScratch.discard(root, flushing: manager)
    }
}
