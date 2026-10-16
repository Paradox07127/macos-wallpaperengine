#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import XCTest

/// Scene 3815666789 built through `AmbientWallpaperSessionBuilder`, with and without `WPEParityRendererFlag`.
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
        UserDefaults.appScoped().removeObject(forKey: WPEParityRendererFlag.defaultsKey)
        UserDefaults.appScoped().removeObject(forKey: WPEParityRendererFlag.modeDefaultsKey)
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testFlaggedSceneLoadsAndPresentsThroughParityDriver() async throws {
        if case let .failure(reason) = WPEParityShaderToolchain.makeCompiler() {
            throw XCTSkip("\(reason)")
        }
        let scene = try installScene()
        UserDefaults.appScoped().set([Self.workshopID], forKey: WPEParityRendererFlag.defaultsKey)
        let session = try XCTUnwrap(makeSession(scene))
        defer { session.cleanup() }

        // Generous: a cold shader disk cache compiles every program first.
        let result = await session.prepareForDisplay(timeout: .seconds(120))
        XCTAssertEqual(result, .ready, "load error: \(String(describing: session.loadError))")
        let actor = session.spanRenderActor
        let usesParity = await actor.run { $0.parityDriverForTesting != nil }
        XCTAssertTrue(usesParity)
        let state = await actor.rendererStateSnapshot()
        let snapshot = try XCTUnwrap(state)
        XCTAssertTrue(snapshot.isLoaded)
        XCTAssertTrue(snapshot.hasPresentedFrame)
        XCTAssertEqual(snapshot.completedPresentGeneration, snapshot.currentLoadGeneration)
        XCTAssertNil(snapshot.failedPresentGeneration)
        XCTAssertEqual(snapshot.shaderErrorCount, 0, "\(snapshot.shaderErrors.map { "\($0.shader): \($0.reason)" })")
        XCTAssertEqual(snapshot.descriptor?.workshopID, Self.workshopID)
    }

    func testUnflaggedSceneKeepsMetalSceneRenderer() async throws {
        let scene = try installScene()
        WPEParityRendererFlag.setMode(.off)
        let session = try XCTUnwrap(makeSession(scene))
        defer { session.cleanup() }

        let actor = session.spanRenderActor
        let deadline = Date().addingTimeInterval(10)
        var adopted = await actor.rendererStateSnapshot() != nil
        while !adopted, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            adopted = await actor.rendererStateSnapshot() != nil
        }
        XCTAssertTrue(adopted, "no renderer adopted")
        let usesParity = await actor.run { $0.parityDriverForTesting != nil }
        XCTAssertFalse(usesParity)
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
    private func installScene() throws -> InstalledScene {
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
                                         entryFile: "scene.json", capabilityTier: .degraded)
        return InstalledScene(descriptor: descriptor, supportRoot: scratch,
                              engineRoot: wpeAssets.deletingLastPathComponent())
    }
}
#endif
