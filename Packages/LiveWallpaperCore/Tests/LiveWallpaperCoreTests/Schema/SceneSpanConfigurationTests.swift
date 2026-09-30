import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Scene span configuration persistence")
struct SceneSpanConfigurationTests {
    private var descriptor: SceneDescriptor {
        .init(workshopID: "span-test", cacheRelativePath: "wpe-cache/span-test", entryFile: "scene.json", capabilityTier: .imageOnly)
    }

    @Test("Span membership round-trips while an older config remains independent")
    func roundTripAndLegacyDefault() throws {
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(descriptor))
        let id = UUID()
        configuration.sceneSpanGroupID = id
        let encoded = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(ScreenConfiguration.self, from: encoded).sceneSpanGroupID == id)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sceneSpanGroupID")
        #expect(try JSONDecoder().decode(ScreenConfiguration.self, from: JSONSerialization.data(withJSONObject: object)).sceneSpanGroupID == nil)
    }

    @Test("Selecting a wallpaper independently clears the selected display's membership")
    func independentSelection() {
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(descriptor))
        configuration.sceneSpanGroupID = UUID()
        configuration.setSceneWallpaper(descriptor, origin: nil)
        #expect(configuration.sceneSpanGroupID == nil)
        configuration.sceneSpanGroupID = UUID()
        configuration.replacePrimaryVideo(bookmarkData: Data([1]))
        #expect(configuration.sceneSpanGroupID == nil)
    }
}
