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

    @Test(arguments: ["translatorVersion", "keyFormatVersion"], [false, true])
    func staleShaderVersionsRequireRepreparation(field: String, missing: Bool) throws {
        let descriptor = SceneDescriptor(workshopID: "123", cacheRelativePath: "wpe-cache/123",
                                         entryFile: "scene.json", capabilityTier: .imageOnly)
        let parity = SystemWallpaperSceneConfiguration.Parity(settings: .init(), textureCompression: true,
                                                              renderScale: 1, compilerIdentity: "fixture")
        let current = SystemWallpaperSceneConfiguration(descriptor: descriptor, dependencies: [], hasEngineAssets: false, parity: parity)
        #expect(!current.needsRepreparation)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        #expect(json["translatorVersion"] as? Int == SystemWallpaperSceneConfiguration.currentTranslatorVersion)
        #expect(json["keyFormatVersion"] as? Int == SystemWallpaperSceneConfiguration.currentKeyFormatVersion)
        if missing {
            json.removeValue(forKey: field)
        } else {
            json[field] = 0
        }
        let stale = try JSONDecoder().decode(SystemWallpaperSceneConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(stale.needsRepreparation)
        json[field] = 999
        let future = try JSONDecoder().decode(SystemWallpaperSceneConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!future.needsRepreparation)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func heartbeatAutomaticallyRepairsCurrentCapsuleOnlyOncePerContent() async throws {
        guard #available(macOS 26.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Videos/current.scene")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let descriptor = SceneDescriptor(workshopID: "123", cacheRelativePath: "wpe-cache/123",
                                         entryFile: "../invalid.json", capabilityTier: .imageOnly)
        let parity = SystemWallpaperSceneConfiguration.Parity(settings: .init(), textureCompression: true,
                                                              renderScale: 1, compilerIdentity: "fixture")
        let configuration = SystemWallpaperSceneConfiguration(descriptor: descriptor, dependencies: [], hasEngineAssets: false, parity: parity)
        #expect(!configuration.needsRepreparation)
        try JSONEncoder().encode(configuration).write(to: bundle.appendingPathComponent("configuration.json"))
        let item = SystemWallpaperManifest.Item(id: "current", title: "Current", fileName: "current.scene", addedAt: Date())
        try JSONEncoder().encode(SystemWallpaperManifest(version: 1, items: [item])).write(to: root.appendingPathComponent("manifest.json"))
        let dependencies = WallpaperExportService.Dependencies(sharedRoot: root, resolver: .live, now: Date.init,
                                                               makeThumbnailJPEG: { _ in nil })
        let service = WallpaperExportService(dependencies: dependencies)
        let beat = SystemWallpaperHeartbeat(timestamp: Date(), activeChoiceID: item.id, playbackFailures: [item.id: "scene.load.failed"])
        try JSONEncoder().encode(beat).write(to: root.appendingPathComponent("heartbeat.json"))
        service.refreshProviderStatus()
        for _ in 0 ..< 100 where service.lastError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.lastError != nil)
        let receiptURL = root.appendingPathComponent("scene-recovery.json")
        let receipt = try Data(contentsOf: receiptURL)
        service.clearLastError()
        await service.reprepareLegacySceneCapsules()
        #expect(service.lastError == nil)
        #expect(try Data(contentsOf: receiptURL) == receipt)
        let relaunched = WallpaperExportService(dependencies: dependencies)
        await relaunched.reprepareLegacySceneCapsules()
        #expect(relaunched.lastError == nil)
        try Data("new content".utf8).write(to: bundle.appendingPathComponent("change.txt"))
        await service.reprepareLegacySceneCapsules()
        #expect(service.lastError != nil)
        #expect(try Data(contentsOf: receiptURL) != receipt)
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
