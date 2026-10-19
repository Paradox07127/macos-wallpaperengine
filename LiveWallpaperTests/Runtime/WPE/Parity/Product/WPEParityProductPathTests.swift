#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import XCTest

/// The product builder always selects parity, including upgrades from every historical renderer selection.
@MainActor
final class WPEParityProductPathTests: XCTestCase {
    private static let workshopID = "3815666789"

    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-product-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        UserDefaults.appScoped().removeObject(forKey: "loomscreen.wallpapers.parityRenderer.v1")
        UserDefaults.appScoped().removeObject(forKey: "loomscreen.wallpapers.parityRendererMode.v1")
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testHistoricalRendererSelectionsAllLoadAndPresentThroughParity() async throws {
        if case let .failure(reason) = WPEParityShaderToolchain.makeCompiler() {
            throw XCTSkip("\(reason)")
        }
        let scene = try installScene()
        for mode in ["off", "listed", "all"] {
            UserDefaults.appScoped().set(mode, forKey: "loomscreen.wallpapers.parityRendererMode.v1")
            UserDefaults.appScoped().set(["unrelated-scene"], forKey: "loomscreen.wallpapers.parityRenderer.v1")
            let session = try XCTUnwrap(makeSession(scene))
            let result = await session.prepareForDisplay(timeout: .seconds(120))
            XCTAssertEqual(result, .ready, "historical \(mode): \(String(describing: session.loadError))")
            let state = await session.spanRenderActor.rendererStateSnapshot()
            let snapshot = try XCTUnwrap(state)
            XCTAssertNotNil(snapshot.parity)
            XCTAssertTrue(snapshot.isLoaded)
            XCTAssertTrue(snapshot.hasPresentedFrame)
            XCTAssertEqual(snapshot.completedPresentGeneration, snapshot.currentLoadGeneration)
            XCTAssertNil(snapshot.failedPresentGeneration)
            XCTAssertEqual(snapshot.shaderErrorCount, 0, "\(snapshot.shaderErrors)")
            XCTAssertEqual(snapshot.descriptor?.workshopID, Self.workshopID)
            session.cleanup()
        }
    }

    func testRejectedPresetCreatesAnExplicitlyFailedCandidate() async throws {
        if case let .failure(reason) = WPEParityShaderToolchain.makeCompiler() {
            throw XCTSkip("\(reason)")
        }
        let scene = try installScene(presetSnapshot: ["wec_e": .number(1)])
        let session = try XCTUnwrap(makeSession(scene))
        defer { session.cleanup() }
        let result = await session.prepareForDisplay(timeout: .seconds(1))
        XCTAssertEqual(result, .failed)
        let error = try XCTUnwrap(session.loadError)
        XCTAssertNotNil(session.runtimeError)
        XCTAssertNotNil(session.loadFailureCause)
        let state = await session.spanRenderActor.rendererStateSnapshot()
        XCTAssertNil(state, "A rejected preset must not adopt a renderer")
        await session.retry()
        XCTAssertEqual(session.loadError?.errorDescription, error.errorDescription,
                       "Retry cannot turn an unadopted failed candidate into a successful empty reload")
    }

    func testUnavailableToolchainCreatesAnExplicitlyFailedCandidate() async throws {
        let scene = try installScene()
        let session = try XCTUnwrap(AmbientWallpaperSessionBuilder().makeSceneSession(
            descriptor: scene.descriptor, frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            engineAssetsRootURL: scene.engineRoot, applicationSupportRootURL: scene.supportRoot,
            makeParityCompiler: { .failure(.init(description: "required parity toolchain unavailable")) }
        ))
        defer { session.cleanup() }
        let result = await session.prepareForDisplay(timeout: .seconds(1))
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(try XCTUnwrap(session.loadError?.errorDescription).contains("required parity toolchain unavailable"))
        XCTAssertNotNil(session.runtimeError)
        let snapshot = await session.spanRenderActor.rendererStateSnapshot()
        XCTAssertNil(snapshot)
    }

    private struct InstalledScene {
        let descriptor: SceneDescriptor
        let supportRoot: URL
        let engineRoot: URL
    }

    private func makeSession(_ scene: InstalledScene) -> SceneWallpaperSession? {
        AmbientWallpaperSessionBuilder().makeSceneSession(
            descriptor: scene.descriptor, frame: CGRect(x: 0, y: 0, width: 960, height: 540),
            engineAssetsRootURL: scene.engineRoot, applicationSupportRootURL: scene.supportRoot
        )
    }

    /// Copies the fixture scene into a scratch app-support root as an extracted `.cache` scene.
    private func installScene(
        presetSnapshot: [String: WallpaperEngineProjectPropertyValue] = [:]
    ) throws -> InstalledScene {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        // The sandboxed test host's home is its container; the WPE install lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let relativePath = "wpe-cache/\(Self.workshopID)"
        let sceneDirectory = scratch.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sceneDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "scene-sources/\(Self.workshopID)"),
                                         to: sceneDirectory)
        let descriptor = SceneDescriptor(workshopID: Self.workshopID, cacheRelativePath: relativePath,
                                         entryFile: "scene.json", capabilityTier: .degraded,
                                         presetSnapshot: presetSnapshot)
        return InstalledScene(descriptor: descriptor, supportRoot: scratch,
                              engineRoot: wpeAssets.deletingLastPathComponent())
    }
}
#endif
