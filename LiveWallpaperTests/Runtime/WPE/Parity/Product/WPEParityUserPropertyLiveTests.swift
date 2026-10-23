#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

/// User-property changes reach a running parity scene through the render actor's prepare/commit without a reload,
/// on the capture fixture 3815666789 with its object 17 bound to user properties.
final class WPEParityUserPropertyLiveTests: XCTestCase {
    private static let size = CGSize(width: 1920, height: 1080)
    private static let sceneID = "3815666789"

    private var scratch: URL!
    private var actors: [WPEDisplayRenderActor] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-user-live-\(UUID().uuidString)",
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

    func testAlphaChangesTheLayerGAlphaWithoutReloading() async throws {
        let harness = try await makeHarness()
        let operation = try XCTUnwrap(harness.operation { $0.fillsComposite })
        let before = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(before.alpha[operation]), 1, accuracy: 1e-6)
        let generation = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration

        let committed = try await change(harness, "opacity", from: .number(1), to: .number(0.25))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(after.alpha[operation]), 0.25, accuracy: 1e-6)
        XCTAssertEqual(after.renderer, before.renderer, "the renderer is not rebuilt")
        let generationAfter = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration
        XCTAssertEqual(generationAfter, generation, "the scene did not reload")
    }

    func testMaterialConstantChangesTheCBufferAndRepacksOnePass() async throws {
        let harness = try await makeHarness()
        let operation = try XCTUnwrap(harness.plan.programs.first { $0.value.shader == "effects/foliagesway" }?.key)
        let before = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(before.speed[operation]), 5, accuracy: 1e-6)

        let committed = try await change(harness, "speed", from: .number(5), to: .number(9))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(after.speed[operation]), 9, accuracy: 1e-6)
        XCTAssertEqual(after.constantPacks, before.constantPacks + 1)
        let held = try await frame(harness.actor)
        XCTAssertEqual(held.constantPacks, after.constantPacks, "an unchanged pass is not re-packed")
    }

    func testScriptedMaterialConstantChangesTheCBufferWithoutReloading() async throws {
        let harness = try await makeHarness(speedScript: "export function update(v){ return v; }")
        let operation = try XCTUnwrap(harness.plan.programs.first { $0.value.shader == "effects/foliagesway" }?.key)
        let before = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(before.speed[operation]), 5, accuracy: 1e-6)
        let generation = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration

        let committed = try await change(harness, "speed", from: .number(5), to: .number(9))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(after.speed[operation]), 9, accuracy: 1e-6)
        XCTAssertEqual(after.renderer, before.renderer, "the renderer is not rebuilt")
        let generationAfter = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration
        XCTAssertEqual(generationAfter, generation, "the scene did not reload")
    }

    func testMaterialFileConstantFollowsAKeyTheSceneAlsoBinds() async throws {
        let harness = try await makeHarness(alphaKey: "drift", materialSpeedKey: "drift")
        let composite = try XCTUnwrap(harness.operation { $0.fillsComposite })
        let sway = try XCTUnwrap(harness.plan.programs.first { $0.value.shader == "effects/foliagesway" }?.key)
        let before = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(before.speed[sway]), 5, accuracy: 1e-6)
        let generation = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration

        let committed = try await change(harness, "drift", from: .number(1), to: .number(0.5))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(after.alpha[composite]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(after.speed[sway]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(after.renderer, before.renderer, "the renderer is not rebuilt")
        let generationAfter = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration
        XCTAssertEqual(generationAfter, generation, "the scene did not reload")
    }

    func testMaterialFileOnlyKeyChangesTheCBufferWithoutReloading() async throws {
        let harness = try await makeHarness(materialSpeedKey: "sway")
        let operation = try XCTUnwrap(harness.plan.programs.first { $0.value.shader == "effects/foliagesway" }?.key)
        let before = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(before.speed[operation]), 5, accuracy: 1e-6)

        let committed = try await change(harness, "sway", from: .number(5), to: .number(9))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(after.speed[operation]), 9, accuracy: 1e-6)
        XCTAssertEqual(after.renderer, before.renderer, "the renderer is not rebuilt")
        XCTAssertEqual(after.constantPacks, before.constantPacks + 1)
    }

    func testReloadAfterACommitResolvesMaterialFileConstantsWithTheCommittedValue() async throws {
        let harness = try await makeHarness(alphaKey: "drift", materialSpeedKey: "drift")
        let composite = try XCTUnwrap(harness.operation { $0.fillsComposite })
        let sway = try XCTUnwrap(harness.plan.programs.first { $0.value.shader == "effects/foliagesway" }?.key)
        let snapshot = await harness.actor.rendererStateSnapshot()
        let loaded = try XCTUnwrap(snapshot?.descriptor)
        let committed = try await change(harness, "drift", from: .number(1), to: .number(0.5),
                                         descriptor: loaded.withPropertyOverrides(["drift": .number(0.5)]))
        XCTAssertTrue(committed)

        try await harness.actor.reload()
        let reloaded = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(reloaded.alpha[composite]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(reloaded.speed[sway]), 0.5, accuracy: 1e-6)
    }

    func testHidingTheLayerDropsItsOperationsTheNextFrame() async throws {
        let harness = try await makeHarness()
        let operations = harness.operations(of: "17")
        let before = try await frame(harness.actor)
        XCTAssertFalse(before.operations.isDisjoint(with: operations))

        let committed = try await change(harness, "show", from: .bool(true), to: .bool(false))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertTrue(after.operations.isDisjoint(with: operations), "\(after.operations)")
        XCTAssertEqual(after.renderer, before.renderer)
    }

    func testTextureBoundPropertyFallsBackToReload() async throws {
        let harness = try await makeHarness()
        let bindings = await harness.actor.scenePropertyBindings()
        XCTAssertFalse(bindings["mask", default: []].isEmpty)
        let patch = WPEScenePropertyPatch(bindingsByProperty: bindings, oldValues: ["mask": .string("util/white")],
                                          newValues: ["mask": .string("util/black")])
        let authority = ScenePropertyMutationAuthority()
        let prepared = await harness.actor.prepareScenePropertyPatch(patch, authority: authority,
                                                                     expectedIntent: authority.currentToken())
        XCTAssertNil(prepared)
    }

    func testLiveAlphaMatchesASceneBuiltWithTheNewValue() async throws {
        let harness = try await makeHarness()
        for _ in 1 ... 3 {
            _ = try await frame(harness.actor)
        }
        let committed = try await change(harness, "opacity", from: .number(1), to: .number(0.25))
        XCTAssertTrue(committed)
        for _ in 1 ... 3 {
            _ = try await frame(harness.actor)
        }
        let live = try await harness.actor.run { actor in
            try Self.readBack(XCTUnwrap(actor.parityDriverForTesting))
        }

        let fixture = try fixture()
        let document = try WPESceneDocumentParser.parse(data: harness.sceneJSON, userValues: ["opacity": .number(0.25)])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        try await driver.load(document: document, assets: harness.assets, settings: WPEParityProgramSettings(),
                              drawableSize: Self.size, pixelFormat: .rgba8Unorm_srgb, compiler: fixture.compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        for _ in 1 ... 6 {
            try Self.encode(renderer)
        }
        let rebuilt = try Self.readBack(driver)
        XCTAssertEqual(live.count, rebuilt.count)
        XCTAssertTrue(live == rebuilt, "live alpha change differs from a scene loaded with the new value")
    }

    func testSoundVolumeChangesTheTrackGainWithoutReloading() async throws {
        let sound: [String: Any] = [
            "id": 902, "name": "music", "sound": ["sounds/Melodysheep - Ether.flac"], "playbackmode": "loop",
            "volume": ["user": "musicvolume", "value": 1],
        ]
        let harness = try await makeHarness(withSound: sound)
        let before = try await frame(harness.actor)
        let generation = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration

        let committed = try await change(harness, "musicvolume", from: .number(1), to: .number(0.5))
        XCTAssertTrue(committed)
        let volume = await harness.actor.run { actor in
            actor.parityDriverForTesting?.soundRuntime?.debugTrackSnapshots().first { $0.id == "902" }?.sceneVolume
        }
        XCTAssertEqual(volume, 0.5)
        let after = try await frame(harness.actor)
        XCTAssertEqual(after.renderer, before.renderer, "the renderer is not rebuilt")
        let generationAfter = await harness.actor.rendererStateSnapshot()?.currentLoadGeneration
        XCTAssertEqual(generationAfter, generation, "the scene did not reload")
    }

    func testUnboundPropertyReachesTheScriptApplyUserProperties() async throws {
        let harness = try await makeHarness(edit: {
            $0["visible"] = ["value": true, "script": """
            export function applyUserProperties(p){ if (p.hasOwnProperty('fade')) thisLayer.alpha = p.fade; }
            """]
        }, properties: ["fade": ["type": "slider", "value": 1, "min": 0, "max": 1]])
        let operation = try XCTUnwrap(harness.operation { $0.fillsComposite })
        let before = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(before.alpha[operation]), 1, accuracy: 1e-6)

        let committed = try await change(harness, "fade", from: .number(1), to: .number(0.5))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(after.alpha[operation]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(after.renderer, before.renderer)
    }

    func testHidingAScriptedLayerDropsItsOperationsTheNextFrame() async throws {
        let harness = try await makeHarness(edit: {
            $0["visible"] = ["user": "show", "value": true, "script": "export function update(v){ return v; }"]
        })
        let operations = harness.operations(of: "17")
        let before = try await frame(harness.actor)
        XCTAssertFalse(before.operations.isDisjoint(with: operations))

        let committed = try await change(harness, "show", from: .bool(true), to: .bool(false))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertTrue(after.operations.isDisjoint(with: operations), "\(after.operations)")
        XCTAssertEqual(after.renderer, before.renderer)
    }

    func testScriptPropertyChangeReachesTheRunningScript() async throws {
        let harness = try await makeHarness(edit: {
            $0["visible"] = [
                "value": true,
                "script": """
                export var scriptProperties = createScriptProperties().addSlider({name:'level',value:1}).finish();
                export function update(v){ thisLayer.alpha = scriptProperties.level; return v; }
                """,
                "scriptproperties": ["level": ["user": "level", "value": 1]],
            ]
        })
        let operation = try XCTUnwrap(harness.operation { $0.fillsComposite })
        let before = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(before.alpha[operation]), 1, accuracy: 1e-6)

        let committed = try await change(harness, "level", from: .number(1), to: .number(0.25))
        XCTAssertTrue(committed)
        let after = try await frame(harness.actor)
        XCTAssertEqual(try XCTUnwrap(after.alpha[operation]), 0.25, accuracy: 1e-6)
        XCTAssertEqual(after.renderer, before.renderer)
    }

    // MARK: Helpers

    private struct Harness {
        let actor: WPEDisplayRenderActor
        let plan: WPEParityFramePlan
        let assets: WPEParityProgramAssets
        let sceneJSON: Data

        func operations(of object: String) -> Set<Int> {
            Set(plan.frames[0].draws.compactMap { index, draw in
                if case let .scene(scene) = draw, scene.objectID == object {
                    index
                } else {
                    nil
                }
            })
        }

        func operation(where predicate: (WPEParitySceneDraw) -> Bool) -> Int? {
            plan.frames[0].draws.sorted { $0.key < $1.key }.first { _, draw in
                if case let .scene(scene) = draw {
                    scene.objectID == "17" && predicate(scene)
                } else {
                    false
                }
            }?.key
        }
    }

    private struct Fixture {
        let root: URL
        let wpeAssets: URL
        let compiler: WPEParityHelperShaderCompiler
    }

    private struct FrameReading: Sendable {
        let renderer: ObjectIdentifier
        let operations: Set<Int>
        let alpha: [Int: Float]
        let speed: [Int: Float]
        let constantPacks: Int
    }

    /// Prepares and commits one property change on the actor as `ScreenManager` does; `descriptor` nil commits the
    /// loaded descriptor.
    private func change(_ harness: Harness, _ key: String, from old: WallpaperEngineProjectPropertyValue,
                        to new: WallpaperEngineProjectPropertyValue,
                        descriptor: SceneDescriptor? = nil) async throws -> Bool {
        let bindings = await harness.actor.scenePropertyBindings()
        let patch = WPEScenePropertyPatch(bindingsByProperty: bindings, oldValues: [key: old], newValues: [key: new])
        let authority = ScenePropertyMutationAuthority()
        let prepared = await harness.actor.prepareScenePropertyPatch(patch, authority: authority,
                                                                     expectedIntent: authority.currentToken())
        let snapshot = await harness.actor.rendererStateSnapshot()
        let loaded = try XCTUnwrap(snapshot?.descriptor)
        guard let prepared else { return false }
        return await harness.actor.commitScenePropertyPatch(prepared, updatedDescriptor: descriptor ?? loaded)
    }

    /// Encodes one frame of the actor's parity renderer at a fixed step and reads what its draws set.
    private func frame(_ actor: WPEDisplayRenderActor) async throws -> FrameReading {
        try await actor.run { actor in
            let renderer = try XCTUnwrap(actor.parityDriverForTesting?.renderer)
            try Self.encode(renderer)
            var alpha: [Int: Float] = [:]
            var speed: [Int: Float] = [:]
            for (operation, draw) in renderer.lastFrameDraws {
                alpha[operation] = Self.float(draw.constants[.fragment]?["g_Alpha"])
                speed[operation] = Self.float(draw.constants[.fragment]?["g_Speed"])
            }
            return FrameReading(renderer: ObjectIdentifier(renderer),
                                operations: Set(renderer.lastFrameDraws.map(\.operation)), alpha: alpha,
                                speed: speed, constantPacks: renderer.constantPacks)
        }
    }

    private static func encode(_ renderer: WPEParityFrameRenderer) throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("frame was skipped")
        }
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }

    private static func float(_ value: WPECBufferValue?) -> Float? {
        if case let .float(number)? = value {
            number
        } else {
            nil
        }
    }

    private static func readBack(_ driver: WPEParitySceneDriver) throws -> [UInt8] {
        let texture = try XCTUnwrap(driver.renderer?.backbuffer)
        let queue = driver.executor.textureSourceCommandQueue
        let bytesPerRow = texture.width * (texture.pixelFormat == .rgba16Float ? 8 : 4)
        let length = bytesPerRow * texture.height
        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: length, options: .storageModeShared))
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

    private func fixture() throws -> Fixture {
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
        return Fixture(root: root, wpeAssets: wpeAssets, compiler: compiler)
    }

    /// Object 17's alpha, visibility, foliagesway speed and a waterripple texture bound to user properties `opacity`,
    /// `show`, `speed` and `mask`; the scene is installed as a `.cache` scene and loaded by a fresh actor.
    /// With `materialSpeedKey`, the scene leaves `speeduv` to `materials/effects/foliagesway.json`, which binds it to
    /// that key with value 5; otherwise `speedScript` is attached to the scene's `speed` envelope.
    /// `edit` runs on object 17 after these; `properties` go to project.json; `sound` is muted.
    private func makeHarness(alphaKey: String = "opacity", materialSpeedKey: String? = nil, speedScript: String? = nil,
                             edit: ((inout [String: Any]) -> Void)? = nil, properties: [String: Any]? = nil,
                             withSound sound: [String: Any]? = nil) async throws -> Harness {
        let fixture = try fixture()
        let relativePath = "wpe-cache/\(Self.sceneID)"
        let sceneDirectory = scratch.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sceneDirectory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.root.appending(path: "scene-sources/\(Self.sceneID)"),
                                         to: sceneDirectory)
        if let properties {
            try JSONSerialization.data(withJSONObject: ["general": ["properties": properties]])
                .write(to: sceneDirectory.appending(path: "project.json"))
        }
        if sound != nil {
            try FileManager.default.createDirectory(at: sceneDirectory.appending(path: "sounds"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: fixture.root.appending(path: "scene-sources/3509243656/sounds/Melodysheep - Ether.flac"),
                to: sceneDirectory.appending(path: "sounds/Melodysheep - Ether.flac")
            )
        }
        let sceneURL = sceneDirectory.appending(path: "scene.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
        objects[0]["alpha"] = ["user": alphaKey, "value": 1]
        objects[0]["visible"] = ["user": "show", "value": true]
        edit?(&objects[0])
        if let sound {
            objects.append(sound)
        }
        var effects = try XCTUnwrap(objects[0]["effects"] as? [[String: Any]])
        var ripple = try XCTUnwrap(effects[0]["passes"] as? [[String: Any]])
        ripple[0]["textures"] = [NSNull(), ["user": "mask", "value": "util/white"]]
        effects[0]["passes"] = ripple
        var sway = try XCTUnwrap(effects[1]["passes"] as? [[String: Any]])
        var constants = sway[0]["constantshadervalues"] as? [String: Any] ?? [:]
        if let materialSpeedKey {
            constants["speeduv"] = nil
            let materialURL = sceneDirectory.appending(path: "materials/effects/foliagesway.json")
            var material = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: materialURL))
                as? [String: Any])
            var passes = try XCTUnwrap(material["passes"] as? [[String: Any]])
            passes[0]["constantshadervalues"] = ["speeduv": ["user": materialSpeedKey, "value": 5]]
            material["passes"] = passes
            try JSONSerialization.data(withJSONObject: material).write(to: materialURL)
        } else {
            var speed: [String: Any] = ["user": "speed", "value": 5]
            speed["script"] = speedScript
            constants["speeduv"] = speed
        }
        sway[0]["constantshadervalues"] = constants
        effects[1]["passes"] = sway
        objects[0]["effects"] = effects
        json["objects"] = objects
        let sceneJSON = try JSONSerialization.data(withJSONObject: json)
        try sceneJSON.write(to: sceneURL)

        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [fixture.root.appending(path: "wpeassets"), fixture.wpeAssets])
        let document = try WPESceneDocumentParser.parse(data: sceneJSON, userValues: [:])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                          width: Int(Self.size.width), height: Int(Self.size.height))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = Self.size
        let inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: Self.sceneID, cacheRelativePath: relativePath,
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: sceneDirectory),
            projectRoot: sceneDirectory,
            assets: assets,
            settings: WPEParityProgramSettings(),
            compiler: fixture.compiler,
            device: device,
            presentLayer: WPEPresentLayer(layer: layer),
            mailbox: WPEPointerMailbox(),
            surfaceControl: SilentSurfaceControl(),
            drawableSize: Self.size,
            pixelFormat: layer.pixelFormat,
            soundResolver: sound == nil ? nil
                : WPEMultiRootResourceResolver(primaryRootURL: sceneDirectory, dependencyMounts: [])
        )
        let actor = WPEDisplayRenderActor()
        actors.append(actor)
        try await actor.adoptParity(inputs)
        if sound != nil {
            await actor.setAudioMuted(true)
        }
        try await actor.load()
        return Harness(actor: actor, plan: plan, assets: assets, sceneJSON: sceneJSON)
    }
}

private final class SilentSurfaceControl: WPESurfaceControl {
    func applyPacing(_: WPERenderPacingUpdate) {}

    func releaseDrawables() {}

    func detach() {}

    func setClickCaptureEnabled(_: Bool) {}
}
#endif
