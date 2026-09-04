import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("SceneDescriptor / WallpaperContent.scene persistence")
struct SceneDescriptorCodableTests {

    // MARK: - SceneDescriptor

    @Test("SceneDescriptor round-trips through JSON")
    func sceneDescriptorRoundTrips() throws {
        let descriptor = SceneDescriptor(
            workshopID: "3351072238",
            cacheRelativePath: "wpe-cache/3351072238",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded == descriptor)
    }

    @Test("Unknown capabilityTier decodes lossily as .unsupported")
    func sceneDescriptorTierFallsBack() throws {
        let payload: [String: Any] = [
            "workshopID": "abc",
            "cacheRelativePath": "wpe-cache/abc",
            "entryFile": "scene.json",
            "capabilityTier": "fxOnly"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded.capabilityTier == .unsupported)
        #expect(decoded.workshopID == "abc")
    }

    @Test("SceneDescriptor decodes missing dependencyWorkshopIDs as empty")
    func sceneDescriptorMissingDependenciesDecodeAsEmpty() throws {
        let payload: [String: Any] = [
            "workshopID": "abc",
            "cacheRelativePath": "wpe-cache/abc",
            "entryFile": "scene.json",
            "capabilityTier": "imageOnly"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded.dependencyWorkshopIDs == [])
    }

    @Test("SceneDescriptor round-trips dependencyWorkshopIDs")
    func sceneDescriptorDependenciesRoundTrip() throws {
        let descriptor = SceneDescriptor(
            workshopID: "main",
            cacheRelativePath: "wpe-cache/main",
            entryFile: "scene.json",
            capabilityTier: .degraded,
            dependencyWorkshopIDs: ["111", "222"]
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded == descriptor)
    }

    // MARK: - WallpaperContent.scene

    @Test("WallpaperContent.scene round-trips through ScreenConfiguration")
    func wallpaperContentSceneRoundTrips() throws {
        let descriptor = SceneDescriptor(
            workshopID: "rt",
            cacheRelativePath: "wpe-cache/rt",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        let config = ScreenConfiguration(
            screenID: 42,
            wallpaper: .scene(descriptor)
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.activeWallpaper == .scene(descriptor))
        #expect(decoded.wallpaperType == .scene)
    }

    // MARK: - Legacy backfill

    @Test("Reconcile keeps wpeOrigin when scene descriptor matches workshopID + cacheRelativePath")
    func reconcileKeepsOriginWhenSceneMatches() throws {
        let descriptor = SceneDescriptor(
            workshopID: "match",
            cacheRelativePath: "wpe-cache/match",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        var config = ScreenConfiguration(screenID: 9, wallpaper: .scene(descriptor))
        config.wpeOrigin = WPEOrigin(
            workshopID: "match",
            title: "Match",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/match",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))

        #expect(config.wpeOrigin != nil)
    }

    @Test("Reconcile drops wpeOrigin when scene descriptor disagrees with origin workshopID")
    func reconcileDropsOriginOnSceneMismatch() throws {
        let descriptor = SceneDescriptor(
            workshopID: "current",
            cacheRelativePath: "wpe-cache/current",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        var config = ScreenConfiguration(screenID: 10, wallpaper: .scene(descriptor))
        config.wpeOrigin = WPEOrigin(
            workshopID: "stale",
            title: "Stale",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/stale",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        WPEOriginReconciler().reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))

        #expect(config.wpeOrigin == nil)
    }
}
