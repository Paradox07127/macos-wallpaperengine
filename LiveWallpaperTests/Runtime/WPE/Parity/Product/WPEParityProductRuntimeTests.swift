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

/// Captures, hibernate, static-scene pacing, activity and QA diagnostics of a parity scene on the render actor.
final class WPEParityProductRuntimeTests: XCTestCase {
    /// Under the poster's downsample limit, so the poster keeps every backbuffer pixel.
    private static let size = CGSize(width: 1280, height: 720)
    private static let sceneID = "3815666789"

    private var scratch: URL!
    private var actors: [WPEDisplayRenderActor] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-runtime-\(UUID().uuidString)",
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

    func testCapturesReturnThePresentedFrame() async throws {
        let harness = try await makeHarness()
        for _ in 1 ... 2 {
            try await renderFrame(harness)
        }
        let drawable = try XCTUnwrap(harness.layer.lastTexture)
        let capture = await harness.actor.captureDisplayedFrame()
        let displayed = try XCTUnwrap(capture)
        XCTAssertEqual([displayed.texture.width, displayed.texture.height], [drawable.width, drawable.height])
        XCTAssertEqual(displayed.pixelFormat, drawable.pixelFormat)
        let drawablePixels = try readBack(drawable)
        XCTAssertEqual(try readBack(displayed.texture), drawablePixels, "the capture replays the presented pass")
        let first = Array(drawablePixels.prefix(4))
        XCTAssertTrue(stride(from: 0, to: drawablePixels.count, by: 4).contains {
            Array(drawablePixels[$0 ..< $0 + 4]) != first
        }, "the drawable is one flat colour \(first)")

        let poster = await harness.actor.captureLivePoster()
        let backbuffer = try await harness.actor.run { actor in
            try XCTUnwrap(actor.parityDriverForTesting?.renderer?.backbuffer).snapshotSource
        }
        let reference = try XCTUnwrap(WPEMetalTextureSnapshotter.shared.snapshot(from: backbuffer.texture))
        XCTAssertEqual([backbuffer.texture.width, backbuffer.texture.height], [1280, 720])
        XCTAssertEqual(try pixels(XCTUnwrap(poster)), try pixels(reference), "the poster is the backbuffer")

        await harness.actor.applyPerformanceProfile(.suspended)
        let suspendedPoster = await harness.actor.captureLivePoster()
        XCTAssertNil(suspendedPoster, "as the old renderer, a suspended scene gives no poster")
    }

    func testHibernateReleasesTheSceneAndWakeRendersAgain() async throws {
        let harness = try await makeHarness()
        let device = harness.device
        for _ in 1 ... 2 {
            try await renderFrame(harness)
        }
        XCTAssertEqual(harness.activity.latest?.producesFrames, true)
        let loaded = device.currentAllocatedSize
        let hibernated = await harness.actor.hibernate()
        XCTAssertTrue(hibernated)
        try await settle(harness)
        let released = device.currentAllocatedSize
        print("parity hibernate: GPU allocated \(loaded) -> \(released) bytes")
        XCTAssertLessThan(released, loaded)
        XCTAssertEqual(harness.activity.latest?.producesFrames, false)
        XCTAssertEqual(harness.surface.lastIsPaused, true)
        let state = await harness.actor.rendererStateSnapshot()
        XCTAssertEqual(state?.isLoaded, false)
        let capture = await harness.actor.captureDisplayedFrame()
        XCTAssertNil(capture)
        let again = await harness.actor.hibernate()
        XCTAssertFalse(again, "nothing loaded to release")

        try await harness.actor.reload()
        try await renderFrame(harness)
        let wokenState = await harness.actor.rendererStateSnapshot()
        let woken = try XCTUnwrap(wokenState)
        XCTAssertTrue(woken.isLoaded)
        XCTAssertTrue(woken.hasPresentedFrame)
        XCTAssertEqual(harness.activity.latest?.producesFrames, true)
        print("parity wake: GPU allocated \(device.currentAllocatedSize) bytes")
    }

