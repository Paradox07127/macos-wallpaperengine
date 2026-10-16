#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

/// A render actor whose parity load failed takes the old renderer for the same scene and keeps the settings sent so far.
final class WPEParityFallbackTests: XCTestCase {
    private static let size = CGSize(width: 1280, height: 720)
    private static let sceneID = "3815666789"

    private var scratch: URL!
    private var actors: [WPEDisplayRenderActor] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-fallback-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        WPEParitySceneDriver.remainingForcedLoadFailuresForTesting = 0
        for actor in actors {
            await actor.teardownRenderer()
            await actor.shutdown()
        }
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testFailedParityLoadFallsBackToTheOldRendererWithTheSentSettings() async throws {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(found): compiler = found
        case let .failure(reason): throw XCTSkip("\(reason)")
        }
        // The sandboxed test host's home is its container; the WPE install lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let relativePath = "wpe-cache/\(UUID().uuidString)"
        let sceneDirectory = scratch.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sceneDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "scene-sources/\(Self.sceneID)"), to: sceneDirectory)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = Self.size
        let mailbox = WPEPointerMailbox()
        let descriptor = SceneDescriptor(workshopID: Self.sceneID, cacheRelativePath: relativePath,
                                         entryFile: "scene.json", capabilityTier: .degraded)
        let inputs = WPEParitySceneInputs(
            descriptor: descriptor,
            entryResolver: SceneResourceResolver(cacheRootURL: sceneDirectory),
            projectRoot: sceneDirectory,
            assets: WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                           assetRoots: [root.appending(path: "wpeassets"), wpeAssets]),
            settings: WPEParityProgramSettings(),
            compiler: compiler,
            device: device,
            presentLayer: WPEPresentLayer(layer: layer),
            mailbox: mailbox,
            surfaceControl: NoOpSurfaceControl(),
            drawableSize: Self.size,
            pixelFormat: layer.pixelFormat
        )
        let actor = WPEDisplayRenderActor()
        actors.append(actor)
        try await actor.adoptParity(inputs)
        await actor.setAudioVolume(0.25)
        await actor.setFrameRateCeiling(24)

        WPEParitySceneDriver.remainingForcedLoadFailuresForTesting = 1
        do {
            try await actor.load()
            XCTFail("the forced parity load failure did not throw")
        } catch {}

        // The parity scene paced a no-op surface; only the old renderer's pacer reaches the actor's link.
        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor, cacheRootURL: sceneDirectory, dependencyMounts: [], engineAssetsRootURL: wpeAssets,
            surfaceControl: WPERenderThreadFramePacer(surface: NoOpSurfaceControl(), renderActor: actor),
            mailbox: mailbox, presentLayer: WPEPresentLayer(layer: layer), drawableSize: Self.size, device: device
        )
        await actor.replaceParity(with: WPERendererHandoff(renderer: renderer).renderer)
        try await actor.load()

        let parityGone = await actor.run { $0.parityDriverForTesting == nil }
        XCTAssertTrue(parityGone)
        let snapshot = await actor.rendererStateSnapshot()
        XCTAssertEqual(snapshot?.isLoaded, true)
        XCTAssertNil(snapshot?.parity)
        let volume = await actor.currentPendingAudioVolume()
        XCTAssertEqual(volume, 0.25)
        let linkFPS = await actor.run { $0.linkPreferredFPSForTesting }
        XCTAssertEqual(linkFPS, 24)
    }
}

private final class NoOpSurfaceControl: WPESurfaceControl {
    func applyPacing(_: WPERenderPacingUpdate) {}
    func setNeedsRedraw() {}
    func drawImmediately() {}
    func releaseDrawables() {}
    func detach() {}
    func setClickCaptureEnabled(_: Bool) {}
}
#endif
