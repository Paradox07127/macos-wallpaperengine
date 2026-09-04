import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("App language preference", .serialized) @MainActor
struct AppLanguagePreferenceTests {
    @Test("Language choices include system, English, Chinese, Japanese, and Spanish")
    func languageChoicesExposeSupportedLocales() {
        #expect(AppLanguagePreference.allCases == [.system, .english, .simplifiedChinese, .traditionalChinese, .japanese, .spanish])
        #expect(AppLanguagePreference.system.localeIdentifier == nil)
        #expect(AppLanguagePreference.english.localeIdentifier == "en")
        #expect(AppLanguagePreference.simplifiedChinese.localeIdentifier == "zh-Hans")
        #expect(AppLanguagePreference.traditionalChinese.localeIdentifier == "zh-Hant")
        #expect(AppLanguagePreference.japanese.localeIdentifier == "ja")
        #expect(AppLanguagePreference.spanish.localeIdentifier == "es")
        #expect(AppLanguagePreference.menuCases == [
            .system, .english, .spanish, .japanese, .simplifiedChinese, .traditionalChinese,
        ])
        #expect(Set(AppLanguagePreference.menuCases) == Set(AppLanguagePreference.allCases))
    }

    @Test("Language menu names stay in that language")
    func languageMenuUsesEndonyms() {
        #expect(AppLanguagePreference.system.endonym == nil)
        #expect(AppLanguagePreference.english.endonym == "English")
        #expect(AppLanguagePreference.simplifiedChinese.endonym == "简体中文")
        #expect(AppLanguagePreference.traditionalChinese.endonym == "繁體中文")
        #expect(AppLanguagePreference.japanese.endonym == "日本語")
        #expect(AppLanguagePreference.spanish.endonym == "Español")
    }

    @Test("The language picker renders endonyms, not catalog keys")
    func languagePickerRendersEndonyms() throws {
        let picker = try RepositoryRoot.source("LiveWallpaper/Views/Settings/GeneralSection.swift")
        #expect(picker.contains("language.pickerLabel"))
        #expect(picker.contains("AppLanguagePreference.menuCases"))
        #expect(!picker.contains("AppLanguagePreference.allCases"))
        #expect(!picker.contains("language.titleKey"))

        let model = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/App/AppLanguagePreference.swift"
        )
        #expect(model.contains("Text(verbatim: endonym)"))
        #expect(!model.contains("var titleKey: LocalizedStringKey"))
    }

    @Test("App UI languages map to official Wallpaper Engine language codes")
    func wallpaperEngineLanguageCodesFollowTheResolvedUILanguage() {
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
            preferredLocalization: "de"
        ) == "en-us")
    }

    @Test("Saved language preference round-trips through an injected domain")
    func savedPreferencePersists() throws {
        let scratch = try TestScratch.defaultsSuite("AppLanguagePreferenceTests.roundTrip")
        let defaults = scratch.defaults
        defer { scratch.discard() }

        #expect(AppLanguagePreference.current(in: defaults) == .system)

        AppLanguagePreference.save(.simplifiedChinese, to: defaults)
        #expect(AppLanguagePreference.current(in: defaults) == .simplifiedChinese)

        AppLanguagePreference.save(.system, to: defaults)
        #expect(defaults.object(forKey: AppLanguagePreference.storageKey) == nil)
    }

    @Test("Settings reset clears the saved language")
    func settingsResetClearsSavedLanguage() async throws {
        // Asserts on the manager's own domain rather than `AppLanguagePreference
        // .current`: that global reads `.standard`, and driving it from here meant
        // running the wipe against the user's real defaults on every suite run.
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
