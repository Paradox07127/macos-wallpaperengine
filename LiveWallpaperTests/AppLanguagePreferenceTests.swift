import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("App language preference", .serialized) @MainActor
struct AppLanguagePreferenceTests {
    @Test("Language choices include system, English, Chinese, and Japanese")
    func languageChoicesExposeSupportedLocales() {
        #expect(AppLanguagePreference.allCases == [.system, .english, .simplifiedChinese, .traditionalChinese, .japanese])
        #expect(AppLanguagePreference.system.localeIdentifier == nil)
        #expect(AppLanguagePreference.english.localeIdentifier == "en")
        #expect(AppLanguagePreference.simplifiedChinese.localeIdentifier == "zh-Hans")
        #expect(AppLanguagePreference.traditionalChinese.localeIdentifier == "zh-Hant")
        #expect(AppLanguagePreference.japanese.localeIdentifier == "ja")
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
