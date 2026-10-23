#if !LITE_BUILD && DEBUG
import AppKit
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore
import XCTest

/// A parity scene as the hidden producer of a span group: it renders one backbuffer at the union of the members and
/// publishes it; each member's `WPESceneSpanPresenter` shows its own part.
final class WPEParitySpanTests: XCTestCase {
    private static let sceneID = "3815666789"
    private static let members = [CGRect(x: 0, y: 0, width: 640, height: 360),
                                  CGRect(x: 640, y: 0, width: 640, height: 360)]
    private static let canvas = members.reduce(CGRect.null) { $0.union($1) }

    private var scratch: URL!
    private var actors: [WPEDisplayRenderActor] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-span-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        for actor in actors {
            await actor.teardownRenderer()
            await actor.shutdown()
        }
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testProducerPublishesTheSpanAndMembersShowTheirSlices() async throws {
        let harness = try await makeHarness()
        try await renderFrame(harness)
        let frame = try XCTUnwrap(harness.frames.latest(), "the producer published a frame")
        XCTAssertEqual([frame.texture.width, frame.texture.height], [1280, 360], "one backbuffer at the span size")
        XCTAssertEqual(frame.sourceSize, Self.canvas.size)
        XCTAssertEqual(frame.fitMode, .stretch, "cover crops in the scene camera; the members only slice")
        XCTAssertNil(harness.layer.lastTexture, "the producer never takes a drawable")
        let produced = await harness.actor.rendererStateSnapshot()
        XCTAssertEqual(produced?.hasPresentedFrame, false, "GPU production alone is not ready")

        let source = try await presentMembers(harness, frame: frame)
        let first = Array(source.prefix(4))
        XCTAssertTrue(stride(from: 0, to: source.count, by: 4).contains { Array(source[$0 ..< $0 + 4]) != first },
                      "the frame is one flat colour \(first)")

        var ready = false
        for _ in 0 ..< 500 where !ready {
            ready = await harness.actor.rendererStateSnapshot()?.hasPresentedFrame == true
            if !ready {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        XCTAssertTrue(ready, "a member's completed present makes the producer ready")
        let poster = await harness.actor.captureLivePoster()
        XCTAssertNotNil(poster, "the live poster copies the producer's backbuffer")
    }

    func testProducerPausesResumesAndHibernateReleasesIt() async throws {
        let harness = try await makeHarness()
        try await renderFrame(harness)
        let first = try XCTUnwrap(harness.frames.latest())
        XCTAssertEqual(harness.activity.latest?.producesFrames, true)

        await harness.actor.applyPerformanceProfile(.suspended)
        XCTAssertEqual(harness.surface.lastIsPaused, true, "a suspended producer stops its link")
        await harness.actor.applyPerformanceProfile(.quality)
        XCTAssertEqual(harness.surface.lastIsPaused, false)
        try await renderFrame(harness)
        let resumed = try XCTUnwrap(harness.frames.latest())
        XCTAssertGreaterThan(resumed.sequence, first.sequence, "frames publish again after the resume")
        XCTAssertEqual(resumed.generation, first.generation)

        let loaded = harness.device.currentAllocatedSize
        let hibernated = await harness.actor.hibernate()
        XCTAssertTrue(hibernated)
        try await settle(harness)
        XCTAssertNil(harness.frames.latest(), "hibernate retires the published frame")
        XCTAssertLessThan(harness.device.currentAllocatedSize, loaded)
        XCTAssertEqual(harness.surface.lastIsPaused, true)
        XCTAssertEqual(harness.activity.latest?.producesFrames, false)
        let state = await harness.actor.rendererStateSnapshot()
        XCTAssertEqual(state?.isLoaded, false)

        try await harness.actor.reload()
        try await renderFrame(harness)
        let woken = try XCTUnwrap(harness.frames.latest(), "the woken producer publishes again")
        let wokenState = await harness.actor.rendererStateSnapshot()
        XCTAssertEqual(woken.generation, wokenState?.currentLoadGeneration)
        XCTAssertGreaterThan(woken.generation, first.generation)

        await harness.actor.teardownRenderer()
        XCTAssertNil(harness.frames.latest())
    }

    func testSpanProducerKeepsNativeCanvasAtScaledDefaultsAndSlicesCorrectly() async throws {
        let defaults = try isolatedDefaults()
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let saved = defaults.object(forKey: key)
        defer { restore(defaults, key: key, value: saved) }
        for scale in [0.5, 0.75] {
            defaults.set(scale, forKey: key)
            XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, scale)
            let harness = try await makeHarness(requiredInputs: true)
            try await renderFrame(harness)
            let frame = try XCTUnwrap(harness.frames.latest())
            XCTAssertEqual([frame.texture.width, frame.texture.height], [1280, 360])
            XCTAssertEqual(frame.sourceSize, CGSize(width: 1280, height: 360))
            XCTAssertNil(harness.layer.lastTexture, "the hidden producer does not acquire a drawable")
            let pixels = try await presentMembers(harness, frame: frame)
            assertNonuniform(pixels)
            let producer = try await observe(harness)
            XCTAssertEqual(producer.size, SIMD2(1280, 360))
            XCTAssertEqual(producer.verdict, WPEMetalUpscalePlan.Verdict.settingOff.rawValue)
            XCTAssertEqual(producer.shaderErrors, 0)

            await harness.actor.applyPerformanceProfile(.suspended)
            XCTAssertEqual(harness.surface.lastIsPaused, true)
            XCTAssertEqual(harness.frames.latest()?.sequence, frame.sequence)
            await harness.actor.applyPerformanceProfile(.quality)
            XCTAssertEqual(harness.surface.lastIsPaused, false)
            try await renderFrame(harness)
            let resumed = try XCTUnwrap(harness.frames.latest())
            XCTAssertEqual(resumed.generation, frame.generation)
            XCTAssertGreaterThan(resumed.sequence, frame.sequence)
            XCTAssertEqual([resumed.texture.width, resumed.texture.height], [1280, 360])
            let hibernated = await harness.actor.hibernate()
            XCTAssertTrue(hibernated)
            try await settle(harness)
            XCTAssertNil(harness.frames.latest())
            XCTAssertEqual(harness.surface.lastIsPaused, true)
            let state = await harness.actor.rendererStateSnapshot()
            XCTAssertEqual(try XCTUnwrap(state).isLoaded, false)
            await harness.actor.teardownRenderer()
        }
    }

    func testStaticSingleScreenActorRecoversFromScalerDeclineAndAdoptsActualDrawableSize() async throws {
        let defaults = try isolatedDefaults()
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let saved = defaults.object(forKey: key)
        defer { restore(defaults, key: key, value: saved) }
        defaults.set(0.5, forKey: key)
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, 0.5)
        XCTAssertTrue(WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler, "this is a required MetalFX product gate")
        let harness = try await makeHarness(span: false, staticMedia: true, requiredInputs: true)
        let wroteAlpha = try await harness.actor.run { actor in
            let renderer = try XCTUnwrap(actor.parityDriverForTesting?.renderer)
            // The same typed field SceneScript writes; adding a script to the document would make it nonstatic.
            return renderer.state.set(.alpha, of: "17", to: SIMD4(repeating: 0.5))
        }
        XCTAssertTrue(wroteAlpha)
        XCTAssertEqual(harness.surface.lastIsPaused, false)
        try await renderFrame(harness)
        let first = try await observe(harness)
        XCTAssertEqual(first.size, SIMD2(640, 360))
        XCTAssertEqual(first.drawableSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(first.usedMetalFX, true, "the real scaler must encode successfully before the refusal")
        XCTAssertEqual(first.verdict, WPEMetalUpscalePlan.Verdict.active.rawValue)
        XCTAssertTrue(first.isStatic)
        XCTAssertEqual(first.alpha, 0.5)
        XCTAssertNotNil(first.mediaCurrentID, "the load must seed a real nonempty artwork texture")
        XCTAssertEqual(first.mediaRevision, 1)
        XCTAssertNotNil(first.mediaCurrentName)
        XCTAssertEqual(first.shaderErrors, 0)
        XCTAssertEqual(harness.surface.lastIsPaused, true)
        XCTAssertEqual(harness.surface.lastEnableSetNeedsDisplay, true)
        XCTAssertEqual(harness.activity.latest, WPESceneRuntimeActivity(producesFrames: false, audible: false))
        try assertNonuniform(readBack(XCTUnwrap(harness.layer.lastTexture)))

        // Only the next drawable changes. The production scaler rejects framebuffer-only output with usageMismatch.
        let requestsBeforeDecline = harness.surface.runningRequests
        harness.layer.framebufferOnly = true
        let declined = try await harness.actor.run { actor in
            actor.renderFrame()
            return try Self.observe(actor)
        }
        XCTAssertEqual(harness.layer.lastTexture?.isFramebufferOnly, true)
        XCTAssertEqual(declined.size, SIMD2(640, 360))
        XCTAssertEqual(declined.usedMetalFX, false)
        XCTAssertEqual(declined.verdict, WPEMetalUpscalePlan.Verdict.declinedAtPresent.rawValue)
        harness.layer.framebufferOnly = false
        try await settle(harness)
        let native = try await awaitReplan(harness, from: declined, size: SIMD2(1280, 720))
        assertContinued(native, from: declined)
        XCTAssertGreaterThan(harness.surface.runningRequests, requestsBeforeDecline)
        XCTAssertEqual(harness.surface.lastIsPaused, false, "Actor requests the static scene's replacement frame")
        try await renderFrame(harness)
        XCTAssertEqual(harness.surface.lastIsPaused, true, "the replacement frame parks the link again")
        let shown = try XCTUnwrap(harness.layer.lastTexture)
        XCTAssertEqual([shown.width, shown.height], [1280, 720])
        try assertMediaPixels(readBack(shown), width: 1280, height: 720)

        // The drawable changes without an updateSurfaceGeometry call. Its actual size must reach the Actor's replan.
        let requestsBeforeResize = harness.surface.runningRequests
        harness.layer.drawableSize = CGSize(width: 960, height: 540)
        let resizedPresent = try await harness.actor.run { actor in
            actor.renderFrame()
            return try Self.observe(actor)
        }
        XCTAssertEqual(harness.layer.lastTexture.map { SIMD2($0.width, $0.height) }, SIMD2(960, 540))
        XCTAssertEqual(resizedPresent.size, SIMD2(1280, 720), "the first new drawable still reads the existing renderer")
        XCTAssertEqual(resizedPresent.drawableSize, CGSize(width: 960, height: 540))
        try await settle(harness)
        let resized = try await awaitReplan(harness, from: resizedPresent, size: SIMD2(960, 540))
        assertContinued(resized, from: resizedPresent)
        XCTAssertEqual(resized.verdict, WPEMetalUpscalePlan.Verdict.declinedAtPresent.rawValue)
        XCTAssertGreaterThan(harness.surface.runningRequests, requestsBeforeResize)
        XCTAssertEqual(harness.surface.lastIsPaused, false)
        try await renderFrame(harness)
        XCTAssertEqual(harness.surface.lastIsPaused, true)
        XCTAssertEqual(harness.surface.lastEnableSetNeedsDisplay, true)
        let final = try XCTUnwrap(harness.layer.lastTexture)
        XCTAssertEqual([final.width, final.height], [960, 540])
        try assertMediaPixels(readBack(final), width: 960, height: 540)
        let state = await harness.actor.rendererStateSnapshot()
        XCTAssertTrue(try XCTUnwrap(state).hasPresentedFrame)
    }

    // MARK: Harness

    private struct Harness {
        let actor: WPEDisplayRenderActor
        let device: MTLDevice
        let layer: RecordingLayer
        let surface: PacingRecorder
        let activity: ActivityRecorder
        let frames: WPESceneSpanFrames
    }

    /// Values observed on the real render actor; no renderer or mutable media store crosses its isolation.
    private struct Observation: Sendable {
        let rendererID: ObjectIdentifier
        let generation: Int
        let size: SIMD2<Int>
        let drawableSize: CGSize
        let time: Double
        let pauseRamp: Float
        let alpha: Float?
        let mediaCurrentID: ObjectIdentifier?
        let mediaPreviousID: ObjectIdentifier?
        let mediaRevision: UInt64?
        let mediaCurrentName: String?
        let mediaPreviousName: String?
        let usedMetalFX: Bool?
        let verdict: String
        let shaderErrors: Int
        let isStatic: Bool
    }

    private static func observe(_ actor: isolated WPEDisplayRenderActor) throws -> Observation {
        let driver = try XCTUnwrap(actor.parityDriverForTesting)
        let renderer = try XCTUnwrap(driver.renderer)
        return Observation(
            rendererID: ObjectIdentifier(renderer), generation: driver.loadGeneration,
            size: SIMD2(renderer.backbuffer.width, renderer.backbuffer.height), drawableSize: driver.drawableSize,
            time: renderer.clock.time, pauseRamp: renderer.clock.pauseRamp,
            alpha: renderer.state.value(.alpha, of: "17")?.x,
            mediaCurrentID: renderer.mediaTextures?.current.map { ObjectIdentifier($0) },
            mediaPreviousID: renderer.mediaTextures?.previous.map { ObjectIdentifier($0) },
            mediaRevision: renderer.mediaTextures?.revision, mediaCurrentName: renderer.mediaTextures?.currentSystemName,
            mediaPreviousName: renderer.mediaTextures?.previousSystemName,
            usedMetalFX: driver.executor.lastPresentPass?.usedMetalFX,
            verdict: driver.executor.upscalePlan.verdict.rawValue, shaderErrors: driver.shaderErrorSummary.count,
            isStatic: renderer.isStatic
        )
    }

    private func observe(_ harness: Harness) async throws -> Observation {
        try await harness.actor.run { try Self.observe($0) }
    }

    private func awaitReplan(_ harness: Harness, from previous: Observation,
                             size: SIMD2<Int>) async throws -> Observation {
        let deadline = Date().addingTimeInterval(10)
        var current = try await observe(harness)
        while current.rendererID == previous.rendererID || current.size != size, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
            current = try await observe(harness)
        }
        XCTAssertNotEqual(current.rendererID, previous.rendererID, "Actor must replace the renderer without a manual replan")
        XCTAssertEqual(current.size, size)
        return current
    }

