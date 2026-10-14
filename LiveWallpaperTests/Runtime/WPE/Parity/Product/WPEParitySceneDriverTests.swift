#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

/// Scene 3815666789 compiled by wpe-shaderc, rendered by the parity renderer and presented into a CAMetalLayer.
final class WPEParitySceneDriverTests: XCTestCase {
    private static let size = CGSize(width: 1920, height: 1080)
    /// The capture machine's settings, as in `WPEParityRealSceneTests`.
    private static let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true)

    private var scratch: URL!
    private var timestamp: CFTimeInterval = 100

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-driver-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testLoadPresentPauseAndCleanup() async throws {
        let (document, assets) = try sceneInputs()
        let compiler = try makeCompiler()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        try await driver.load(document: document, assets: assets, settings: Self.settings, drawableSize: Self.size,
                              pixelFormat: .rgba8Unorm_srgb, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        XCTAssertFalse(driver.hasPresentedFrame)

        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = Self.size
        layer.framebufferOnly = false
        for frame in 1 ... 3 {
            try await present(driver, layer: layer, label: "frame \(frame)")
        }
        XCTAssertEqual(driver.completedPresentGeneration, driver.loadGeneration)
        XCTAssertNil(driver.failedPresentGeneration)
        XCTAssertTrue(driver.hasPresentedFrame)
        let drawable = try XCTUnwrap(layer.lastTexture)
        XCTAssertEqual([drawable.width, drawable.height], [1920, 1080])
        let pixels = try readBack(drawable, device: device)
        let first = Array(pixels.prefix(4))
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { Array(pixels[$0 ..< $0 + 4]) != first },
                      "the drawable is one flat colour \(first)")

        // The pause ramp eases scene time to a stop, after which it holds.
        driver.applyPerformanceProfile(.suspended)
        var rampFrames = 0
        while try sceneClock(driver).pauseRamp > 0, rampFrames < 120 {
            try await present(driver, layer: layer, label: "ramp frame \(rampFrames)")
            rampFrames += 1
        }
        XCTAssertEqual(try sceneClock(driver).pauseRamp, 0, "after \(rampFrames) suspended frames")
        let held = try sceneClock(driver).time
        for frame in 1 ... 2 {
            try await present(driver, layer: layer, label: "suspended frame \(frame)")
            XCTAssertEqual(try sceneClock(driver).time, held, "suspended frame \(frame)")
        }
        driver.applyPerformanceProfile(.quality)
        for frame in 1 ... 2 {
            try await present(driver, layer: layer, label: "resumed frame \(frame)")
        }
        XCTAssertGreaterThan(try sceneClock(driver).time, held)

        // A frame still on the GPU at cleanup finishes without marking the new generation ready.
        let pending = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                                 pointer: SIMD2(0.5, 0.5)))
        let generation = driver.loadGeneration
        driver.cleanup()
        XCTAssertFalse(driver.didLoad)
        XCTAssertNil(driver.renderer)
        XCTAssertNotEqual(driver.loadGeneration, generation)
        XCTAssertNil(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(), pointer: SIMD2(0.5, 0.5)))
        await pending.completed()
        try await settle(driver, label: "after cleanup")
        XCTAssertNil(driver.completedPresentGeneration)
        XCTAssertFalse(driver.hasPresentedFrame)
    }

    /// Scene 3509243656 has one sound layer; the driver plays it with WPE's rules and stops it on cleanup.
    func testSoundLayerStartsRuntimeAndCleanupStopsIt() async throws {
        let (document, assets) = try sceneInputs(sceneID: "3509243656")
        XCTAssertEqual(document.soundObjects.count, 1)
        let compiler = try makeCompiler()
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        driver.setAudioMuted(true)
        let sceneDirectory = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR"))
            .appending(path: "scene-sources/3509243656")
        try await driver.load(document: document, assets: assets, settings: Self.settings, drawableSize: Self.size,
                              pixelFormat: .rgba8Unorm_srgb, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch),
                              soundResolver: WPEMultiRootResourceResolver(primaryRootURL: sceneDirectory,
                                                                          dependencyMounts: []))
        let runtime = try XCTUnwrap(driver.soundRuntime)
        XCTAssertEqual(runtime.rules, .wpe)
        let track = try XCTUnwrap(runtime.debugTrackSnapshots().first)
        XCTAssertEqual(track.playerVolume, 0, "muted before load")
        XCTAssertGreaterThan(track.scheduledSegmentCount, 0)

        driver.cleanup()
        XCTAssertNil(driver.soundRuntime)
        XCTAssertTrue(runtime.debugTrackSnapshots().isEmpty, "cleanup stops and detaches every track")
    }

    /// The unsigned Debug test host cannot provide the inherited sandbox required by the shipping helper.
    /// Explicit test inputs use the current source build; the signed Release product gate uses its bundle.
    private func makeCompiler() throws -> WPEParityHelperShaderCompiler {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER"]
        let urls = keys.compactMap { environment[$0].map { URL(fileURLWithPath: $0) } }
        if !urls.isEmpty {
            guard urls.count == 3 else { throw XCTSkip("Supply all three current test toolchain paths") }
            return try WPEParityHelperShaderCompiler(helper: urls[0], dxcompiler: urls[1], metalIRConverter: urls[2],
                                                     workDirectory: scratch.appending(path: "shaderc"))
        }
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(compiler): return compiler
        case let .failure(reason): throw XCTSkip("\(reason)")
        }
    }

    private func present(_ driver: WPEParitySceneDriver, layer: CAMetalLayer, label: String) async throws {
        let commandBuffer = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                                       pointer: SIMD2(0.5, 0.5)),
                                          "\(label) was not presented")
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error, label)
        try await settle(driver, label: label)
    }

    /// `completed()` can resume before the completion handlers that record readiness have run.
    private func settle(_ driver: WPEParitySceneDriver, label: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while driver.inFlightCount > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(driver.inFlightCount, 0, label)
    }

    private func nextTimestamp() -> CFTimeInterval {
        timestamp += 1.0 / 60
        return timestamp
    }

    private func sceneClock(_ driver: WPEParitySceneDriver) throws -> WPEParityClock {
        try XCTUnwrap(driver.renderer).clock
    }

    private func sceneInputs(sceneID: String = "3815666789") throws -> (WPESceneDocument, WPEParityProgramAssets) {
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
        let sceneDirectory = root.appending(path: "scene-sources/\(sceneID)")
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: sceneDirectory.appending(path: "scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        // The capture's wpeassets/ holds only shaders; util materials come from the WPE install.
        return (document, WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                                 assetRoots: [root.appending(path: "wpeassets"), wpeAssets]))
    }

    private func readBack(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }
}

/// Keeps the texture of the last drawable handed out, so the test can read what the present wrote.
private final class RecordingLayer: CAMetalLayer {
    private(set) var lastTexture: MTLTexture?

    override func nextDrawable() -> (any CAMetalDrawable)? {
        let drawable = super.nextDrawable()
        lastTexture = drawable?.texture
        return drawable
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
