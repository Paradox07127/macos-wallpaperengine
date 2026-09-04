import Foundation
import Testing
@testable import LiveWallpaperCore

/// `project.json` arrives with imported wallpapers and is untrusted. The
/// integral fast path in `stringValue` used to call `Int(_:)`, which traps past
/// `Int`'s range — crashing while building the custom-settings UI for an
/// imported wallpaper rather than rendering the value as-is.
@Suite("WallpaperEngineProjectPropertyValue numeric formatting")
struct WallpaperEngineProjectPropertyValueTests {

    @Test("An out-of-range integral value formats instead of trapping")
    func outOfRangeIntegralFormats() {
        // 1e300 is finite and integral, so it reaches the fast path.
        let value = WallpaperEngineProjectPropertyValue.number(1e300)
        #expect(value.stringValue == String(1e300))
        #expect(WallpaperEngineProjectPropertyValue.number(-1e300).stringValue == String(-1e300))
    }

    @Test("In-range integral values keep their integer formatting")
    func inRangeIntegralKeepsIntegerForm() {
        #expect(WallpaperEngineProjectPropertyValue.number(3).stringValue == "3")
        #expect(WallpaperEngineProjectPropertyValue.number(-7).stringValue == "-7")
        #expect(WallpaperEngineProjectPropertyValue.number(0).stringValue == "0")
    }

    @Test("Fractional values keep their Double formatting")
    func fractionalKeepsDoubleForm() {
        #expect(WallpaperEngineProjectPropertyValue.number(2.5).stringValue == "2.5")
    }
}

/// `HTMLConfig` and `SceneDescriptor` used to decode their property-override
/// maps with a whole-dictionary `try?`/`do-catch`, so one malformed value
/// (an unrepresentable JSON `null`, object, or array) dropped every override
/// in the map, not just the bad key.
@Suite("HTMLConfig / SceneDescriptor lossy override-map decode")
struct LossyOverrideMapDecodeTests {
    @Test("A malformed HTMLConfig override drops only that key, not the whole map")
    func htmlConfigLossyDictDropsOnlyMalformedKey() throws {
        var config = HTMLConfig()
        config.wallpaperEngineProjectProperties = ["scale": .number(1.5)]

        let data = try JSONEncoder().encode(config)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var overrides = try #require(object["wallpaperEngineProjectProperties"] as? [String: Any])
        overrides["tint"] = NSNull() // unrepresentable: not bool/number/string
        object["wallpaperEngineProjectProperties"] = overrides
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(HTMLConfig.self, from: corrupted)

        #expect(decoded.wallpaperEngineProjectProperties["scale"] == .number(1.5))
        #expect(decoded.wallpaperEngineProjectProperties["tint"] == nil)
    }

    @Test("A malformed SceneDescriptor propertyOverrides entry drops only that key, not the whole increment")
    func sceneDescriptorLossyDictDropsOnlyMalformedKey() throws {
        let descriptor = SceneDescriptor(
            workshopID: "123",
            cacheRelativePath: "wpe-cache/123",
            entryFile: "scene.json",
            capabilityTier: .imageOnly,
            propertyOverrides: ["scale": .number(1.5)]
        )

        let data = try JSONEncoder().encode(descriptor)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var overrides = try #require(object["propertyOverrides"] as? [String: Any])
        overrides["tint"] = NSNull()
        object["propertyOverrides"] = overrides
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: corrupted)

        #expect(decoded.propertyOverrides["scale"] == .number(1.5))
        #expect(decoded.propertyOverrides["tint"] == nil)
    }
}
