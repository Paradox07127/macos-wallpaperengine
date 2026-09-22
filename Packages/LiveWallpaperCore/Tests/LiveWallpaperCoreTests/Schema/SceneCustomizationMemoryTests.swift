import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Per-display scene customization memory")
struct SceneCustomizationMemoryTests {
    private func scene(_ id: String, preset: String? = nil) -> SceneDescriptor {
        SceneDescriptor(workshopID: id, cacheRelativePath: "wpe-cache/\(id)",
                        entryFile: "scene.pkg", capabilityTier: .imageOnly,
                        propertyOverrides: preset == nil ? [:] : ["speed": .number(0.7)],
                        presetID: preset, presetSnapshot: preset == nil ? [:] : ["fog": .bool(true)])
    }

    @Test("A to B to restart to A restores both layers; a different display remains independent")
    func restoresAcrossScenesAndRestart() throws {
        let look = scene("A", preset: "calm")
        var config = ScreenConfiguration(screenID: 1, wallpaper: .scene(look))
        config.setSceneWallpaper(scene("B", preset: "bright"), origin: nil)
        config = try JSONDecoder().decode(ScreenConfiguration.self, from: JSONEncoder().encode(config))
        config.setSceneWallpaper(scene("A"), origin: nil)
        #expect(config.activeWallpaper == .scene(look))
        config.setSceneWallpaper(scene("B"), origin: nil)
        #expect(config.activeWallpaper == .scene(scene("B", preset: "bright")))
        var other = ScreenConfiguration(screenID: 2, wallpaper: .scene(scene("B")))
        other.setSceneWallpaper(scene("A"), origin: nil)
        #expect(other.activeWallpaper == .scene(scene("A")))
    }

    @Test("An explicitly chosen preset takes priority over the remembered one")
    func explicitPresetWins() {
        var config = ScreenConfiguration(screenID: 1, wallpaper: .scene(scene("A", preset: "old")))
        config.setSceneWallpaper(scene("B"), origin: nil)
        let next = scene("A", preset: "new")
        config.setSceneWallpaper(next, origin: nil)
        #expect(config.activeWallpaper == .scene(next))
    }

    @Test("Returning to defaults replaces the previous remembered look")
    func clearedPresetStaysCleared() {
        var config = ScreenConfiguration(screenID: 1, wallpaper: .scene(scene("A", preset: "old")))
        config.setSceneWallpaper(scene("B"), origin: nil)
        config.setSceneWallpaper(scene("A"), origin: nil)
        // The inspector commits its explicit selection directly to both current and legacy slots.
        config.activeWallpaper = .scene(scene("A"))
        config.savedSceneDescriptor = scene("A")
        config.setSceneWallpaper(scene("B"), origin: nil)
        config.setSceneWallpaper(scene("A"), origin: nil)
        #expect(config.activeWallpaper == .scene(scene("A")))
        #expect(config.savedSceneCustomizations.count == 2)
    }

    @Test("Old configuration JSON migrates its single saved scene without requiring a new field")
    func legacyConfigurationMigrates() throws {
        var config = ScreenConfiguration(screenID: 1, wallpaper: .html(source: .inline("hello"), config: .default))
        config.savedSceneDescriptor = scene("A", preset: "legacy")
        let data = try JSONEncoder().encode(config)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("savedSceneCustomizations"))
        config = try JSONDecoder().decode(ScreenConfiguration.self, from: data)
        config.setSceneWallpaper(scene("A"), origin: nil)
        #expect(config.activeWallpaper == .scene(scene("A", preset: "legacy")))
    }
}
