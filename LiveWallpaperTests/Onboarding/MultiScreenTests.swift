import AppKit
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("Onboarding multi-screen primitives")
@MainActor
struct OnboardingMultiScreenTests {

    @Test("Unsupported import recovery copy follows the catalog's scene capability")
    func unsupportedImportCopyFollowsSceneCapability() {
        let liteCatalog = FeatureCatalog(capabilities: .lite)
        let proCatalog = FeatureCatalog(capabilities: .pro)
        let liteSceneCapable = OnboardingImportCopy.sceneCapable(in: liteCatalog)
        let proSceneCapable = OnboardingImportCopy.sceneCapable(in: proCatalog)
        let lite = OnboardingImportCopy.unsupportedFileTypeVariant(sceneCapable: liteSceneCapable)
        let pro = OnboardingImportCopy.unsupportedFileTypeVariant(sceneCapable: proSceneCapable)
        let liteMessage = OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: liteSceneCapable)
        let proMessage = OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: proSceneCapable)

        #expect(!liteSceneCapable)
        #expect(proSceneCapable)
        #expect(lite == .videoAndWeb)
        #expect(pro == .videoWebAndScene)
        #expect(liteMessage == LocalizedStringResource("That file type isn't supported. Pick a video or web page."))
        #expect(proMessage == LocalizedStringResource("That file type isn't supported. Pick a video, web page, or scene."))
    }

    // MARK: - Persistence round-trips for multiple screens

    @Test("WallpaperConfigurationStore writes and reads multiple per-screen configurations")
    func configurationStoreSupportsMultipleScreens() {
        let store = WallpaperConfigurationStore()
        let originalSettings = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalSettings) }
        SettingsManager.shared.replaceAllConfigurations([])
        store.clearCache()

        let firstID: CGDirectDisplayID = 5005
        let secondID: CGDirectDisplayID = 6006
        let firstConfig = ScreenConfiguration(
            screenID: firstID,
            wallpaper: .html(source: .inline("<p>x</p>"), config: .default)
        )
        var secondConfig = firstConfig
        secondConfig.screenID = secondID

        store.save(firstConfig)
        store.save(secondConfig)

        #expect(store.get(for: firstID)?.screenID == firstID)
        #expect(store.get(for: secondID)?.screenID == secondID)
        let loaded = store.loadAll().map(\.screenID).sorted()
        #expect(loaded == [firstID, secondID].sorted())
    }

    @Test("Removing a screen's configuration leaves siblings intact")
    func removingOneScreenConfigurationLeavesOthersIntact() {
        let store = WallpaperConfigurationStore()
        let originalSettings = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalSettings) }
        SettingsManager.shared.replaceAllConfigurations([])
        store.clearCache()

        let primaryID: CGDirectDisplayID = 7007
        let secondaryID: CGDirectDisplayID = 8008
        store.save(ScreenConfiguration(screenID: primaryID, wallpaper: .html(source: .inline("<p>x</p>"), config: .default)))
        store.save(ScreenConfiguration(screenID: secondaryID, wallpaper: .html(source: .inline("<p>x</p>"), config: .default)))

        store.remove(for: primaryID)

        #expect(store.get(for: primaryID) == nil)
        #expect(store.get(for: secondaryID)?.screenID == secondaryID)
    }

    // MARK: - applyConfigurationToAllDisplays single-screen guard

    @Test("applyConfigurationToAllDisplays is a no-op when only one screen is registered")
    func applyToAllNoOpsForSingleScreen() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for single-screen guard test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.saveConfiguration(
            ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("<p>x</p>"), config: .default))
        )

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        let countBefore = SettingsManager.shared.loadConfigurations().count
        manager.applyConfigurationToAllDisplays(from: screen)
        let countAfter = SettingsManager.shared.loadConfigurations().count

        #expect(countBefore == countAfter, "Single-screen apply must not duplicate the configuration")
    }
}
