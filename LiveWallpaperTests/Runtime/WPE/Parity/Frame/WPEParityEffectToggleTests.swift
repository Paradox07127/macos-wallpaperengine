#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// Effect visible bits and bloom constants change a running parity scene without a reload (R24 Q2, Q3, Q5), on the
/// capture fixture 3815666789, whose object 17 runs effects 19 (waterripple) and 50 (foliagesway).
final class WPEParityEffectToggleTests: XCTestCase {
    private static let width = 1920
    private static let height = 1080
    private static let sceneID = "3815666789"
    private static let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true)

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-effect-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testHiddenEffectMatchesASceneLoadedWithoutItAndComesBack() async throws {
        let toggled = try await makeFixtureRenderer()
        let renderer = toggled.renderer
        let pipelines = renderer.pipelineCreations
        try await encode(renderer)
        XCTAssertTrue(Self.drawnEffects(renderer).isSuperset(of: ["19", "50"]))

        XCTAssertTrue(renderer.state.setEffect("19", of: "17", visible: false))
        for _ in 1 ... 2 {
            try await encode(renderer)
            XCTAssertEqual(Self.drawnEffects(renderer), ["50"])
        }
        let without = try await makeFixtureRenderer { json in
            Self.editEffects(&json) { $0[0]["visible"] = false }
        }
        for _ in 1 ... 3 {
            try await encode(without.renderer)
        }
        let hidden = try readBack(renderer.backbuffer, toggled)
        XCTAssertTrue(try hidden == readBack(without.renderer.backbuffer, without),
                      "hiding effect 19 differs from a scene loaded without it")

        renderer.state.setEffect("19", of: "17", visible: true)
        for _ in 1 ... 2 {
            try await encode(renderer)
        }
        XCTAssertTrue(Self.drawnEffects(renderer).isSuperset(of: ["19", "50"]))
        let original = try await makeFixtureRenderer()
        for _ in 1 ... 5 {
            try await encode(original.renderer)
        }
        let shown = try readBack(renderer.backbuffer, toggled)
        XCTAssertTrue(try shown == readBack(original.renderer.backbuffer, original),
                      "showing effect 19 again differs from the scene as loaded")
        XCTAssertEqual(renderer.pipelineCreations, pipelines, "no pipeline is built after load")
    }

    func testEffectVisibleUserPropertyAppliesThroughTheDriver() async throws {
        let harness = try await makeDriver { json in
            Self.editEffects(&json) { $0[0]["visible"] = ["user": "ripple", "value": true] }
        }
        defer { harness.driver.cleanup() }
        XCTAssertEqual(harness.driver.userPropertyBindings["ripple"]?.map(\.action), [.incremental])
        let renderer = try XCTUnwrap(harness.driver.renderer)
        try await encode(renderer)
        XCTAssertTrue(Self.drawnEffects(renderer).contains("19"))

        XCTAssertTrue(try change(harness, "ripple", from: .bool(true), to: .bool(false)))
        try await encode(renderer)
        XCTAssertFalse(Self.drawnEffects(renderer).contains("19"))
        XCTAssertTrue(harness.driver.renderer === renderer, "the renderer is not rebuilt")
    }

    func testBloomStrengthAppliesNextFrameAndTheBloomSwitchReloads() async throws {
        let harness = try await makeDriver { json in
            var general = json["general"] as? [String: Any] ?? [:]
            general["bloom"] = ["user": "glowing", "value": true]
            general["bloomstrength"] = ["user": "glow", "value": 2]
            json["general"] = general
        }
        defer { harness.driver.cleanup() }
        let renderer = try XCTUnwrap(harness.driver.renderer)
        try await encode(renderer)
        XCTAssertEqual(try XCTUnwrap(Self.bloomStrength(renderer)), 2, accuracy: 1e-6)

        XCTAssertTrue(try change(harness, "glow", from: .number(2), to: .number(5)))
        try await encode(renderer)
        XCTAssertEqual(try XCTUnwrap(Self.bloomStrength(renderer)), 5, accuracy: 1e-6)
        XCTAssertTrue(harness.driver.renderer === renderer, "the renderer is not rebuilt")

        XCTAssertFalse(try change(harness, "glowing", from: .bool(true), to: .bool(false)),
                       "the bloom switch reloads")
    }

    // MARK: Helpers

    private struct Fixture {
        let renderer: WPEParityFrameRenderer
        let device: MTLDevice
        let queue: MTLCommandQueue
    }

    private struct DriverHarness {
        let driver: WPEParitySceneDriver
        let json: [String: Any]
    }

    /// Effect ids of the scene draws the last frame encoded.
    private static func drawnEffects(_ renderer: WPEParityFrameRenderer) -> Set<String> {
        Set(renderer.lastFrameDraws.compactMap { operation, _ in
            if case let .scene(draw)? = renderer.frames[0].draws[operation] {
                draw.effectID
            } else {
                nil
            }
        })
    }

    private static func bloomStrength(_ renderer: WPEParityFrameRenderer) -> Float? {
        renderer.lastFrameDraws.lazy.compactMap { operation, draw -> Float? in
            guard case let .post(post)? = renderer.frames[0].draws[operation],
                  post.shader == "downsample_quarter_bloom",
                  case let .float(value)? = draw.constants.values.lazy.compactMap({ $0["g_BloomStrength"] }).first
            else { return nil }
            return value
        }.first
    }

    private static func editEffects(_ json: inout [String: Any], _ body: (inout [[String: Any]]) -> Void) {
        var objects = json["objects"] as? [[String: Any]] ?? []
        for index in objects.indices where objects[index]["id"] as? Int == 17 {
            var effects = objects[index]["effects"] as? [[String: Any]] ?? []
            body(&effects)
            objects[index]["effects"] = effects
        }
        json["objects"] = objects
    }

    private func encode(_ renderer: WPEParityFrameRenderer) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("frame was skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error)
    }

    /// Prepares and commits one property change as the render actor does; false when prepare declines it.
    private func change(_ harness: DriverHarness, _ key: String, from old: WallpaperEngineProjectPropertyValue,
                        to new: WallpaperEngineProjectPropertyValue) throws -> Bool {
        let patch = WPEScenePropertyPatch(bindingsByProperty: harness.driver.userPropertyBindings,
                                          oldValues: [key: old], newValues: [key: new])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: harness.json),
                                                        userValues: [key: new])
        guard harness.driver.prepareUserProperties(patch, document: document) else { return false }
        return harness.driver.commitUserProperties(patch)
    }

    private func readBack(_ texture: MTLTexture, _ fixture: Fixture) throws -> [UInt8] {
        let bytesPerRow = texture.width * (texture.pixelFormat == .rgba16Float ? 8 : 4)
        let length = bytesPerRow * texture.height
        let buffer = try XCTUnwrap(fixture.device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(fixture.queue.makeCommandBuffer())
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

    private func paths() throws -> (root: URL, wpeAssets: URL) {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        return (root, wpeAssets)
    }

    private func sceneJSON(_ root: URL, edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        let url = root.appending(path: "scene-sources/\(Self.sceneID)/scene.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&json)
        return json
    }

    private func assets(_ root: URL, _ wpeAssets: URL) -> WPEParityProgramAssets {
        WPEParityProgramAssets(sceneDirectory: root.appending(path: "scene-sources/\(Self.sceneID)"),
                               assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
    }

    /// The capture scene with its JSON edited by `edit`, compiled from the capture's stages.
    private func makeFixtureRenderer(edit: (inout [String: Any]) -> Void = { _ in }) async throws -> Fixture {
        let (root, wpeAssets) = try paths()
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: sceneJSON(root, edit: edit)), userValues: [:]
        )
        let plan = try WPEParityFramePlan(document: document, assets: assets(root, wpeAssets),
                                          settings: Self.settings, width: Self.width, height: Self.height)
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms),
            diskCache: WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cache"))
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: "hlsl-capture-2026-10-12",
                                                bindingABIVersion: 1),
            particleSeed: 1
        )
        return Fixture(renderer: renderer, device: device, queue: queue)
    }

    /// The capture scene with its JSON edited by `edit`, loaded by a driver as the product loads it.
    private func makeDriver(edit: (inout [String: Any]) -> Void) async throws -> DriverHarness {
        let (root, wpeAssets) = try paths()
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(found): compiler = found
        case let .failure(reason): throw XCTSkip("\(reason)")
        }
        let json = try sceneJSON(root, edit: edit)
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try await driver.load(document: document, assets: assets(root, wpeAssets), settings: WPEParityProgramSettings(),
                              drawableSize: CGSize(width: Self.width, height: Self.height),
                              pixelFormat: .rgba8Unorm_srgb, compiler: compiler)
        return DriverHarness(driver: driver, json: json)
    }
}
#endif
