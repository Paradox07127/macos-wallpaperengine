#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Per-frame object state in parity scenes: keyframe animations and store writes reach the draws.
final class WPEParitySceneStateTests: XCTestCase {
    private static let width = 1920
    private static let height = 1080
    private static let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true)

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-state-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testAlphaAnimationDrivesTheLayerDrawsGAlpha() async throws {
        let property: [String: Any] = ["value": 1, "animation": [
            "c0": [["frame": 0, "value": 1], ["frame": 30, "value": 0]],
            "options": ["fps": 30, "length": 30, "mode": "loop"],
        ]]
        let fixture = try await makeFixtureRenderer("3815666789") { Self.edit(&$0, object: 17) { $0["alpha"] = property } }
        let operation = try XCTUnwrap(Self.operation(fixture.plan, object: "17") { $0.fillsComposite })
        let reference = try XCTUnwrap(WPEParityPropertyAnimation(property: XCTUnwrap(WPESceneJSONValue(jsonValue: property)),
                                                                 valueType: .float))
        var alphas: [Float] = []
        for frame in 1 ... 10 {
            try await encode(fixture.renderer)
            reference.advance(dt: fixture.renderer.clock.frametime)
            let expected = try XCTUnwrap(reference.value).x
            let draw = try XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
            let alpha = try XCTUnwrap(Self.float(draw.constants[.fragment]?["g_Alpha"]), "frame \(frame)")
            XCTAssertEqual(alpha, expected, accuracy: 1e-6, "frame \(frame)")
            XCTAssertEqual(Self.vector(draw.constants[.fragment]?["g_Color4"])?.last ?? -1, expected, accuracy: 1e-6)
            alphas.append(alpha)
        }
        print("alpha animation: g_Alpha over 10 frames \(alphas)")
        XCTAssertLessThan(alphas[9], alphas[0])
    }

    func testOriginAnimationMovesTheLayerMVPAndTwoChannelScaleDoesNot() async throws {
        let origin: [String: Any] = ["value": "1920 1080 0", "animation": [
            "c0": [["frame": 0, "value": 1920], ["frame": 30, "value": 2400]],
            "c1": [["frame": 0, "value": 1080]], "c2": [["frame": 0, "value": 0]],
            "options": ["fps": 30, "length": 30, "mode": "loop"],
        ]]
        let scale: [String: Any] = ["value": "1 1 1", "animation": [
            "c0": [["frame": 0, "value": 1], ["frame": 30, "value": 3]],
            "c1": [["frame": 0, "value": 1], ["frame": 30, "value": 3]],
            "options": ["fps": 30, "length": 30, "mode": "loop"],
        ]]
        func mvpMove(_ properties: [String: Any]) async throws -> (Float, WPEParitySceneState.Object?) {
            let fixture = try await makeFixtureRenderer("3815666789") { json in
                Self.edit(&json, object: 17) { $0.merge(properties) { $1 } }
                var general = json["general"] as? [String: Any] ?? [:]
                (general["cameraparallax"], general["camerashake"]) = (false, false)
                json["general"] = general
            }
            let operation = try XCTUnwrap(Self.operation(fixture.plan, object: "17") { $0.geometry == .layerMesh })
            try await encode(fixture.renderer)
            let before = try XCTUnwrap(fixture.renderer.uniforms(operation)).matrices.modelViewProjection
            for _ in 1 ... 9 {
                try await encode(fixture.renderer)
            }
            let after = try XCTUnwrap(fixture.renderer.uniforms(operation)).matrices.modelViewProjection
            return (simd_length(after.columns.3 - before.columns.3), fixture.renderer.state.object("17"))
        }
        let (moved, animated) = try await mvpMove(["origin": origin])
        let (still, scaled) = try await mvpMove(["scale": scale])
        print("origin animation: MVP translation change over 9 frames \(moved); two-channel scale \(still)")
        XCTAssertGreaterThan(moved, 1e-4)
        XCTAssertGreaterThan(animated?.origin.x ?? 0, 1920)
        XCTAssertEqual(still, 0, accuracy: 1e-7)
        XCTAssertEqual(scaled?.scale, SIMD3(1, 1, 1))
    }

    func testMaterialConstantAnimationRepacksOnlyWhenTheValueChanges() async throws {
        let speed: [String: Any] = ["value": 5, "animation": [
            "c0": [["frame": 0, "value": 5], ["frame": 10, "value": 15]],
            "options": ["fps": 30, "length": 20, "mode": "single"],
        ]]
        let fixture = try await makeFixtureRenderer("3815666789") { json in
            Self.edit(&json, object: 17) { object in
                var effects = object["effects"] as? [[String: Any]] ?? []
                var passes = effects[1]["passes"] as? [[String: Any]] ?? []
                var constants = passes[0]["constantshadervalues"] as? [String: Any] ?? [:]
                constants["speeduv"] = speed
                passes[0]["constantshadervalues"] = constants
                effects[1]["passes"] = passes
                object["effects"] = effects
            }
        }
        let operation = try XCTUnwrap(fixture.plan.programs.first { $0.value.shader == "effects/foliagesway" }?.key)
        let reference = try XCTUnwrap(WPEParityPropertyAnimation(property: XCTUnwrap(WPESceneJSONValue(jsonValue: speed)),
                                                                 valueType: .float))
        var previous: Float = 5
        var (changed, held) = (0, 0)
        for frame in 1 ... 40 {
            let packs = fixture.renderer.constantPacks
            try await encode(fixture.renderer)
            reference.advance(dt: fixture.renderer.clock.frametime)
            let expected = try XCTUnwrap(reference.value).x
            let draw = try XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
            XCTAssertEqual(try XCTUnwrap(Self.float(draw.constants[.fragment]?["g_Speed"])), expected, accuracy: 1e-6,
                           "frame \(frame)")
            XCTAssertEqual(Self.float(draw.constants[.vertex]?["g_Speed"]), 1, "frame \(frame): vertex reads speed")
            if expected != previous {
                XCTAssertGreaterThan(fixture.renderer.constantPacks, packs, "frame \(frame)")
                changed += 1
            } else {
                XCTAssertEqual(fixture.renderer.constantPacks, packs, "frame \(frame)")
                held += 1
            }
            previous = expected
        }
        print("constant animation: \(changed) frames re-packed, \(held) frames held, \(fixture.renderer.constantPacks) packs")
        XCTAssertGreaterThan(changed, 0)
        XCTAssertGreaterThan(held, 0)
    }

    func testHiddenLayerStopsEncodingAndComesBack() async throws {
        let fixture = try await makeFixtureRenderer("3815666789")
        func drawsOf17() -> Int {
            fixture.renderer.lastFrameDraws.count { Self.object(fixture.plan, $0.operation) == "17" }
        }
        try await encode(fixture.renderer)
        let shown = drawsOf17()
        XCTAssertGreaterThan(shown, 0)
        XCTAssertTrue(fixture.renderer.state.set(.visible, of: "17", to: .zero))
        try await encode(fixture.renderer)
        XCTAssertEqual(drawsOf17(), 0)
        fixture.renderer.state.set(.visible, of: "17", to: .one)
        try await encode(fixture.renderer)
        XCTAssertEqual(drawsOf17(), shown)
    }

    func testChildOfHiddenGroupIsNotDrawn() async throws {
        let fixture = try await makeFixtureRenderer("3815666789") { json in
            var objects = json["objects"] as? [[String: Any]] ?? []
            objects.insert(["id": 900, "name": "group", "origin": "0 0 0", "scale": "1 1 1", "angles": "0 0 0"], at: 0)
            json["objects"] = objects
            Self.edit(&json, object: 17) { $0["parent"] = 900 }
        }
        try await encode(fixture.renderer)
        XCTAssertTrue(fixture.renderer.lastFrameDraws.contains { Self.object(fixture.plan, $0.operation) == "17" })
        XCTAssertTrue(fixture.renderer.state.set(.visible, of: "900", to: .zero))
        XCTAssertFalse(fixture.renderer.state.isVisible("17"))
        try await encode(fixture.renderer)
        XCTAssertFalse(fixture.renderer.lastFrameDraws.contains { Self.object(fixture.plan, $0.operation) == "17" })
    }

    func testHiddenParticleObjectRestartsWithoutParticles() async throws {
        let fixture = try await makeFixtureRenderer("3660962877") { json in
            var general = json["general"] as? [String: Any] ?? [:]
            general["camerashake"] = false
            json["general"] = general
        }
        for _ in 1 ... 10 {
            try await encode(fixture.renderer)
        }
        XCTAssertGreaterThan(fixture.renderer.particleLiveCount("560") ?? 0, 0)
        fixture.renderer.state.set(.visible, of: "560", to: .zero)
        for _ in 1 ... 3 {
            try await encode(fixture.renderer)
            XCTAssertFalse(fixture.renderer.lastFrameDraws.contains { Self.object(fixture.plan, $0.operation) == "560" })
        }
        XCTAssertEqual(fixture.renderer.particleLiveCount("560"), 0)
        fixture.renderer.state.set(.visible, of: "560", to: .one)
        XCTAssertEqual(fixture.renderer.particleLiveCount("560"), 0)
        for _ in 1 ... 10 {
            try await encode(fixture.renderer)
        }
        XCTAssertGreaterThan(fixture.renderer.particleLiveCount("560") ?? 0, 0)
    }

    /// Prints a hash of frame 0's backbuffer for scenes without animations, to compare across builds.
    func testFrameZeroBackbufferHash() async throws {
        let fixture = try await makeFixtureRenderer("3815666789")
        try await encode(fixture.renderer)
        try print("scene 3815666789: frame 0 backbuffer hash "
            + "\(Self.hash(readBack(fixture.renderer.backbuffer, device: fixture.device, queue: fixture.queue)))")
        let workshop = try await makeWorkshopRenderer("3448877775")
        try await encode(workshop.renderer)
        try print("scene 3448877775: frame 0 backbuffer hash "
            + "\(Self.hash(readBack(workshop.renderer.backbuffer, device: workshop.device, queue: workshop.queue)))")
    }

    /// A wallpaper read that throws is a miss, so the engine root's file of the same path answers it.
    func testThrowingWallpaperReadFallsBackToTheEngineAssets() throws {
        let engineRoot = scratch.appending(path: "engine", directoryHint: .isDirectory)
        let file = engineRoot.appending(path: "assets/materials/fallback.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(#"{"passes":[]}"#.utf8)
        try bytes.write(to: file)
        let assets = WPEParitySceneAssets.make(provider: ThrowingSceneAssetProvider(),
                                               projectRoot: scratch.appending(path: "project", directoryHint: .isDirectory),
                                               dependencyMounts: [], engineAssetsRootURL: engineRoot)
        XCTAssertEqual(assets.data("materials/fallback.json"), bytes)
    }

    // MARK: Helpers

    private struct Fixture {
        let plan: WPEParityFramePlan
        let renderer: WPEParityFrameRenderer
        let device: MTLDevice
        let queue: MTLCommandQueue
    }

    private func encode(_ renderer: WPEParityFrameRenderer, elapsed: Double = 1.0 / 60) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: elapsed) else {
            return XCTFail("frame was skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error)
    }

    private static func edit(_ json: inout [String: Any], object id: Int, _ body: (inout [String: Any]) -> Void) {
        var objects = json["objects"] as? [[String: Any]] ?? []
        for index in objects.indices where objects[index]["id"] as? Int == id {
            body(&objects[index])
        }
        json["objects"] = objects
    }

    private static func object(_ plan: WPEParityFramePlan, _ operation: Int) -> String? {
        if case let .scene(draw)? = plan.frames[0].draws[operation] {
            draw.objectID
        } else {
            nil
        }
    }

    private static func operation(_ plan: WPEParityFramePlan, object id: String,
                                  where predicate: (WPEParitySceneDraw) -> Bool) -> Int? {
        plan.frames[0].draws.sorted { $0.key < $1.key }.first { _, draw in
            if case let .scene(scene) = draw {
                scene.objectID == id && predicate(scene)
            } else {
                false
            }
        }?.key
    }

    private static func float(_ value: WPECBufferValue?) -> Float? {
        if case let .float(number)? = value {
            number
        } else {
            nil
        }
    }

    private static func vector(_ value: WPECBufferValue?) -> [Float]? {
        if case let .vector(components)? = value {
            components
        } else {
            nil
        }
    }

    /// A capture scene with its scene JSON edited by `edit`.
    private func makeFixtureRenderer(_ sceneID: String,
                                     edit: (inout [String: Any]) -> Void = { _ in }) async throws -> Fixture {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let sceneDirectory = root.appending(path: "scene-sources/\(sceneID)")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sceneDirectory.appending(path: "scene.json"))
        ) as? [String: Any])
        edit(&json)
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoTransformScripts() }
        )
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: Self.settings,
                                          width: Self.width, height: Self.height)
        let geometryCompiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms,
                                                     geometryCompiler: geometryCompiler,
                                                     uncapturedUtilityPrograms: WPEParityFixtureShaderCompiler.utilityPrograms(in: plan)),
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
        return Fixture(plan: plan, renderer: renderer, device: device, queue: queue)
    }

    /// An installed Workshop scene compiled by wpe-shaderc.
    private func makeWorkshopRenderer(_ sceneID: String) async throws -> Fixture {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let folder = steam.appending(path: "workshop/content/431960/\(sceneID)", directoryHint: .isDirectory)
        let package = folder.appending(path: "scene.pkg")
        let engineRoot = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop \(sceneID) and WPE's assets (or WPE_ASSETS_DIR)")
        }
        let assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engineRoot)
        let document = try WPESceneDocumentParser.parse(
            data: XCTUnwrap(assets.data("scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoTransformScripts() }
        )
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                          width: Self.width, height: Self.height)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let cache = FileManager.default.temporaryDirectory.appending(path: "parity-particles-\(sceneID)-cache",
                                                                     directoryHint: .isDirectory)
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                bindingABIVersion: 1),
            particleSeed: 1
        )
        return Fixture(plan: plan, renderer: renderer, device: device, queue: queue)
    }

    private func readBack(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        let bytesPerRow = texture.width * (texture.pixelFormat == .rgba16Float ? 8 : 4)
        let length = bytesPerRow * texture.height
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
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

    /// FNV-1a 64.
    private static func hash(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}

private struct NoTransformScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}

private struct ThrowingSceneAssetProvider: WPESceneAssetProvider {
    var entryNames: [String] {
        []
    }

    func data(atRelativePath _: String) throws -> Data {
        throw CocoaError(.fileReadUnknown)
    }

    func stagedURL(atRelativePath _: String) throws -> URL {
        throw CocoaError(.fileReadUnknown)
    }

    func exists(atRelativePath _: String) -> Bool {
        false
    }
}
#endif
