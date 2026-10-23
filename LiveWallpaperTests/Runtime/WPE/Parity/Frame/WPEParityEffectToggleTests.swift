#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// Effect visible bits and bloom constants change a running parity scene without a reload, on the
/// capture fixture 3815666789, whose object 17 runs effects 19 (waterripple) and 50 (foliagesway).
final class WPEParityEffectToggleTests: XCTestCase {
    private static let width = 1920
    private static let height = 1080
    private static let sceneID = "3815666789"
    private static let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaaSampleCount: 2)

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

        XCTAssertTrue(renderer.instance.state.setEffect("19", of: "17", visible: false))
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
        XCTAssertEqual(Self.drawnEffects(without.renderer), ["50"], "an authored hidden effect draws at load")
        let hidden = try readBack(renderer.backbuffer, toggled)
        XCTAssertTrue(try hidden == readBack(without.renderer.backbuffer, without),
                      "hiding effect 19 differs from a scene loaded without it")

        renderer.instance.state.setEffect("19", of: "17", visible: true)
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

    /// Each effect set and every switch between them draws the same bytes whether pooled targets alias or not.
    func testEffectCombinationsDrawTheSameBytesWithRenderTargetAliasing() async throws {
        let plain = try await makeFixtureRenderer()
        let aliased = try await makeFixtureRenderer(aliasing: true)
        XCTAssertFalse(aliased.renderer.aliasedRenderTargets.isEmpty, "the scene aliases no render target")
        let steps: [(ripple: Bool, sway: Bool)] = [
            (true, true), (false, true), (false, false), (true, false), (true, true), (false, false), (true, true),
        ]
        for (index, step) in steps.enumerated() {
            for fixture in [plain, aliased] {
                fixture.renderer.instance.state.setEffect("19", of: "17", visible: step.ripple)
                fixture.renderer.instance.state.setEffect("50", of: "17", visible: step.sway)
            }
            for frame in 1 ... 3 {
                try await encode(plain.renderer)
                try await encode(aliased.renderer)
                XCTAssertTrue(try readBack(plain.renderer.backbuffer, plain)
                    == readBack(aliased.renderer.backbuffer, aliased),
                    "step \(index) \(step) frame \(frame) differs with aliasing")
            }
        }
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

    func testBloomStrengthAndTheBloomSwitchApplyNextFrame() async throws {
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

        // general.bloom has no onChanged hook; Main polls its bit every frame (17fa70, 180a41..180a75).
        XCTAssertTrue(try change(harness, "glowing", from: .bool(true), to: .bool(false)))
        try await encode(renderer)
        XCTAssertNil(Self.bloomStrength(renderer), "the bloom switch still draws bloom")
        XCTAssertTrue(harness.driver.renderer === renderer, "the renderer is not rebuilt")
    }

    func testConditionalTextureChangeAfterACachedEffectReturnReachesItsReader() async throws {
        // TEXB4: raw red 2x2 base, green replacement while the bool `enabled` is true.
        let tex = try XCTUnwrap(Data(base64Encoded: "VEVYVjAwMDUAVEVYSTAwMDEAAAAAAAMAAAACAAAAAgAAAAIAAAACAAAAAAAAAFRFWEIwMDA0AAEAAAD/////AQAAAEcAAAAoIwAAAgAAAHsiY29uZGl0aW9uIjoiZW5hYmxlZCJ9AAEAAAACAAAAAgAAAAAAAAAQAAAAEAAAAP8AAP//AAD//wAA//8AAP8BAAAAAQAAABMAAAAoIwAAAAAAAAAAAAACAAAAAgAAAP////8QAAAAAP8A/wD/AP8A/wD/AP8A/w=="))
        let harness = try await makeSyntheticDriver(texture: tex, objects: [
            ["id": 1, "name": "imported", "image": "models/toggle.json", "origin": "16 8 0", "size": "32 16", "alpha": 1],
            ["id": 2, "name": "direct", "image": "models/util/solidlayer.json", "origin": "48 8 0", "size": "32 16",
             "color": "0 0 0", "alpha": 1, "effects": [["id": 4, "file": "effects/toggle.json"]]],
        ], userPropertiesJSON: #"{"enabled":{"type":"bool","value":true}}"#)
        defer { harness.driver.cleanup() }
        let renderer = try XCTUnwrap(harness.driver.renderer)
        try await encode(renderer)
        renderer.instance.state.setEffect("4", of: "2", visible: false)
        try await encode(renderer)
        renderer.instance.state.setEffect("4", of: "2", visible: true)
        try await encode(renderer)
        XCTAssertEqual(Self.drawnEffects(renderer), ["4"])

        XCTAssertTrue(try change(harness, "enabled", from: .bool(true), to: .bool(false)))
        try await encode(renderer)
        let imported = try XCTUnwrap(Self.sampledTexture(renderer, objectID: "1", effect: false))
        let direct = try XCTUnwrap(Self.sampledTexture(renderer, objectID: "2", effect: true))
        XCTAssertTrue(imported === direct, "the effect restored from the graph cache must read the replaced texture")
    }

    /// A solidlayer parent is not passthrough, so its child draws in the scene loop at its own place (40,8), outside
    /// the parent's 32x16 composite.
    func testChildOfANonPassthroughParentWithAnEffectDrawsIntoTheScene() async throws {
        let tex = try XCTUnwrap(Data(base64Encoded: "VEVYVjAwMDUAVEVYSTAwMDEAAAAAAAMAAAACAAAAAgAAAAIAAAACAAAAAAAAAFRFWEIwMDA0AAEAAAD/////AQAAAEcAAAAoIwAAAgAAAHsiY29uZGl0aW9uIjoiZW5hYmxlZCJ9AAEAAAACAAAAAgAAAAAAAAAQAAAAEAAAAP8AAP//AAD//wAA//8AAP8BAAAAAQAAABMAAAAoIwAAAAAAAAAAAAACAAAAAgAAAP////8QAAAAAP8A/wD/AP8A/wD/AP8A/w=="))
        let harness = try await makeSyntheticDriver(texture: tex, objects: [
            ["id": 1, "name": "parent", "image": "models/util/solidlayer.json", "origin": "16 8 0", "size": "32 16",
             "color": "0 0 0", "alpha": 1, "effects": [["id": 4, "file": "effects/toggle.json"]]],
            ["id": 2, "name": "child", "image": "models/util/solidlayer.json", "parent": 1, "origin": "24 0 0",
             "size": "16 16", "color": "1 1 1", "alpha": 1],
        ], userPropertiesJSON: #"{"enabled":{"type":"bool","value":false}}"#)
        defer { harness.driver.cleanup() }
        let renderer = try XCTUnwrap(harness.driver.renderer)
        try await encode(renderer)
        let device = renderer.backbuffer.device
        let fixture = try Fixture(renderer: renderer, device: device, queue: XCTUnwrap(device.makeCommandQueue()))
        let pixels = try readBack(renderer.backbuffer, fixture)
        let offset = (8 * renderer.backbuffer.width + 40) * 4
        XCTAssertEqual(Array(pixels[offset ..< offset + 3]), [255, 255, 255])
    }

    /// A first writer whose fragment stage may discard does not overwrite the whole target, so the target keeps its
    /// own texture: the checker the first frame drew survives where the second frame discards.
    func testDiscardingFirstWriterKeepsItsTargetDedicated() async throws {
        let harness = try await makeFirstWriterDriver(discards: true)
        defer { harness.driver.cleanup() }
        let renderer = try XCTUnwrap(harness.driver.renderer)
        let target = try XCTUnwrap(Self.firstWriterTarget(renderer))
        XCTAssertFalse(renderer.aliasedRenderTargets.contains(target), "a discarding first writer is aliased")
        try await encode(renderer)
        // The clock caps a step at 0.25 s, which takes the second frame past the shader's 0.1 s switch.
        try await encode(renderer, elapsed: 0.25)
        let texture = try XCTUnwrap(renderer.renderTarget(target))
        let device = renderer.backbuffer.device
        let fixture = try Fixture(renderer: renderer, device: device, queue: XCTUnwrap(device.makeCommandQueue()))
        let pixels = try readBack(texture, fixture)
        func pixel(_ u: Double, _ v: Double) -> [UInt8] {
            let offset = (Int(v * Double(texture.height)) * texture.width + Int(u * Double(texture.width))) * 4
            return Array(pixels[offset ..< offset + 4])
        }
        XCTAssertEqual(pixel(0.125, 0.25), [0, 255, 0, 255], "the second frame did not draw the left half")
        let row = [pixel(0.625, 0.25), pixel(0.875, 0.25)]
        XCTAssertEqual(Set(row), [[0, 0, 0, 255], [255, 255, 255, 255]], "the first frame's checker is lost")
        XCTAssertEqual([pixel(0.625, 0.75), pixel(0.875, 0.75)], row.reversed(), "the first frame's checker is lost")
    }

    func testFullscreenOpaqueFirstWriterIsAliased() async throws {
        let harness = try await makeFirstWriterDriver(discards: false)
        defer { harness.driver.cleanup() }
        let renderer = try XCTUnwrap(harness.driver.renderer)
        let target = try XCTUnwrap(Self.firstWriterTarget(renderer))
        XCTAssertTrue(renderer.aliasedRenderTargets.contains(target),
                      "aliased \(renderer.aliasedRenderTargets.sorted()) lacks \(target)")
    }

    // MARK: Helpers

    private static func firstWriterTarget(_ renderer: WPEParityFrameRenderer) -> WPEResourceID? {
        renderer.frames[0].draws.values.lazy.compactMap { description -> WPEResourceID? in
            guard case let .scene(draw) = description, draw.shader == "firstwriter" else { return nil }
            return draw.target
        }.first
    }

    /// A 32x32 solid layer whose first effect draws `firstwriter` into its own FBO and then passes that FBO through;
    /// a second effect keeps the first one out of the passes that draw with the layer's matrices.
    private func makeFirstWriterDriver(discards: Bool) async throws -> DriverHarness {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(found): compiler = found
        case let .failure(reason): throw XCTSkip("\(reason)")
        }
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
        \tgl_Position = vec4(a_Position, 1.0);
        \tv_TexCoord = a_TexCoord;
        }
        """
        // A 4x2 checker of black and white cells before 0.1 s, green after; `discards` drops the right half then.
        let fragment = """
        varying vec2 v_TexCoord;
        uniform float g_Time;
        void main() {
        \(discards ? "\tif (g_Time > 0.1 && v_TexCoord.x > 0.5) discard;" : "")
        \tfloat column = step(0.25, v_TexCoord.x) - step(0.5, v_TexCoord.x) + step(0.75, v_TexCoord.x);
        \tfloat on = abs(column - step(0.5, v_TexCoord.y));
        \tgl_FragColor = g_Time > 0.1 ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(on, on, on, 1.0);
        }
        """
        let opaque: [String: Any] = ["blending": "normal", "depthtest": "disabled", "depthwrite": "disabled",
                                     "cullmode": "nocull"]
        let effect: [String: Any] = [
            "fbos": [["name": "firstwriter", "format": "rgba8888", "scale": 1]],
            "passes": [
                ["material": "materials/firstwriter.json", "target": "firstwriter"],
                ["material": "materials/util/passthrough.json", "bind": [["index": 0, "name": "firstwriter"]]],
            ],
        ]
        let files: [String: Data] = try [
            "shaders/firstwriter.vert": Data(vertex.utf8),
            "shaders/firstwriter.frag": Data(fragment.utf8),
            "materials/firstwriter.json": JSONSerialization.data(withJSONObject: [
                "passes": [opaque.merging(["shader": "firstwriter"]) { $1 }],
            ]),
            "effects/firstwriter.json": JSONSerialization.data(withJSONObject: effect),
            "materials/tail.json": JSONSerialization.data(withJSONObject: [
                "passes": [opaque.merging(["shader": "passthrough", "textures": [NSNull()]]) { $1 }],
            ]),
            "effects/tail.json": JSONSerialization.data(withJSONObject: ["passes": [["material": "materials/tail.json"]]]),
        ]
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }, .directory(wpeAssets)])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32], "clearcolor": "0 0 0",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": [["id": 1, "name": "layer", "image": "models/util/solidlayer.json", "origin": "16 16 0",
                         "size": "32 32", "color": "0 0 0", "alpha": 1,
                         "effects": [["id": 7, "file": "effects/firstwriter.json"], ["id": 8, "file": "effects/tail.json"]]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        var settings = WPEParityProgramSettings(bloom: false)
        settings.renderTargetAliasing = true
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try await driver.load(document: document, assets: assets, settings: settings,
                              drawableSize: CGSize(width: 32, height: 32), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        return DriverHarness(driver: driver, json: json)
    }

    private static func sampledTexture(_ renderer: WPEParityFrameRenderer, objectID: String,
                                       effect: Bool) -> MTLTexture? {
        let (shader, slot) = effect ? ("effects/blend", "g_Texture1") : ("passthrough", "g_Texture0")
        return renderer.lastFrameDraws.lazy.compactMap { operation, draw -> MTLTexture? in
            guard case let .scene(scene)? = renderer.frames[0].draws[operation], scene.objectID == objectID,
                  (scene.effectID != nil) == effect, scene.shader == shader else { return nil }
            return draw.textures[slot]
        }.first
    }

    /// A 64x16 scene over the installed WPE assets whose `toggle` model, material and effect sample `texture`.
    private func makeSyntheticDriver(texture: Data, objects: [[String: Any]],
                                     userPropertiesJSON: String = "{}") async throws -> DriverHarness {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(found): compiler = found
        case let .failure(reason): throw XCTSkip("\(reason)")
        }
        let pass: [String: Any] = ["shader": "passthrough", "textures": ["toggle"], "combos": ["TRANSFORM": 1],
                                   "blending": "normal"]
        // BLENDMODE 0 is normal blending, so the opaque blend texture replaces the layer input.
        let blend: [String: Any] = ["shader": "effects/blend", "textures": [NSNull(), "toggle"],
                                    "combos": ["BLENDMODE": 0], "blending": "normal"]
        var files: [String: Data] = try [
            "materials/toggle.tex": texture,
            "models/toggle.json": JSONSerialization.data(withJSONObject: ["material": "materials/toggle.json"]),
            "materials/toggle.json": JSONSerialization.data(withJSONObject: ["passes": [pass]]),
            "materials/toggle-blend.json": JSONSerialization.data(withJSONObject: ["passes": [blend]]),
            "effects/toggle.json": JSONSerialization.data(withJSONObject: ["passes": [["material": "materials/toggle-blend.json"]]]),
        ]
        for stage in ["vert", "frag"] {
            let stock = wpeAssets.appending(path: "effects/blend/shaders/effects/blend.\(stage)")
            files["shaders/effects/blend.\(stage)"] = try Data(contentsOf: stock)
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }, .directory(wpeAssets)])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 16], "clearcolor": "0 0 0",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 64, height: 16), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch),
                              scriptHost: .init(userPropertiesJSON: userPropertiesJSON))
        return DriverHarness(driver: driver, json: json)
    }

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

    private func encode(_ renderer: WPEParityFrameRenderer, elapsed: Double = 1.0 / 60) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: elapsed) else {
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
    private func makeFixtureRenderer(aliasing: Bool = false,
                                     edit: (inout [String: Any]) -> Void = { _ in }) async throws -> Fixture {
        let (root, wpeAssets) = try paths()
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: sceneJSON(root, edit: edit)), userValues: [:]
        )
        var settings = Self.settings
        settings.renderTargetAliasing = aliasing
        let plan = try WPEParityFramePlan(document: document, assets: assets(root, wpeAssets),
                                          settings: settings, width: Self.width, height: Self.height)
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
                              pixelFormat: .rgba8Unorm_srgb, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        return DriverHarness(driver: driver, json: json)
    }
}
#endif
