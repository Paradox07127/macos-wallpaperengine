import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("ScreenConfiguration decode defaults")
struct ScreenConfigurationLegacyDefaultsTests {
    /// A config persisted before `frameRateLimit` existed. `encode(to:)` always writes the key,
    /// so this shape only reaches us from an older build's stored JSON.
    private func decodeWithoutFrameRateLimit(
        _ configuration: ScreenConfiguration
    ) throws -> ScreenConfiguration {
        let data = try JSONEncoder().encode(configuration)
        let json = try JSONSerialization.jsonObject(with: data)
        var object = try #require(json as? [String: Any])
        #expect(object["frameRateLimit"] != nil, "the key must exist before the test can drop it")
        object.removeValue(forKey: "frameRateLimit")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
    }

    private var sceneDescriptor: SceneDescriptor {
        SceneDescriptor(
            workshopID: "123",
            cacheRelativePath: "wpe-cache/123",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
    }

    @Test("A stored config with no frame-rate key resolves the same default as the initializer")
    func missingKeyMatchesTheInitializer() throws {
        let htmlURL = try #require(URL(string: "https://example.com"))
        for wallpaper in [
            WallpaperContent.scene(sceneDescriptor),
            WallpaperContent.video(bookmarkData: Data([1])),
            WallpaperContent.html(source: .url(htmlURL), config: HTMLConfig()),
        ] {
            let built = ScreenConfiguration(screenID: 4, wallpaper: wallpaper)
            let decoded = try decodeWithoutFrameRateLimit(built)
            #expect(
                decoded.frameRateLimit == FrameRateLimit.naturalDefault(for: wallpaper.wallpaperType),
                "\(wallpaper.wallpaperType) decoded as \(decoded.frameRateLimit)"
            )
            #expect(decoded.frameRateLimit == built.frameRateLimit)
        }
    }

    @Test("A scene stored before the key existed is capped, not uncapped")
    func sceneWithoutKeyIsNotUncapped() throws {
        let built = ScreenConfiguration(screenID: 4, wallpaper: .scene(sceneDescriptor))
        let decoded = try decodeWithoutFrameRateLimit(built)
        #expect(decoded.frameRateLimit == .fps30)
        // Control: the two cases are genuinely different, so the assertion above is not
        // satisfied by whatever the decoder happens to fall back to for every type.
        let video = ScreenConfiguration(screenID: 4, wallpaper: .video(bookmarkData: Data([1])))
        let decodedVideo = try decodeWithoutFrameRateLimit(video)
        #expect(decodedVideo.frameRateLimit == .matchDisplay)
    }

    @Test("An explicitly stored cap still wins over the per-type default")
    func explicitValueRoundTrips() throws {
        let built = ScreenConfiguration(
            screenID: 4, wallpaper: .scene(sceneDescriptor), frameRateLimit: .matchDisplay
        )
        let data = try JSONEncoder().encode(built)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)
        #expect(decoded.frameRateLimit == .matchDisplay)
    }
}
