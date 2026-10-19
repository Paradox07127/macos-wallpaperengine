#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing

struct SystemWallpaperSceneConfigurationTests {
    @Test func paritySnapshotRoundTripsWithoutReadingPreferences() throws {
        let descriptor = SceneDescriptor(workshopID: "123", cacheRelativePath: "wpe-cache/123",
                                         entryFile: "scene.json", capabilityTier: .imageOnly,
                                         presetSnapshot: ["wec_e": .bool(true), "wec_con": .number(25)])
        let settings = try WPEParityProgramSettings(
            bloom: false, hdrPostProcessing: true, msaaSampleCount: 4, mipMappedFrameBufferEnabled: true,
            colorCorrection: WPEParityColorCorrection(presetSnapshot: descriptor.presetSnapshot),
            displayHDR: true, maximumPotentialEDR: 2, shadowQuality: 4,
            offscreenScaleTier: 3, renderTargetAliasing: true
        )
        let parity = SystemWallpaperSceneConfiguration.Parity(settings: settings, textureCompression: false,
                                                              renderScale: 0.5, compilerIdentity: "fixture compiler")
        let configuration = SystemWallpaperSceneConfiguration(descriptor: descriptor, dependencies: [],
                                                              hasEngineAssets: false, parity: parity)
        let decoded = try JSONDecoder().decode(SystemWallpaperSceneConfiguration.self,
                                               from: JSONEncoder().encode(configuration))
        let frozen = try #require(decoded.parity)
        #expect(frozen == parity)
        #expect(try frozen.settings(for: decoded.descriptor) == settings)
        #expect(frozen.shaderOptions == .init())
        #expect(!frozen.textureCompression && frozen.renderScale == 0.5)
    }

    @Test func incompatibleParityABICannotBeRestored() throws {
        let descriptor = SceneDescriptor(workshopID: "123", cacheRelativePath: "wpe-cache/123",
                                         entryFile: "scene.json", capabilityTier: .imageOnly)
        let parity = SystemWallpaperSceneConfiguration.Parity(settings: .init(), textureCompression: true,
                                                              renderScale: 1, compilerIdentity: "fixture compiler",
                                                              bindingABIVersion: -1)
        #expect(throws: CocoaError.self) { try parity.settings(for: descriptor) }
    }
}
#endif