    func testStaticSceneParksTheLinkAfterItsFirstFrame() async throws {
        let harness = try await makeHarness { Self.edit(&$0) { $0["effects"] = [] } }
        XCTAssertEqual(harness.surface.lastIsPaused, false, "the first frame runs the link")
        try await renderFrame(harness)
        XCTAssertEqual(harness.surface.lastIsPaused, true, "parked after the first frame")
        XCTAssertEqual(harness.surface.lastEnableSetNeedsDisplay, true)
        XCTAssertEqual(harness.activity.latest, WPESceneRuntimeActivity(producesFrames: false, audible: false))
        let state = await harness.actor.rendererStateSnapshot()
        XCTAssertEqual(state?.parity?.isStatic, true)

        // A resume draws one frame, then parks again.
        await harness.actor.applyPerformanceProfile(.suspended)
        await harness.actor.applyPerformanceProfile(.quality)
        XCTAssertEqual(harness.surface.lastIsPaused, false)
        try await renderFrame(harness)
        XCTAssertEqual(harness.surface.lastIsPaused, true)

        let alpha: [String: Any] = ["value": 1, "animation": [
            "c0": [["frame": 0, "value": 1], ["frame": 30, "value": 0]],
            "options": ["fps": 30, "length": 30, "mode": "loop"],
        ]]
        let animated = try await makeHarness {
            Self.edit(&$0) { object in
                object["effects"] = []
                object["alpha"] = alpha
            }
        }
        try await renderFrame(animated)
        try await renderFrame(animated)
        XCTAssertEqual(animated.surface.lastIsPaused, false, "an animated alpha keeps the link running")
        XCTAssertEqual(animated.activity.latest?.producesFrames, true)
    }

    /// The parity sound runtime counts random play intervals down by frame time.
    func testStaticSceneWithSoundKeepsTheLinkRunning() async throws {
        let sound: [String: Any] = [
            "id": 900, "name": "sound", "sound": ["sounds/Melodysheep - Ether.flac"], "playbackmode": "random",
            "mintime": 1.0, "maxtime": 2.0, "volume": 1.0, "startsilent": false,
        ]
        let harness = try await makeHarness(withSound: true) { json in
            Self.edit(&json) { $0["effects"] = [] }
            json["objects"] = (json["objects"] as? [[String: Any]] ?? []) + [sound]
        }
        try await renderFrame(harness)
        try await renderFrame(harness)
        XCTAssertEqual(harness.surface.lastIsPaused, false, "a sound layer keeps the link running")
    }

    func testRendererStateCarriesParityDiagnostics() async throws {
        let harness = try await makeHarness()
        for _ in 1 ... 2 {
            try await renderFrame(harness)
        }
        let state = await harness.actor.rendererStateSnapshot()
        let snapshot = try XCTUnwrap(state)
        let parity = try XCTUnwrap(snapshot.parity)
        print("parity diagnostics: \(parity)")
        XCTAssertEqual(parity.loadGeneration, snapshot.currentLoadGeneration)
        XCTAssertGreaterThan(parity.drawCount, 0)
        XCTAssertGreaterThan(parity.encodedDrawCount, 0)
        XCTAssertGreaterThanOrEqual(parity.skippedDraws.values.reduce(0, +), snapshot.shaderErrorCount)
        XCTAssertGreaterThan(try XCTUnwrap(parity.encodeFrameCPUMeanMilliseconds), 0)
        XCTAssertGreaterThan(parity.arenaBytes, 0)
        XCTAssertGreaterThan(parity.dedicatedTextureBytes, 0)
        XCTAssertFalse(parity.isStatic, "the waterripple and foliagesway effects read g_Time")
        XCTAssertEqual(Set(parity.qaFields.keys), [
            "loadGeneration", "drawCount", "encodedDrawCount", "skippedDraws", "encodeFrameCPUMeanMs", "arenaBytes",
            "heapBytes", "dedicatedTextureBytes", "static",
        ])
        let diagnostics = SceneRendererDiagnostics(loadDiagnostics: nil, resolution: snapshot.resolution,
                                                   shaderErrors: .init(count: 0, entries: []),
                                                   gpuErrors: .init(count: 0, last: nil), parity: snapshot.parity)
        XCTAssertEqual(diagnostics.parity, parity)
    }

    // MARK: Harness

    private struct Harness {
        let actor: WPEDisplayRenderActor
        let device: MTLDevice
        let layer: RecordingLayer
        let surface: PacingRecorder
        let activity: ActivityRecorder
    }