    private func assertContinued(_ current: Observation, from previous: Observation) {
        XCTAssertGreaterThan(previous.time, 0)
        XCTAssertEqual(current.time, previous.time, "replan must copy the running clock, not restart it")
        XCTAssertEqual(current.pauseRamp, previous.pauseRamp)
        XCTAssertEqual(current.generation, previous.generation, "replan must not reload the scene")
        XCTAssertEqual(current.alpha, 0.5, "the typed alpha writeback survives the renderer swap")
        XCTAssertEqual(current.mediaCurrentID, previous.mediaCurrentID)
        XCTAssertEqual(current.mediaPreviousID, previous.mediaPreviousID)
        XCTAssertEqual(current.mediaRevision, previous.mediaRevision)
        XCTAssertEqual(current.mediaCurrentName, previous.mediaCurrentName)
        XCTAssertEqual(current.mediaPreviousName, previous.mediaPreviousName)
        XCTAssertEqual(current.shaderErrors, 0)
        XCTAssertTrue(current.isStatic)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw unavailable("The Actor gate requires the existing isolated XCTest defaults store", required: true)
        }
        return defaults
    }

    private func restore(_ defaults: UserDefaults, key: String, value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func unavailable(_ reason: String, required: Bool) -> any Error {
        if required {
            return NSError(domain: "WPEParitySpanTests.RequiredInputs", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return XCTSkip(reason)
    }

    private func missingInput(_ reason: String, required: Bool) -> any Error {
        TestScratch.requiredInputError(XCTSkip(reason), failure: unavailable(reason, required: required))
    }

    /// Nonuniform external input: opaque red/green halves, independent of the WPE renderer.
    private func mediaArtwork() throws -> Data {
        var rgba: [UInt8] = []
        for _ in 0 ..< 8 {
            for column in 0 ..< 16 {
                rgba.append(contentsOf: column < 8 ? [255, 0, 0, 255] : [0, 255, 0, 255])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 16, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: 64, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw unavailable("Required media artwork could not be encoded", required: true)
        }
        return data as Data
    }

    private func assertNonuniform(_ pixels: [UInt8]) {
        let first = Array(pixels.prefix(4))
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains {
            Array(pixels[$0 ..< $0 + 4]) != first
        }, "the real shader must produce nonuniform pixels")
    }

    private func assertMediaPixels(_ pixels: [UInt8], width: Int, height: Int) {
        XCTAssertEqual(pixels.count, width * height * 4)
        // Original genericimage4 samples the cover and multiplies alpha by 0.5. Translucent over authored black
        // is red/green at 0.5; authored present -> sRGB drawable returns 128 and forces opaque alpha.
        for (x, expected) in [(width / 8, [128, 0, 0, 255]), (width * 7 / 8, [0, 128, 0, 255])] {
            let index = ((height / 2) * width + x) * 4
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(Int(pixels[index + channel]) - expected[channel]), channel == 3 ? 0 : 1,
                                         "native final pixel x=\(x), channel=\(channel)")
            }
        }
    }

    private func presentMembers(_ harness: Harness, frame: WPESceneSpanFrame) async throws -> [UInt8] {
        let source = try readBack(frame.texture)
        for member in Self.members {
            let layer = RecordingLayer()
            layer.device = harness.device
            // Present decodes authored sRGB; the sRGB drawable of the same layout encodes it back.
            XCTAssertEqual(frame.texture.pixelFormat, .rgba8Unorm)
            layer.pixelFormat = .rgba8Unorm_srgb
            layer.drawableSize = member.size
            layer.framebufferOnly = false
            let state = WPESceneSpanPresentationState()
            let presenter = try WPESceneSpanPresenter(
                device: harness.device, layer: WPEPresentLayer(layer: layer), frames: harness.frames, state: state,
                producer: harness.actor, configuration: .init(canvasFrame: Self.canvas, screenFrame: member), density: 1
            )
            presenter.present()
            let deadline = Date().addingTimeInterval(5)
            while !state.hasPresented(generation: frame.generation), Date() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(state.hasPresented(generation: frame.generation))
            let texture = try XCTUnwrap(layer.lastTexture)
            XCTAssertEqual([texture.width, texture.height], [640, 360])
            let slice = try readBack(texture)
            let width = Int(member.width)
            var maxDifference = 0
            for row in 0 ..< Int(member.height) {
                for column in 0 ..< width {
                    let sliceIndex = (row * width + column) * 4
                    let sourceIndex = (row * frame.texture.width + Int(member.minX) + column) * 4
                    for channel in 0 ..< 3 {
                        maxDifference = max(maxDifference, abs(Int(slice[sliceIndex + channel])
                                - Int(source[sourceIndex + channel])))
                    }
                }
            }
            XCTAssertLessThanOrEqual(maxDifference, 1, "member at x=\(member.minX) shows its region of the frame")
        }
        return source
    }

    private func makeHarness(span: Bool = true, staticMedia: Bool = false,
                             requiredInputs: Bool = false) async throws -> Harness {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw missingInput("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>",
                               required: requiredInputs)
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(found): compiler = found
        case let .failure(reason): throw missingInput("\(reason)", required: requiredInputs)
        }
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw missingInput("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)",
                               required: requiredInputs)
        }
        let relativePath = "wpe-cache/\(UUID().uuidString)"
        let sceneDirectory = scratch.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sceneDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "scene-sources/\(Self.sceneID)"), to: sceneDirectory)
        if staticMedia {
            let sceneFile = sceneDirectory.appending(path: "scene.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sceneFile)) as? [String: Any])
            var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
            guard objects.count == 1 else {
                throw unavailable("Required scene must contain its one original image layer", required: true)
            }
            objects[0]["effects"] = []
            json["objects"] = objects
            var general = try XCTUnwrap(json["general"] as? [String: Any])
            general["camerafade"] = false
            general["clearcolor"] = "0 0 0"
            json["general"] = general
            try JSONSerialization.data(withJSONObject: json).write(to: sceneFile)
            let modelPath = try XCTUnwrap(objects[0]["image"] as? String)
            let model = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: sceneDirectory.appending(path: modelPath))
            ) as? [String: Any])
            let materialFile = try sceneDirectory.appending(path: XCTUnwrap(model["material"] as? String))
            var material = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: materialFile)) as? [String: Any])
            var passes = try XCTUnwrap(material["passes"] as? [[String: Any]])
            guard passes.count == 1, passes[0]["shader"] as? String == "genericimage4" else {
                throw unavailable("Required material must retain its original genericimage4 pass", required: true)
            }
            passes[0]["usertextures"] = [["name": "$mediaThumbnail", "type": "system", "keepaspect": false]]
            material["passes"] = passes
            try JSONSerialization.data(withJSONObject: material).write(to: materialFile)
        }

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        let size = span ? Self.canvas.size : CGSize(width: 1280, height: 720)
        layer.drawableSize = size
        layer.framebufferOnly = false
        let surface = PacingRecorder()
        let activity = ActivityRecorder()
        let frames = WPESceneSpanFrames()
        var inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: Self.sceneID, cacheRelativePath: relativePath,
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
            pixelFormat: layer.pixelFormat,
            onRuntimeActivityChange: { activity.record($0) }
        )
        if span {
            inputs.span = (frames, Self.members.count + 8)
        }
        if staticMedia {
            let artwork = try mediaArtwork()
            inputs.media = await MainActor.run {
                WPESceneMediaEventDispatcher(source: SpanNowPlayingSource(
                    state: .init(phase: .playing, title: "Actor replan artwork", artwork: artwork)
                ))
            }
        }
        let actor = WPEDisplayRenderActor()
        actors.append(actor)
        try await actor.adoptParity(inputs)
        await actor.setAudioMuted(true)
        try await actor.load()
        return Harness(actor: actor, device: device, layer: layer, surface: surface, activity: activity,
                       frames: frames)
    }

    /// One display-link frame, waited for until its publication completed.
    private func renderFrame(_ harness: Harness) async throws {
        await harness.actor.renderFrame()
        try await settle(harness)
    }

    private func settle(_ harness: Harness) async throws {
        let deadline = Date().addingTimeInterval(5)
        var inFlight = await harness.actor.run { $0.parityDriverForTesting?.inFlightCount ?? 0 }
        while inFlight > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
            inFlight = await harness.actor.run { $0.parityDriverForTesting?.inFlightCount ?? 0 }
        }
        XCTAssertEqual(inFlight, 0)
    }

    private func readBack(_ texture: MTLTexture) throws -> [UInt8] {
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        let device = texture.device
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
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

/// Keeps the texture of the last drawable handed out, so the test can read what a present wrote.
private final class RecordingLayer: CAMetalLayer {
    private(set) var lastTexture: MTLTexture?

    override func nextDrawable() -> (any CAMetalDrawable)? {
        let drawable = super.nextDrawable()
        lastTexture = drawable?.texture
        return drawable
    }
}

/// Records the pacing the render actor last asked for.
private final class PacingRecorder: WPESurfaceControl {
    private struct State {
        var isPaused: Bool?
        var enableSetNeedsDisplay: Bool?
        var runningRequests = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var lastIsPaused: Bool? {
        state.withLock(\.isPaused)
    }

    var lastEnableSetNeedsDisplay: Bool? {
        state.withLock(\.enableSetNeedsDisplay)
    }

    var runningRequests: Int {
        state.withLock(\.runningRequests)
    }

    func applyPacing(_ update: WPERenderPacingUpdate) {
        state.withLock {
            $0.isPaused = update.isPaused ?? $0.isPaused
            $0.enableSetNeedsDisplay = update.enableSetNeedsDisplay ?? $0.enableSetNeedsDisplay
            if update.isPaused == false {
                $0.runningRequests += 1
            }
        }
    }

    func setClickCaptureEnabled(_: Bool) {}
}

private final class ActivityRecorder: Sendable {
    private let activity = OSAllocatedUnfairLock<WPESceneRuntimeActivity?>(initialState: nil)

    var latest: WPESceneRuntimeActivity? {
        activity.withLock { $0 }
    }

    func record(_ activity: WPESceneRuntimeActivity) {
        self.activity.withLock { $0 = activity }
    }
}

@MainActor
private final class SpanNowPlayingSource: WPENowPlayingEventSource {
    private let state: MonitorNowPlayingState

    init(state: MonitorNowPlayingState) {
        self.state = state
    }

    func subscribe(id _: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        handler(1, state)
    }

    func unsubscribe(id _: UUID) {}
}
#endif
