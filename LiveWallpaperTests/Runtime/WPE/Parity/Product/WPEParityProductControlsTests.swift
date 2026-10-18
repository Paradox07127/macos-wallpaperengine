#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore
import XCTest

/// The product controls `WPEDisplayRenderActor` forwards to a parity scene, on the capture fixtures.
final class WPEParityProductControlsTests: XCTestCase {
    private static let size = CGSize(width: 1920, height: 1080)

    private var scratch: URL!
    private var actors: [WPEDisplayRenderActor] = []
    private var videoBuckets: [URL] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-controls-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        for actor in actors {
            await actor.teardownRenderer()
            await actor.shutdown()
        }
        for bucket in videoBuckets {
            try? FileManager.default.removeItem(at: bucket)
        }
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testResizeReplansTheSceneAtTheNewSize() async throws {
        let fixture = try fixture()
        let (document, assets) = try sceneInputs("3815666789", fixture: fixture)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        try await driver.load(document: document, assets: assets, settings: WPEParityProgramSettings(),
                              drawableSize: Self.size, pixelFormat: .rgba8Unorm_srgb, compiler: fixture.compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = Self.size
        var timestamp: CFTimeInterval = 100
        func present(_ label: String) async throws {
            timestamp += 1.0 / 60
            let commandBuffer = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: timestamp,
                                                                           pointer: SIMD2(0.5, 0.5)), label)
            await commandBuffer.completed()
            XCTAssertNil(commandBuffer.error, label)
        }
        for frame in 1 ... 2 {
            try await present("frame \(frame) at 1920x1080")
        }
        let before = try XCTUnwrap(driver.renderer)
        XCTAssertEqual([before.backbuffer.width, before.backbuffer.height], [1920, 1080])