    private func makeHarness(withSound: Bool = false,
                             edit: ((inout [String: Any]) -> Void)? = nil) async throws -> Harness {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        // An unsigned Debug test host cannot supply the shipping helper's inherited sandbox.
        // Xcode forwards TEST_RUNNER_WPE_* as WPE_*; explicit test inputs must select all three together.
        let environment = ProcessInfo.processInfo.environment
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER"]
        let compiler: WPEParityHelperShaderCompiler
        let compilerOrigin: String
        if keys.contains(where: { environment[$0] != nil }) {
            let urls = try keys.map { key in
                let path = try XCTUnwrap(environment[key].flatMap { $0.isEmpty ? nil : $0 },
                                         "Supply all three nonempty test toolchain paths: \(keys.joined(separator: ", "))")
                return URL(fileURLWithPath: path)
            }
            compiler = try WPEParityHelperShaderCompiler(helper: urls[0], dxcompiler: urls[1], metalIRConverter: urls[2],
                                                         workDirectory: scratch.appending(path: "shaderc"))
            compilerOrigin = "test-environment"
        } else {
            switch WPEParityShaderToolchain.makeCompiler() {
            case let .success(found): compiler = found
            case let .failure(reason): throw reason
            }
            compilerOrigin = "product-default"
        }
        print("parity runtime compilerOrigin=\(compilerOrigin) compilerIdentity=\(compiler.compilerIdentity)")
        // The sandboxed test host's home is its container; the WPE install lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let relativePath = "wpe-cache/\(UUID().uuidString)"
        let sceneDirectory = scratch.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sceneDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "scene-sources/\(Self.sceneID)"), to: sceneDirectory)
        if withSound {
            try FileManager.default.createDirectory(at: sceneDirectory.appending(path: "sounds"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: root.appending(path: "scene-sources/3509243656/sounds/Melodysheep - Ether.flac"),
                to: sceneDirectory.appending(path: "sounds/Melodysheep - Ether.flac")
            )
        }
        if let edit {
            let file = sceneDirectory.appending(path: "scene.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            edit(&json)
            try JSONSerialization.data(withJSONObject: json).write(to: file)
        }

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = Self.size
        layer.framebufferOnly = false
        let surface = PacingRecorder()
        let activity = ActivityRecorder()
        let inputs = WPEParitySceneInputs(
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
            drawableSize: Self.size,
            pixelFormat: layer.pixelFormat,
            soundResolver: withSound
                ? WPEMultiRootResourceResolver(primaryRootURL: sceneDirectory, dependencyMounts: []) : nil,
            onRuntimeActivityChange: { activity.record($0) }
        )
        let actor = WPEDisplayRenderActor()
        actors.append(actor)
        try await actor.adoptParity(inputs)
        await actor.setAudioMuted(true)
        try await actor.load()
        return Harness(actor: actor, device: device, layer: layer, surface: surface, activity: activity)
    }

    /// One display-link frame, waited for until its present completed.
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

    private static func edit(_ json: inout [String: Any], _ body: (inout [String: Any]) -> Void) {
        var objects = json["objects"] as? [[String: Any]] ?? []
        for index in objects.indices where objects[index]["id"] as? Int == 17 {
            body(&objects[index])
        }
        json["objects"] = objects
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

    private func pixels(_ image: NSImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
        return Array(data)
    }
}

private extension MTLTexture {
    var snapshotSource: WPEMetalTextureSnapshotter.SnapshotSource {
        WPEMetalTextureSnapshotter.SnapshotSource(texture: self)
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

/// Records the pacing the render actor last asked for.
private final class PacingRecorder: WPESurfaceControl {
    private struct Pacing {
        var isPaused: Bool?
        var enableSetNeedsDisplay: Bool?
    }

    private let last = OSAllocatedUnfairLock(initialState: Pacing())

    var lastIsPaused: Bool? {
        last.withLock(\.isPaused)
    }

    var lastEnableSetNeedsDisplay: Bool? {
        last.withLock(\.enableSetNeedsDisplay)
    }

    func applyPacing(_ update: WPERenderPacingUpdate) {
        last.withLock { state in
            state.isPaused = update.isPaused ?? state.isPaused
            state.enableSetNeedsDisplay = update.enableSetNeedsDisplay ?? state.enableSetNeedsDisplay
        }
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
