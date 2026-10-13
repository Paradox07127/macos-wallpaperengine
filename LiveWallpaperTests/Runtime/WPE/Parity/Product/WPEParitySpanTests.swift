#if !LITE_BUILD && DEBUG
import AppKit
import Foundation
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

        let source = try readBack(frame.texture)
        for member in Self.members {
            let layer = RecordingLayer()
            layer.device = harness.device
            // The present decodes the authored sRGB values; an sRGB drawable of the same layout encodes them back.
            XCTAssertEqual(frame.texture.pixelFormat, .rgba8Unorm)
            layer.pixelFormat = .rgba8Unorm_srgb
            layer.drawableSize = member.size
            layer.framebufferOnly = false
            let state = WPESceneSpanPresentationState()
            let presenter = try WPESceneSpanPresenter(
                device: harness.device, layer: WPEPresentLayer(layer: layer), frames: harness.frames, state: state,
                producer: harness.actor, configuration: .init(canvasFrame: Self.canvas, screenFrame: member),
                density: 1
            )
            presenter.present()
            let deadline = Date().addingTimeInterval(5)
            while !state.hasPresented(generation: frame.generation), Date() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(state.hasPresented(generation: frame.generation))
            let slice = try readBack(XCTUnwrap(layer.lastTexture))
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

    // MARK: Harness

    private struct Harness {
        let actor: WPEDisplayRenderActor
        let device: MTLDevice
        let layer: RecordingLayer
        let surface: PacingRecorder
        let activity: ActivityRecorder
        let frames: WPESceneSpanFrames
    }

    private func makeHarness() async throws -> Harness {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(found): compiler = found
        case let .failure(reason): throw XCTSkip("\(reason)")
        }
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
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = Self.canvas.size
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
            drawableSize: Self.canvas.size,
            pixelFormat: layer.pixelFormat,
            onRuntimeActivityChange: { activity.record($0) }
        )
        inputs.span = (frames, Self.members.count + 8)
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

private final class ActivityRecorder: Sendable {
    private let activity = OSAllocatedUnfairLock<WPESceneRuntimeActivity?>(initialState: nil)

    var latest: WPESceneRuntimeActivity? {
        activity.withLock { $0 }
    }

    func record(_ activity: WPESceneRuntimeActivity) {
        self.activity.withLock { $0 = activity }
    }
}
#endif
