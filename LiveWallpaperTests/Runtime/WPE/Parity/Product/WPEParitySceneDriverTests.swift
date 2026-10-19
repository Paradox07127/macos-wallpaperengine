#if !LITE_BUILD && DEBUG
import CoreGraphics
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

    var scratch: URL!
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

    func testFailedSceneWorkCannotBecomeReadyThroughASuccessfulPresent() {
        let state = WPEParityPresentState()
        state.reset(generation: 3)
        state.recordGPUFailure(generation: 3, reason: "scene GPU failure")
        state.record(generation: 3, succeeded: true)
        XCTAssertNil(state.completedGeneration)
        XCTAssertEqual(state.failedGeneration, 3)
        XCTAssertEqual(state.gpuErrors.count, 1)
        XCTAssertEqual(state.gpuErrors.last, "scene GPU failure")
        state.reset(generation: 4)
        state.recordGPUFailure(generation: 3, reason: "stale completion")
        state.record(generation: 4, succeeded: true)
        XCTAssertEqual(state.completedGeneration, 4)
        XCTAssertEqual(state.gpuErrors.count, 0)
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
            let command = driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                       pointer: SIMD2(0.5, 0.5))
            if try sceneClock(driver).pauseRamp > 0 {
                let submitted = try XCTUnwrap(command, "ramp frame \(rampFrames)")
                try await settle(driver, label: "ramp frame \(rampFrames)")
                XCTAssertEqual(submitted.status, .completed)
                XCTAssertNil(submitted.error)
            } else {
                XCTAssertNil(command, "the native transition to a fully held pause skips GPU submission")
            }
            rampFrames += 1
        }
        XCTAssertEqual(try sceneClock(driver).pauseRamp, 0, "after \(rampFrames) suspended frames")
        try await settle(driver, label: "pause ramp complete")
        let held = try sceneClock(driver).time
        for frame in 1 ... 2 {
            XCTAssertNil(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                      pointer: SIMD2(0.5, 0.5)), "suspended frame \(frame)")
            XCTAssertEqual(try sceneClock(driver).time, held, "suspended frame \(frame)")
            XCTAssertNil(driver.failedPresentGeneration)
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

    func testCaptureKeepsLastPresentedFrameAcrossUnpresentedReplan() async throws {
        let document: WPESceneDocument
        let assets: WPEParityProgramAssets
        let compiler: WPEParityHelperShaderCompiler
        do {
            (document, assets) = try sceneInputs()
            compiler = try makeCompiler()
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParitySceneDriverTests.RequiredCaptureInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required capture inputs unavailable: \(error)"]
            ))
        }
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, 1, "The required native gate uses isolated defaults")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: Self.settings, drawableSize: Self.size,
                              pixelFormat: .rgba8Unorm_srgb, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")

        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.colorspace = colorSpace
        layer.drawableSize = Self.size
        layer.framebufferOnly = false
        try await present(driver, layer: layer, label: "A before replan")
        XCTAssertTrue(driver.hasPresentedFrame)
        let drawableA = try XCTUnwrap(layer.lastTexture)
        let expectedA = try readBack(drawableA, device: device)
        XCTAssertEqual([drawableA.width, drawableA.height], [1920, 1080])
        let firstA = Array(expectedA.prefix(4))
        XCTAssertTrue(stride(from: 0, to: expectedA.count, by: 4).contains {
            Array(expectedA[$0 ..< $0 + 4]) != firstA
        }, "A must contain real scene pixels, not the cleared backbuffer's flat colour")

        // IDs do not retain A's renderer or its backbuffer. The recorded drawable is a distinct present target.
        let rendererAID = try ObjectIdentifier(XCTUnwrap(driver.renderer))
        let backbufferAID = try ObjectIdentifier(XCTUnwrap(driver.renderer).backbuffer)
        let rawFormatA = try XCTUnwrap(driver.renderer).backbuffer.pixelFormat
        let expectedRawA = try readBack(XCTUnwrap(driver.renderer).backbuffer, device: device)
        XCTAssertNotEqual(ObjectIdentifier(drawableA), backbufferAID)
        let resized = CGSize(width: 1280, height: 720)
        driver.updateSurfaceGeometry(drawableSize: resized)
        XCTAssertTrue(driver.needsReplan)
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertFalse(driver.needsReplan)
        XCTAssertNotEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer)), rendererAID)
        XCTAssertNotEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer).backbuffer), backbufferAID)
        XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.width, 1280)
        XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.height, 720)

        // B exists, but no B frame has rendered or presented. Capture must still replay the completed A present.
        let afterReplan = await capture(driver, colorSpace: colorSpace)
        try assertCapture(XCTUnwrap(afterReplan), matches: drawableA, expected: expectedA,
                          device: device, colorSpace: colorSpace, label: "A after unpresented B replan")
        let rawAfterReplan = await driver.copyPresentedBackbuffer()
        let rawA = try XCTUnwrap(rawAfterReplan)
        XCTAssertEqual([rawA.texture.width, rawA.texture.height], [1920, 1080])
        XCTAssertEqual(rawA.texture.pixelFormat, rawFormatA)
        let actualRawA = try readBack(rawA.texture, device: device)
        XCTAssertEqual(actualRawA.count, expectedRawA.count)
        let rawDifference = zip(actualRawA, expectedRawA).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        XCTAssertEqual(rawDifference, 0, "Raw poster copy must also retain A across an unpresented B replan")

        layer.drawableSize = resized
        try await present(driver, layer: layer, label: "B after replan")
        XCTAssertTrue(driver.hasPresentedFrame)
        let drawableB = try XCTUnwrap(layer.lastTexture)
        XCTAssertEqual([drawableB.width, drawableB.height], [1280, 720])
        let expectedB = try readBack(drawableB, device: device)
        let afterPresent = await capture(driver, colorSpace: colorSpace)
        try assertCapture(XCTUnwrap(afterPresent), matches: drawableB, expected: expectedB,
                          device: device, colorSpace: colorSpace, label: "B after B present")

        driver.cleanup()
        let afterCleanup = await capture(driver, colorSpace: colorSpace)
        XCTAssertNil(afterCleanup, "Cleanup revokes the last presented frame's capture eligibility")
    }

    func testPreparedSceneReuseDefaultsAndStrictRollback() throws {
        let suite = try TestScratch.defaultsSuite("WPEParitySceneDriverTests.PreparedSceneReuse")
        defer { suite.discard() }
        let key = WPEParitySceneDriver.preparedSceneReuseDefaultsKey
        let variable = WPEParitySceneDriver.preparedSceneReuseEnvironmentKey
        func resolve(_ environment: [String: String] = [:]) -> Bool {
            WPEParitySceneDriver.resolvePreparedSceneReuse(defaults: suite.defaults, environment: environment)
        }
        XCTAssertTrue(resolve(), "Unconfigured production path defaults on")
        suite.defaults.set(false, forKey: key)
        XCTAssertFalse(resolve(), "A real Boolean false rolls back")
        XCTAssertFalse(resolve([variable: "invalid"]), "Invalid environment falls through to Boolean preference")
        for value in ["1", "true", "TRUE"] {
            XCTAssertTrue(resolve([variable: value]), "Valid environment overrides preference")
        }
        suite.defaults.set(true, forKey: key)
        for value in ["0", "false", "FALSE"] {
            XCTAssertFalse(resolve([variable: value]), "Environment rollback overrides preference")
        }
        for value: Any in [NSNumber(value: 0), NSNumber(value: 1), "false", "0"] {
            suite.defaults.set(value, forKey: key)
            XCTAssertTrue(resolve([variable: "invalid"]), "Numeric and string defaults are not Boolean opt-outs")
        }
    }

    /// Explicit on/off and default construction keep actual presents identical after live commits and a new load.
    /// The expected green/black/blue pixels come from authored input, not preparation counters.
    func testPreparedSceneReusePreservesPropertyCommitAndReloadedPixels() async throws {
        let (_, assets) = try sceneInputs()
        let compiler = try makeCompiler()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        func document(color: String, shown: Bool) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 160, "height": 96], "clearenabled": true,
                            "clearcolor": "0 0 0", "camerashake": false, "cameraparallax": false],
                "objects": [["id": 20, "image": "models/util/solidlayer.json", "origin": "80 48 0",
                             "size": "24 24", "color": color, "visible": ["user": "shown", "value": true]]],
            ]), userValues: ["shown": .bool(shown)])
        }
        var framesByMode: [[[UInt8]]] = []
        for enabled in [false, true, nil] as [Bool?] {
            let driver = try WPEParitySceneDriver(device: device, reusePreparedScene: enabled)
            let mode = enabled.map(String.init) ?? "default"
            if let enabled {
                XCTAssertEqual(driver.reusesPreparedScene, enabled, "Explicit initializer wins over defaults/environment")
            } else if ProcessInfo.processInfo.environment[WPEParitySceneDriver.preparedSceneReuseEnvironmentKey] == nil,
                      UserDefaults.appScoped().object(forKey: WPEParitySceneDriver.preparedSceneReuseDefaultsKey) == nil {
                XCTAssertTrue(driver.reusesPreparedScene, "The ordinary unconfigured driver must exercise default-on reuse")
            }
            defer { driver.cleanup() }
            let cache = WPEParityShaderDiskCache(cachesURL: scratch)
            let layer = RecordingLayer()
            layer.device = device
            layer.pixelFormat = .rgba8Unorm
            layer.framebufferOnly = false
            func load(_ document: WPESceneDocument) async throws {
                try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                      drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                                      compiler: compiler, diskCache: cache, renderScaleOverride: 1, textureCompression: nil)
            }
            func resizedFrame(_ size: CGSize, label: String) async throws -> [UInt8] {
                driver.updateSurfaceGeometry(drawableSize: size)
                XCTAssertTrue(driver.needsReplan)
                let succeeded = await driver.replan()
                _ = try XCTUnwrap(succeeded ? true : nil, "Real resize must succeed: \(label)")
                layer.drawableSize = size
                try await present(driver, layer: layer, label: label)
                let renderer = try XCTUnwrap(driver.renderer)
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                return try readBack(XCTUnwrap(layer.lastTexture), device: device)
            }
            try await load(document(color: "0 1 0", shown: true))
            let green = try await resizedFrame(CGSize(width: 320, height: 192), label: "green reuse=\(mode)")
            XCTAssertTrue(stride(from: 0, to: green.count, by: 4).contains { green[$0 + 1] > 128 })
            let patch = WPEScenePropertyPatch(bindingsByProperty: driver.userPropertyBindings,
                                              oldValues: ["shown": .bool(true)], newValues: ["shown": .bool(false)])
            _ = try XCTUnwrap(driver.prepareUserProperties(patch, document: document(color: "0 1 0", shown: false))
                ? true : nil, "Authored visibility must use the product live-property path")
            _ = try XCTUnwrap(driver.commitUserProperties(patch) ? true : nil, "Property commit must succeed")
            let black = try await resizedFrame(CGSize(width: 160, height: 96), label: "hidden reuse=\(mode)")
            XCTAssertTrue(stride(from: 0, to: black.count, by: 4).allSatisfy {
                black[$0] == 0 && black[$0 + 1] == 0 && black[$0 + 2] == 0
            }, "A committed hidden layer must remain hidden after resize")
            try await load(document(color: "0 0 1", shown: true))
            let blue = try await resizedFrame(CGSize(width: 320, height: 192), label: "reload blue reuse=\(mode)")
            XCTAssertTrue(stride(from: 0, to: blue.count, by: 4).contains { blue[$0 + 2] > 128 })
            XCTAssertFalse(stride(from: 0, to: blue.count, by: 4).contains { blue[$0 + 1] > 128 },
                           "A new document must not reuse the prior load's green preparation")
            framesByMode.append([green, black, blue])
        }
        XCTAssertEqual(framesByMode[0], framesByMode[1], "Every presented pixel must match the original path")
        XCTAssertEqual(framesByMode[0], framesByMode[2], "Default construction must preserve every presented pixel")
    }

    func testFailedReplanWaitsForADifferentTarget() async throws {
        let (document, assets) = try sceneInputs()
        let compiler = try makeCompiler()
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer {
            WPEParitySceneDriver.remainingForcedReplanFailuresForTesting = 0
            driver.cleanup()
        }
        try await driver.load(document: document, assets: assets, settings: Self.settings, drawableSize: Self.size,
                              pixelFormat: .rgba8Unorm_srgb, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        XCTAssertTrue(driver.didLoad)

        WPEParitySceneDriver.remainingForcedReplanFailuresForTesting = 1
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 1280, height: 720))
        XCTAssertTrue(driver.needsReplan)
        let failed = await driver.replan()
        XCTAssertFalse(failed)
        XCTAssertFalse(driver.needsReplan, "a failed target would be rebuilt and logged again every frame")

        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 1600, height: 900))
        XCTAssertTrue(driver.needsReplan)
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertFalse(driver.needsReplan)
        XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.width, 1600)
    }

    /// Scene 3660962877 has a video .tex layer.
    func testSceneLoadedWhileSuspendedStartsWithItsVideosNotPlaying() async throws {
        let (document, assets) = try sceneInputs(sceneID: "3660962877")
        let compiler = try makeCompiler()
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        driver.applyPerformanceProfile(.suspended)
        try await driver.load(document: document, assets: assets, settings: Self.settings, drawableSize: Self.size,
                              pixelFormat: .rgba8Unorm_srgb, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        let renderer = try XCTUnwrap(driver.renderer)
        let playing = document.imageObjects.compactMap { renderer.scriptVideoCommand($0.id, .isPlaying, 0) }
        XCTAssertFalse(playing.isEmpty, "the scene has no video owner")
        XCTAssertEqual(playing, playing.map { _ in 0 })

        driver.applyPerformanceProfile(.quality)
        let resumed = document.imageObjects.compactMap { renderer.scriptVideoCommand($0.id, .isPlaying, 0) }
        XCTAssertEqual(resumed, resumed.map { _ in 1 })
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
        let track = try XCTUnwrap(runtime.debugTrackSnapshots().first)
        XCTAssertEqual(track.playerVolume, 0, "muted before load")
        XCTAssertGreaterThan(track.scheduledSegmentCount, 0)

        driver.cleanup()
        XCTAssertNil(driver.soundRuntime)
        XCTAssertTrue(runtime.debugTrackSnapshots().isEmpty, "cleanup stops and detaches every track")
    }

    func testConcurrentLoadsOfOneSceneCompileEachShaderOnce() async throws {
        let (_, assets) = try sceneInputs()
        let compiler = try makeCompiler()
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 160, "height": 96], "clearenabled": true,
                        "clearcolor": "0 0 0", "camerashake": false, "cameraparallax": false],
            "objects": [["id": 20, "name": "solid", "image": "models/util/solidlayer.json", "origin": "80 48 0",
                         "size": "12 12", "color": "0 1 0", "alpha": 1]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        @Sendable func load(_ cache: WPEParityShaderDiskCache) async throws -> WPEParityShaderStore.Statistics {
            let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: cache)
            XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
            return try XCTUnwrap(driver.diagnostics?.shaderCache)
        }
        let cold = try await load(WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cold")))
        let shared = WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "shared"))
        async let first = load(shared)
        async let second = load(shared)
        let pair = try await [first, second]
        XCTAssertGreaterThan(cold.compilations, 0)
        XCTAssertEqual(pair.map(\.compilations).reduce(0, +), cold.compilations, "cold \(cold), pair \(pair)")
        XCTAssertGreaterThan(pair.map(\.joinedRequests).reduce(0, +), 0, "pair \(pair)")
    }

    /// The unsigned Debug test host cannot provide the inherited sandbox required by the shipping helper.
    /// Explicit test inputs use the current source build; the signed Release product gate uses its bundle.
    func makeCompiler() throws -> WPEParityHelperShaderCompiler {
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

    nonisolated(nonsending) func present(_ driver: WPEParitySceneDriver, layer: CAMetalLayer, label: String) async throws {
        let commandBuffer = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                                       pointer: SIMD2(0.5, 0.5)),
                                          "\(label) was not presented")
        try await settle(driver, label: label)
        XCTAssertEqual(commandBuffer.status, .completed, label)
        XCTAssertNil(commandBuffer.error, label)
    }

    func capture(_ driver: WPEParitySceneDriver, colorSpace: CGColorSpace) async -> WPEDisplayedFrameCapture? {
        await withCheckedContinuation { continuation in
            driver.captureDisplayedFrame(colorSpace: colorSpace) { continuation.resume(returning: $0) }
        }
    }

    private func assertCapture(_ capture: WPEDisplayedFrameCapture, matches drawable: MTLTexture, expected: [UInt8],
                               device: MTLDevice, colorSpace: CGColorSpace, label: String) throws {
        XCTAssertEqual(capture.texture.width, drawable.width, label)
        XCTAssertEqual(capture.texture.height, drawable.height, label)
        XCTAssertEqual(capture.pixelFormat, drawable.pixelFormat, label)
        XCTAssertEqual(capture.texture.pixelFormat, drawable.pixelFormat, label)
        XCTAssertEqual(capture.colorSpace?.name, colorSpace.name, label)
        XCTAssertFalse(capture.isEDR, label)
        let actual = try readBack(capture.texture, device: device)
        XCTAssertEqual(actual.count, expected.count, label)
        let worst = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? .max
        XCTAssertLessThanOrEqual(worst, 1, label)
    }

    /// `completed()` can resume before the completion handlers that record readiness have run.
    nonisolated(nonsending) func settle(_ driver: WPEParitySceneDriver, label: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while driver.inFlightCount > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(driver.inFlightCount, 0, label)
    }

    func nextTimestamp() -> CFTimeInterval {
        timestamp += 1.0 / 60
        return timestamp
    }

    private func sceneClock(_ driver: WPEParitySceneDriver) throws -> WPEParityClock {
        try XCTUnwrap(driver.renderer).clock
    }

    func sceneInputs(sceneID: String = "3815666789") throws -> (WPESceneDocument, WPEParityProgramAssets) {
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
            data: Data(contentsOf: sceneDirectory.appending(path: "scene.json")), userValues: [:]
        )
        // The capture's wpeassets/ holds only shaders; util materials come from the WPE install.
        return (document, WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                                 assetRoots: [root.appending(path: "wpeassets"), wpeAssets]))
    }

    func readBack(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let bytesPerPixel = texture.pixelFormat == .rgba16Float ? 8 : 4
        let bytesPerRow = texture.width * bytesPerPixel
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

    /// Keeps the texture of the last drawable handed out, so the test can read what the present wrote.
    final class RecordingLayer: CAMetalLayer {
        private(set) var lastTexture: MTLTexture?

        override func nextDrawable() -> (any CAMetalDrawable)? {
            let drawable = super.nextDrawable()
            lastTexture = drawable?.texture
            return drawable
        }
    }

}
#endif