        let small = CGSize(width: 1280, height: 720)
        layer.drawableSize = small
        driver.updateSurfaceGeometry(drawableSize: small)
        XCTAssertTrue(driver.needsReplan)
        try await present("frame before the re-plan lands")
        XCTAssertTrue(driver.renderer === before, "frames keep the old plan until the new one is built")
        let time = before.clock.time
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertFalse(driver.needsReplan)
        let after = try XCTUnwrap(driver.renderer)
        XCTAssertEqual([after.backbuffer.width, after.backbuffer.height], [1280, 720])
        XCTAssertEqual(after.clock.time, time, "the scene clock carries over")
        for frame in 1 ... 2 {
            try await present("frame \(frame) at 1280x720")
        }
        XCTAssertEqual(driver.executor.lastPresentedDrawableSize, small)
        XCTAssertGreaterThan(after.clock.time, time)
        driver.cleanup()
    }

    /// Cover is WPE's default alignment, which crops the canvas to the target aspect about its centre;
    /// stretch is mode 2, which never crops. Contain and center render the scene's aspect for the present to box.
    func testFitModesChooseTheCameraCropAndTarget() throws {
        let (document, assets) = try sceneInputs("3815666789", fixture: fixture())
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = WPEParityCamera(document: document, renderTargetSize: SIMD2(1, 1)).size
        XCTAssertEqual(scene.y / scene.x, 9.0 / 16.0, accuracy: 1e-4)
        let drawable = CGSize(width: 1440, height: 1080)
        func bounds(_ mode: WPEPresentFitMode) throws -> SIMD4<Float> {
            let target = WPEParitySceneDriver.renderTarget(fitMode: mode, drawableSize: drawable, sceneSize: scene)
            XCTAssertEqual([target.width, target.height], [1440, 1080], "\(mode)")
            XCTAssertEqual(target.presentFit, .stretch, "\(mode)")
            let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                              width: target.width, height: target.height,
                                              alignment: target.alignment)
            return WPEParityFrameDrawPlanner(device: device, factory: WPEParityPipelineFactory(device: device),
                                             plan: plan).layers.camera.bounds
        }
        let excess = scene.x - scene.y * 1440 / 1080
        let cover = try bounds(.cover)
        XCTAssertEqual(cover.x, 0.5 * excess, accuracy: 1e-3)
        XCTAssertEqual(cover.y, scene.x - 0.5 * excess, accuracy: 1e-3)
        XCTAssertEqual(cover.w - cover.z, scene.y, accuracy: 1e-3)
        let stretch = try bounds(.stretch)
        XCTAssertEqual(stretch.x, 0)
        XCTAssertEqual(stretch.y, scene.x)

        let contain = WPEParitySceneDriver.renderTarget(fitMode: .contain, drawableSize: drawable, sceneSize: scene)
        XCTAssertEqual([contain.width, contain.height], [1440, 810])
        XCTAssertEqual(contain.presentFit, .contain)
        let large = CGSize(width: Double(scene.x) * 2, height: Double(scene.y) * 2)
        let center = WPEParitySceneDriver.renderTarget(fitMode: .center, drawableSize: large, sceneSize: scene)
        XCTAssertEqual([center.width, center.height], [Int(scene.x), Int(scene.y)])
        XCTAssertEqual(center.presentFit, .center)
        // A scene larger than the drawable keeps its size; the present crops it about the centre as the old renderer.
        let cropped = WPEParitySceneDriver.renderTarget(fitMode: .center, drawableSize: drawable, sceneSize: scene)
        XCTAssertEqual([cropped.width, cropped.height], [Int(scene.x), Int(scene.y)])
    }

    func testAdoptionSeedsTheSessionFitMode() async throws {
        let harness = try await makeHarness(sceneID: "3815666789", presentFitMode: .contain, load: false)
        let fitMode = await harness.actor.run { $0.parityDriverForTesting?.fitMode }
        XCTAssertEqual(fitMode, .contain)
    }

    func testFrameRateCeilingAndThrottleReachParityPacing() async throws {
        let harness = try await makeHarness(sceneID: "3815666789", load: false)
        await harness.actor.setFrameRateCeiling(24)
        XCTAssertEqual(harness.surface.lastFramesPerSecond, 24)
        await harness.actor.setAdaptiveFrameRateThrottle(true)
        XCTAssertEqual(harness.surface.lastFramesPerSecond, 15, "half the ceiling, floored at 15")
        await harness.actor.setAdaptiveFrameRateThrottle(false)
        XCTAssertEqual(harness.surface.lastFramesPerSecond, 24)
    }

    func testPointerFollowsTheMailboxOnlyWithMouseInteraction() async throws {
        let harness = try await makeHarness(sceneID: "3815666789")
        let actor = harness.actor
        let mailbox = harness.mailbox
        mailbox.publishGeometry(WPEPointerMailbox.Geometry(viewFrameInScreen: CGRect(x: 0, y: 0, width: 960,
                                                                                     height: 540)))
        func pointer(at location: CGPoint) async throws -> WPEParityUniformPointer {
            mailbox.publishMouseLocation(location, timestampNanos: 1)
            await actor.renderFrame()
            let pointer = await actor.run { $0.parityDriverForTesting?.renderer?.pointer }
            return try XCTUnwrap(pointer)
        }

        // Screen y is up; the uniform is y down.
        var first = try await pointer(at: CGPoint(x: 240, y: 135))
        var second = try await pointer(at: CGPoint(x: 720, y: 405))
        XCTAssertEqual(first.position.x, 0.25, accuracy: 1e-4)
        XCTAssertEqual(first.position.y, 0.75, accuracy: 1e-4)
        XCTAssertEqual(second.position.x, 0.75, accuracy: 1e-4)
        XCTAssertEqual(second.position.y, 0.25, accuracy: 1e-4)

        await actor.setMouseInteractionEnabled(false)
        first = try await pointer(at: CGPoint(x: 240, y: 135))
        second = try await pointer(at: CGPoint(x: 720, y: 405))
        XCTAssertEqual(first.position, second.position)
        XCTAssertEqual(second.position, SIMD2(0.5, 0.5))

        let press = WPEPointerFrame(position: SIMD2(0.75, 0.25), clickPosition: SIMD2(0.75, 0.25), isDown: true,
                                    isRightDown: false)
        mailbox.publishPointerFrame(press)
        let uncaptured = try await pointer(at: CGPoint(x: 720, y: 405))
        XCTAssertFalse(uncaptured.isDown, "click capture off")
        mailbox.publishPointerFrame(.neutral)
        await actor.setClickCaptureEnabled(true)
        XCTAssertEqual(harness.surface.clickCaptureEnabled, true)
        mailbox.publishPointerFrame(press)
        let pressed = try await pointer(at: CGPoint(x: 720, y: 405))
        XCTAssertTrue(pressed.isDown)
        XCTAssertEqual(pressed.state, SIMD4(1, 1, 1, 0))
    }

    func testSceneReadingAudioSpectrumRequiresSystemAudioCapture() async throws {
        // Object 1003's Simple_Audio_Bars fragment shader reads g_AudioSpectrum16Left.
        let audio = try await makeHarness(sceneID: "3660962877")
        let requiresAudio = await audio.actor.requiresSystemAudioCapture()
        XCTAssertTrue(requiresAudio)
        let silent = try await makeHarness(sceneID: "3815666789")
        let requiresNoAudio = await silent.actor.requiresSystemAudioCapture()
        XCTAssertFalse(requiresNoAudio)
    }

    func testVideoTexturesUseTheDescriptorWorkshopID() async throws {
        let workshopID = "parity-video-\(UUID().uuidString)"
        let directoryName = "renamed-\(UUID().uuidString)"
        let bucket = WPEVideoTextureDiskCache.defaultRootURL.appending(path: workshopID, directoryHint: .isDirectory)
        let directoryBucket = WPEVideoTextureDiskCache.defaultRootURL.appending(path: directoryName,
                                                                                directoryHint: .isDirectory)
        videoBuckets += [bucket, directoryBucket]
        _ = try await makeHarness(sceneID: "3660962877", workshopID: workshopID, directoryName: directoryName)
        let stored = try FileManager.default.contentsOfDirectory(atPath: bucket.path)
        XCTAssertEqual(stored.filter { $0.hasSuffix(".mp4") }.count, 1, "\(stored)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryBucket.path))
    }

    private struct Harness {
        let actor: WPEDisplayRenderActor
        let mailbox: WPEPointerMailbox
        let surface: RecordingSurfaceControl
    }

    private struct Fixture {
        let root: URL
        let wpeAssets: URL
        let compiler: WPEParityHelperShaderCompiler
    }

    private func fixture() throws -> Fixture {
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
        return Fixture(root: root, wpeAssets: wpeAssets, compiler: compiler)
    }

    private func sceneInputs(_ sceneID: String, fixture: Fixture) throws -> (WPESceneDocument, WPEParityProgramAssets) {
        let sceneDirectory = fixture.root.appending(path: "scene-sources/\(sceneID)")
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: sceneDirectory.appending(path: "scene.json")), userValues: [:]
        )
        return (document, WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                                 assetRoots: [fixture.root.appending(path: "wpeassets"),
                                                              fixture.wpeAssets]))
    }

    /// The fixture scene installed as an extracted `.cache` scene in `directoryName` and adopted by a fresh actor.
    private func makeHarness(sceneID: String, workshopID: String? = nil, directoryName: String? = nil,
                             presentFitMode: WPEPresentFitMode = .cover, load: Bool = true) async throws -> Harness {
        let fixture = try fixture()
        let root = fixture.root
        let wpeAssets = fixture.wpeAssets
        let compiler = fixture.compiler
        let relativePath = "wpe-cache/\(directoryName ?? sceneID)"
        let sceneDirectory = scratch.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sceneDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "scene-sources/\(sceneID)"), to: sceneDirectory)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = Self.size
        let mailbox = WPEPointerMailbox()
        let surface = RecordingSurfaceControl()
        let inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: workshopID ?? sceneID, cacheRelativePath: relativePath,
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: sceneDirectory),
            projectRoot: sceneDirectory,
            assets: WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                           assetRoots: [root.appending(path: "wpeassets"), wpeAssets]),
            settings: WPEParityProgramSettings(),
            compiler: compiler,
            device: device,
            presentLayer: WPEPresentLayer(layer: layer),
            mailbox: mailbox,
            surfaceControl: surface,
            drawableSize: Self.size,
            pixelFormat: layer.pixelFormat,
            presentFitMode: presentFitMode
        )
        let actor = WPEDisplayRenderActor()
        actors.append(actor)
        try await actor.adoptParity(inputs)
        if load {
            try await actor.load()
        }
        return Harness(actor: actor, mailbox: mailbox, surface: surface)
    }
}

/// Records what the render actor asks of the surface.
private final class RecordingSurfaceControl: WPESurfaceControl {
    private struct Recorded {
        var framesPerSecond: Int?
        var clickCaptureEnabled: Bool?
    }

    private let recorded = OSAllocatedUnfairLock(initialState: Recorded())

    var lastFramesPerSecond: Int? {
        recorded.withLock(\.framesPerSecond)
    }

    var clickCaptureEnabled: Bool? {
        recorded.withLock(\.clickCaptureEnabled)
    }

    func applyPacing(_ update: WPERenderPacingUpdate) {
        guard let fps = update.preferredFramesPerSecond else { return }
        recorded.withLock { $0.framesPerSecond = fps }
    }

    func setNeedsRedraw() {}

    func drawImmediately() {}

    func releaseDrawables() {}

    func detach() {}

    func setClickCaptureEnabled(_ enabled: Bool) {
        recorded.withLock { $0.clickCaptureEnabled = enabled }
    }
}
#endif
