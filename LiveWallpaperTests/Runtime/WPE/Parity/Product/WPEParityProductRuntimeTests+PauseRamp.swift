#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore
import XCTest

/// Which policy suspends let a running parity scene ease its scene time to a hold before the link parks.
extension WPEParityProductRuntimeTests {
    func testRulePauseRunsTheLinkUntilThePauseRampHolds() async throws {
        let harness = try await makePauseRampHarness()
        for _ in 1 ... 2 {
            try await renderPauseRampFrame(harness)
        }
        XCTAssertEqual(harness.surface.lastIsPaused, false)

        await harness.actor.applyPerformanceProfile(
            .suspended, rampDown: SceneWallpaperSession.pauseRampsDown([.applicationRule])
        )
        XCTAssertEqual(harness.surface.lastIsPaused, false, "an application-rule pause parked the link before its ramp")
        var frames = 0
        while harness.surface.lastIsPaused == false, frames < 60 {
            // One display-link interval, so each frame eases the ramp as a running link would.
            try await Task.sleep(for: .milliseconds(17))
            try await renderPauseRampFrame(harness)
            frames += 1
        }
        let ramp = await harness.actor.run { $0.parityDriverForTesting?.renderer?.clock.pauseRamp }
        XCTAssertEqual(ramp, 0, "after \(frames) suspended frames")
        XCTAssertEqual(harness.surface.lastIsPaused, true, "the link still runs after \(frames) suspended frames")
        XCTAssertGreaterThan(frames, 1, "the ramp ended within one frame")
    }

    func testThermalPauseParksTheLinkAtOnce() async throws {
        let harness = try await makePauseRampHarness()
        try await renderPauseRampFrame(harness)
        XCTAssertEqual(harness.surface.lastIsPaused, false)
        XCTAssertFalse(SceneWallpaperSession.pauseRampsDown([.applicationRule, .thermal]))

        await harness.actor.applyPerformanceProfile(.suspended,
                                                    rampDown: SceneWallpaperSession.pauseRampsDown([.thermal]))
        XCTAssertEqual(harness.surface.lastIsPaused, true, "a thermal pause kept the link running")
    }

    // MARK: Harness

    private struct PauseRampHarness {
        let actor: WPEDisplayRenderActor
        let surface: PauseRampPacingRecorder
    }

    /// The fixture scene with an animated alpha and no effects, loaded on a fresh actor.
    private func makePauseRampHarness() async throws -> PauseRampHarness {
        let sceneID = "3815666789"
        let size = CGSize(width: 1280, height: 720)
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        // The sandboxed test host's home is its container; the WPE install lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let environment = ProcessInfo.processInfo.environment
        let wpeAssets = environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "parity-pause-ramp-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)
        // An unsigned Debug test host cannot supply the shipping helper's inherited sandbox; Xcode forwards
        // TEST_RUNNER_WPE_* as WPE_*.
        let toolchain = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER"]
            .compactMap { environment[$0].map { URL(fileURLWithPath: $0) } }
        let compiler: WPEParityHelperShaderCompiler
        if toolchain.isEmpty {
            switch WPEParityShaderToolchain.makeCompiler() {
            case let .success(found): compiler = found
            case let .failure(reason): throw reason
            }
        } else {
            guard toolchain.count == 3 else { throw XCTSkip("Supply all three current test toolchain paths") }
            compiler = try WPEParityHelperShaderCompiler(helper: toolchain[0], dxcompiler: toolchain[1],
                                                         metalIRConverter: toolchain[2],
                                                         workDirectory: scratch.appending(path: "shaderc"))
        }

        let relativePath = "wpe-cache/\(sceneID)"
        let sceneDirectory = scratch.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sceneDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "scene-sources/\(sceneID)"), to: sceneDirectory)
        let file = sceneDirectory.appending(path: "scene.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let alpha: [String: Any] = ["value": 1, "animation": [
            "c0": [["frame": 0, "value": 1], ["frame": 30, "value": 0]],
            "options": ["fps": 30, "length": 30, "mode": "loop"],
        ]]
        var objects = json["objects"] as? [[String: Any]] ?? []
        for index in objects.indices where objects[index]["id"] as? Int == 17 {
            objects[index]["effects"] = [Any]()
            objects[index]["alpha"] = alpha
        }
        json["objects"] = objects
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = size
        let surface = PauseRampPacingRecorder()
        let inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: sceneID, cacheRelativePath: relativePath,
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: sceneDirectory),
            projectRoot: sceneDirectory,
            assets: WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                           assetRoots: [root.appending(path: "wpeassets"), wpeAssets]),
            settings: WPEParityProgramSettings(),
            compiler: compiler,
            device: device,
            presentLayer: WPEPresentLayer(layer: layer),
            mailbox: WPEPointerMailbox(),
            surfaceControl: surface,
            drawableSize: size,
            pixelFormat: layer.pixelFormat
        )
        let actor = WPEDisplayRenderActor()
        addTeardownBlock {
            await actor.teardownRenderer()
            await actor.shutdown()
            try? FileManager.default.removeItem(at: scratch)
        }
        try await actor.adoptParity(inputs)
        await actor.setAudioMuted(true)
        try await actor.load()
        return PauseRampHarness(actor: actor, surface: surface)
    }

    /// One display-link frame, waited for until its present completed.
    private func renderPauseRampFrame(_ harness: PauseRampHarness) async throws {
        await harness.actor.renderFrame()
        let deadline = Date().addingTimeInterval(5)
        var inFlight = await harness.actor.run { $0.parityDriverForTesting?.inFlightCount ?? 0 }
        while inFlight > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
            inFlight = await harness.actor.run { $0.parityDriverForTesting?.inFlightCount ?? 0 }
        }
        XCTAssertEqual(inFlight, 0)
    }
}

/// Records whether the render actor last asked for a parked link.
private final class PauseRampPacingRecorder: WPESurfaceControl {
    private let isPaused = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    var lastIsPaused: Bool? {
        isPaused.withLock { $0 }
    }

    func applyPacing(_ update: WPERenderPacingUpdate) {
        isPaused.withLock { $0 = update.isPaused ?? $0 }
    }

    func setNeedsRedraw() {}

    func drawImmediately() {}

    func releaseDrawables() {}

    func detach() {}

    func setClickCaptureEnabled(_: Bool) {}
}
#endif
