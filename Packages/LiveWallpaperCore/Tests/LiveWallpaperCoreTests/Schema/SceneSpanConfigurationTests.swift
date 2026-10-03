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

    @Test("Switching back to a saved video or page leaves the span group")
    func savedWallpaperActivationLeavesGroup() {
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(descriptor))
        configuration.savedVideoBookmarkData = Data([1])
        configuration.savedHTMLSource = .inline("page")
        configuration.sceneSpanGroupID = UUID()
        let videoActivated = configuration.activateSavedVideoWallpaper()
        #expect(videoActivated)
        #expect(configuration.sceneSpanGroupID == nil)
        configuration.sceneSpanGroupID = UUID()
        let pageActivated = configuration.activateSavedHTMLWallpaper()
        #expect(pageActivated)
        #expect(configuration.sceneSpanGroupID == nil)
    }

    @Test("A playlist entry that is not a scene leaves the span group")
    func automationEntryLeavesGroup() {
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(descriptor))
        configuration.sceneSpanGroupID = UUID()
        let video = configuration.applyingAutomationEntry(.init(title: "", content: .video(bookmarkData: Data([2]), packageEntryName: nil)))
        #expect(video.sceneSpanGroupID == nil)
        let page = configuration.applyingAutomationEntry(.init(title: "", content: .html(source: .inline("page"), config: .default)))
        #expect(page.sceneSpanGroupID == nil)
    }

    @Test("A saved scheme carries no span membership")
    func strippedSchemeLeavesGroup() {
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(descriptor))
        configuration.sceneSpanGroupID = UUID()
        #expect(ScreenScheme.stripped(configuration).sceneSpanGroupID == nil)
    }
}
