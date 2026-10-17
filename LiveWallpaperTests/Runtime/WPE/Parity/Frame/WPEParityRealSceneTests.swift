#if !LITE_BUILD && DEBUG
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import simd
import XCTest

/// Renders the two capture scenes whose programs match WPE byte for byte, through the real shader store.
final class WPEParityRealSceneTests: XCTestCase {
    private static let width = 1920
    private static let height = 1080
    /// The capture machine's settings, so programs carry the combos the captured shaders were compiled with.
    private static let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true)

    func testScene3815666789RendersThreeFrames() async throws {
        try await render("3815666789")
    }

    func testScene3660962877RendersThreeFrames() async throws {
        // Its camerashake is bound to a user property; object 935's captured MVP has V = I, so the capture ran without it.
        try await render("3660962877") { $0["camerashake"] = false }
    }

    /// Object 560's rope (genericropeparticle) and 747's spritetrail draw live particles, and the frame moves.
    func testScene3660962877DrawsParticles() async throws {
        let (plan, renderer, device, queue) = try await makeRenderer("3660962877") { $0["camerashake"] = false }
        let particleDraws = plan.frames[0].draws.keys.filter { renderer.particleRenderer($0) != nil }
        XCTAssertEqual(particleDraws.compactMap { renderer.particleRenderer($0)?.kind }.sorted { "\($0)" < "\($1)" },
                       [.rope, .spriteTrail])
        try await renderFrame(renderer, label: "scene 3660962877 frame 1")
        let first = try readBack(renderer.backbuffer, device: device, queue: queue)
        var vertices: [Int: Int] = [:]
        for frame in 2 ... 30 {
            try await renderFrame(renderer, label: "scene 3660962877 frame \(frame)")
            for (operation, draw) in renderer.lastFrameDraws where renderer.particleRenderer(operation) != nil {
                vertices[operation] = max(vertices[operation] ?? 0, draw.vertexCount)
            }
        }
        print("scene 3660962877: most particle vertices per draw over 30 frames \(vertices.sorted { $0.key < $1.key })")
        for operation in particleDraws {
            XCTAssertGreaterThan(vertices[operation] ?? 0, 0, "operation \(operation)")
        }
        let last = try readBack(renderer.backbuffer, device: device, queue: queue)
        XCTAssertNotEqual(first, last, "the frame did not change over 30 frames")
    }

    /// Each cbuffer of every stage of every draw over three frames holds the bytes packing the draw's whole merged
    /// value set gives, though encoding evaluates only the declared names.
    func testDrawsPackTheBytesOfTheirWholeValueSet() async throws {
        let scenes: [(id: String, edit: (inout [String: Any]) -> Void)] = [
            ("3815666789", { _ in }), ("3660962877", { $0["camerashake"] = false }), ("3509243656", { _ in }),
        ]
        for scene in scenes {
            let (_, renderer, _, _) = try await makeRenderer(scene.id, editGeneral: scene.edit)
            var compared = 0
            for frame in 1 ... 3 {
                try await renderFrame(renderer, label: "scene \(scene.id) frame \(frame)")
                XCTAssertFalse(renderer.lastFrameDraws.isEmpty, "scene \(scene.id) frame \(frame)")
                for (operation, draw) in renderer.lastFrameDraws {
                    XCTAssertNotNil(draw.uniforms, "scene \(scene.id) operation \(operation)")
                    var stages = [(WPEHLSLStage.vertex, draw.pipeline.vertex), (.fragment, draw.pipeline.fragment)]
                    if let geometry = draw.pipeline.geometry {
                        stages.append((.geometry, geometry.geometry))
                    }
                    for (stage, reflected) in stages {
                        let values = draw.values(for: stage)
                        for (index, layout) in reflected.cbuffers.enumerated() where layout.size > 0 {
                            var oracle = WPECBufferPacker(layout: layout)
                            for variable in layout.reflection.variables {
                                if let value = values[variable.name] {
                                    try oracle.write(value, to: variable.name)
                                }
                            }
                            var packed = [UInt8](repeating: 0xA5, count: layout.size)
                            try packed.withUnsafeMutableBytes {
                                try WPEParityDrawEncoder.pack(cbuffer: index, of: reflected,
                                                              constants: draw.constants[stage],
                                                              uniforms: draw.uniforms, at: XCTUnwrap($0.baseAddress))
                            }
                            XCTAssertEqual(packed, oracle.bytes, "scene \(scene.id) frame \(frame) operation "
                                + "\(operation) \(stage) \(layout.reflection.name)")
                            compared += 1
                        }
                    }
                }
            }
            print("scene \(scene.id): \(compared) cbuffers compared over 3 frames")
            XCTAssertGreaterThan(compared, 0, "scene \(scene.id)")
        }
    }

    /// With camerashake on, the shake moves every layer's view, so object 935's MVP changes with scene time.
    /// Parallax is off so only the shake can move the view.
    func testCameraShakeMovesLayerMatrices() async throws {
        func mvpChange(shake: Bool) async throws -> Float {
            let (plan, renderer, _, _) = try await makeRenderer("3660962877") { general in
                general["camerashake"] = shake
                general["cameraparallax"] = false
            }
            let index = try XCTUnwrap(plan.frames[0].draws.first { _, draw in
                if case let .scene(scene) = draw {
                    scene.objectID == "935" && scene.geometry == .layerMesh
                } else {
                    false
                }
            }?.key)
            let before = try XCTUnwrap(renderer.uniforms(index)).matrices.modelViewProjection
            guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 0.5) else {
                throw XCTSkip("frame skipped")
            }
            await commandBuffer.completed()
            let after = try XCTUnwrap(renderer.uniforms(index)).matrices.modelViewProjection
            return simd_length(after.columns.3 - before.columns.3)
        }
        let shaken = try await mvpChange(shake: true)
        let still = try await mvpChange(shake: false)
        print("object 935 MVP translation change over 0.5 s: shake \(shaken), no shake \(still)")
        XCTAssertGreaterThan(shaken, 1e-4)
        XCTAssertEqual(still, 0, accuracy: 1e-7)
    }

    /// Workshop 3647999330, compiled by wpe-shaderc: object 545's puppet morphs its one target, driven by clip 749's
    /// additive layer (track 0, v[30] = 0.4798).
    func testScene3647999330PuppetMorphs() async throws {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let folder = steam.appending(path: "workshop/content/431960/3647999330", directoryHint: .isDirectory)
        let package = folder.appending(path: "scene.pkg")
        let engineRoot = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop 3647999330 and WPE's assets (or WPE_ASSETS_DIR)")
        }
        let assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engineRoot)
        let document = try WPESceneDocumentParser.parse(
            data: XCTUnwrap(assets.data("scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                          width: Self.width, height: Self.height)
        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: cache.appending(path: "shaderc"))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            shaders: WPEParityFrameShaderSource(
                store: WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache)),
                compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
            )
        )
        XCTAssertEqual(renderer.skipped, [:])
        for frame in 0 ... 60 {
            guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: frame == 0 ? 0 : 1.0 / 60) else {
                return XCTFail("scene 3647999330 frame \(frame) was skipped")
            }
            await commandBuffer.completed()
            XCTAssertNil(commandBuffer.error)
        }
        let draw = try XCTUnwrap(renderer.lastFrameDraws.first { operation, _ in
            guard case let .scene(scene)? = plan.frames[0].draws[operation] else { return false }
            return scene.objectID == "545" && scene.source?.combos["MORPHING"] == 1
        }?.draw, "object 545 has no encoded MORPHING draw")
        guard case let .array(groups)? = draw.constants[.vertex]?["g_MorphWeights"],
              case let .vector(weights)? = groups.first else {
            return XCTFail("object 545 uploads no g_MorphWeights")
        }
        XCTAssertEqual(weights[1], 0.4798, accuracy: 0.01)
        let morph = try XCTUnwrap(draw.textures["g_Texture5"])
        XCTAssertEqual([morph.width, morph.height], [2, 2])
        XCTAssertEqual(morph.pixelFormat, .rgba16Snorm)
    }

    /// Workshop 2955378002: an effect visibility script on objects[198] clones layer "playerbarsexception" (an image
    /// layer with two effects) seven times through `createLayer(getInitialLayerConfig(origbar))`.
    func testScene2955378002ScriptClonesTemplateImageLayerSevenTimes() async throws {
        let driver = try await loadWorkshopScene("2955378002")
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        try await presentFrames(driver, count: 3, label: "scene 2955378002")
        let engine = try XCTUnwrap(renderer.script?.engine)
        let created = engine.createdLayers.map(\.id)
        XCTAssertEqual(created.count, 7, "exceptions: \(engine.exceptions)")
        for id in created {
            let draws = sceneDraws(renderer, objectID: id)
            XCTAssertFalse(draws.isEmpty, "created layer \(id) has no planned draw")
            XCTAssertTrue(draws.contains { $0.draw.effectID != nil }, "created layer \(id) plans none of its effects")
            for (operation, _) in draws {
                XCTAssertNil(renderer.skipped[operation], "created layer \(id) operation \(operation)")
            }
        }
    }

    /// Workshop 3798688689: objects[506] creates two ModelData layers per emitter (14 kv1 + 13 kv2 emitters) and
    /// objects[510] four trail layers on the first trail advance; each is reparented onto composelayer 92001 or 92002.
    func testScene3798688689ModelDataLayersDrawInsideTheirComposeLayers() async throws {
        let driver = try await loadWorkshopScene("3798688689")
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        try await presentFrames(driver, count: 3, label: "scene 3798688689")
        let engine = try XCTUnwrap(renderer.script?.engine)
        let created = engine.createdLayers.map(\.id)
        XCTAssertEqual(created.count, 27 * 2 + 4, "exceptions: \(engine.exceptions)")
        let encodedOperations = Set(renderer.lastFrameDraws.map(\.operation))
        var encoded = 0
        for id in created {
            let parent = renderer.state.parentID(of: id)
            XCTAssertTrue(parent == "92001" || parent == "92002", "created layer \(id) has parent \(parent ?? "none")")
            let draws = sceneDraws(renderer, objectID: id)
            XCTAssertFalse(draws.isEmpty, "created layer \(id) has no planned draw")
            for (operation, draw) in draws {
                XCTAssertEqual(draw.compositeOwnerID, parent, "created layer \(id) draws outside its parent composite")
                XCTAssertNil(renderer.skipped[operation], "created layer \(id) operation \(operation)")
                encoded += encodedOperations.contains(operation) ? 1 : 0
            }
        }
        XCTAssertGreaterThan(encoded, 0, "no created layer was encoded in the last frame")
        // 1401ebf60.c:135-141: the unbound we2d_particle_buffer pass samples the pooled composite in slot 0 over the
        // authored `_b` name and writes the `_a` composite composelayer 92003 reads.
        for id in ["92001", "92002"] {
            let passes = sceneDraws(renderer, objectID: id).filter { $0.draw.effectID != nil }
            XCTAssertFalse(passes.isEmpty, "composelayer \(id) plans no effect pass")
            for (operation, draw) in passes {
                XCTAssertNil(renderer.skipped[operation], "composelayer \(id) effect pass \(operation)")
                XCTAssertTrue(draw.reads.first?.rawValue.hasPrefix("sc.") == true,
                              "composelayer \(id) effect pass reads \(draw.reads)")
                XCTAssertEqual(draw.target, WPEParitySceneResource.layerCompositeA(id))
            }
        }
    }

    /// Workshop 3509243656: objects[8]'s visible script creates a layer from `models/ta.json`, a model no loaded
    /// layer draws.
    func testScene3509243656ColdCreatedLayerDraws() async throws {
        try await assertCreatedLayersDraw("3509243656", model: "models/ta.json")
    }

    /// Workshop 3662499296: its scripts create 63 layers from the workshop's `models/bar.json`.
    func testScene3662499296ColdCreatedLayersDraw() async throws {
        try await assertCreatedLayersDraw("3662499296", model: "models/workshop/2652493753/bar.json")
    }

    private func assertCreatedLayersDraw(_ workshopID: String, model: String) async throws {
        let driver = try await loadWorkshopScene(workshopID)
        defer { driver.cleanup() }
        try await presentFrames(driver, count: 3, label: "scene \(workshopID)")
        let renderer = try XCTUnwrap(driver.renderer)
        let engine = try XCTUnwrap(renderer.script?.engine)
        let created = engine.createdLayers.map(\.id)
        XCTAssertFalse(created.isEmpty, "exceptions: \(engine.exceptions)")
        for id in created {
            XCTAssertEqual(renderer.state.object(id)?.createdImage?.model, model, "created layer \(id)")
            let draws = sceneDraws(renderer, objectID: id)
            XCTAssertFalse(draws.isEmpty, "created layer \(id) has no planned draw")
            for (operation, _) in draws {
                XCTAssertNil(renderer.skipped[operation], "created layer \(id) operation \(operation)")
            }
        }
    }

    /// Workshop 2468489223: skinned puppets 159, 247 and 417 have no normals in their MDLV, while genericimage4
    /// declares NORMAL0 without reading it.
    func testScene2468489223PuppetsWithoutNormalsDraw() async throws {
        try await assertPuppetsDraw("2468489223", objects: ["159", "247", "417"])
    }

    func testScene2664591394PuppetWithoutNormalsDraws() async throws {
        try await assertPuppetsDraw("2664591394", objects: ["18"])
    }

    func testScene2835012244PuppetWithoutNormalsDraws() async throws {
        try await assertPuppetsDraw("2835012244", objects: ["23"])
    }

    private func assertPuppetsDraw(_ workshopID: String, objects: [String]) async throws {
        let driver = try await loadWorkshopScene(workshopID)
        defer { driver.cleanup() }
        try await presentFrames(driver, count: 3, label: "scene \(workshopID)")
        let renderer = try XCTUnwrap(driver.renderer)
        let unbound = renderer.skipped.filter { "\($0.value)".contains("has 0 native elements") }
        XCTAssertEqual(unbound, [:], "scene \(workshopID)")
        let encoded = Set(renderer.lastFrameDraws.map(\.operation))
        for id in objects {
            let puppetDraws = sceneDraws(renderer, objectID: id).filter { $0.draw.geometry == .puppetMesh }
            XCTAssertFalse(puppetDraws.isEmpty, "scene \(workshopID) object \(id) plans no puppet draw")
            XCTAssertTrue(puppetDraws.contains { encoded.contains($0.operation) },
                          "scene \(workshopID) object \(id) encoded no puppet draw")
        }
    }

    /// Workshop 3330774573: event-spawned instances outgrow the initial particle share within 30 frames.
    func testScene3330774573GrowingEventInstancesDropNoParticleBatch() async throws {
        try await assertNoParticleBatchDropped("3330774573")
    }

    /// Workshop 3659880761: event-spawned instances outgrow the initial particle share within 30 frames.
    func testScene3659880761GrowingEventInstancesDropNoParticleBatch() async throws {
        try await assertNoParticleBatchDropped("3659880761")
    }

    private func assertNoParticleBatchDropped(_ workshopID: String) async throws {
        let driver = try await loadWorkshopScene(workshopID)
        defer { driver.cleanup() }
        try await presentFrames(driver, count: 120, label: "scene \(workshopID)")
        let renderer = try XCTUnwrap(driver.renderer)
        print("scene \(workshopID): \(renderer.droppedParticleBatches) particle batches dropped over 120 frames, "
            + "share \(renderer.particleShare) bytes")
        XCTAssertEqual(renderer.droppedParticleBatches, 0)
    }

    /// Workshop 3749463715: a press near objects[16]'s puppet picks its nearest bone with getBoneCount and
    /// getBoneTransform, and each update while held moves it toward the cursor with setBoneTransform.
    func testScene3749463715ScriptDragMovesPuppetBones() async throws {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let samples = home.appending(path: "Developer/wpe-fixtures/workshop-samples-2026-10-17/steamapps",
                                     directoryHint: .isDirectory)
        let driver = try await loadWorkshopScene("3749463715", library: samples)
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        let layer = CAMetalLayer()
        layer.device = renderer.backbuffer.device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: Self.width, height: Self.height)
        var timestamp = 100.0
        func bones(pointer: SIMD2<Double>, buttonDown: Bool) async throws -> [Float]? {
            timestamp += 1.0 / 60
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: timestamp, pointer: pointer,
                                                                     buttonDown: buttonDown))
            await command.completed()
            XCTAssertNil(command.error)
            return renderer.lastFrameDraws.lazy.compactMap { operation, draw -> [Float]? in
                guard case let .scene(scene)? = renderer.frames[0].draws[operation], scene.objectID == "562",
                      case let .array(matrices)? = draw.constants[.vertex]?["g_Bones"] else { return nil }
                return matrices.flatMap { value -> [Float] in
                    guard case let .matrix(matrix) = value else { return [] }
                    return matrix.columns.flatMap(\.self)
                }
            }.first
        }
        let first = try await bones(pointer: SIMD2(0.02, 0.02), buttonDown: false)
        let idle = try await bones(pointer: SIMD2(0.02, 0.02), buttonDown: false)
        let quad = try XCTUnwrap(renderer.cursorQuad("562", camera: renderer.pathCamera))
        let center = (quad.0 + quad.1 + quad.2 + quad.3) / 4 / renderer.logicalSize
        let press = SIMD2<Double>(Double(center.x), Double(center.y))
        let held = try await bones(pointer: press, buttonDown: true)
        let dragged = try await bones(pointer: press + SIMD2(30, 0) / SIMD2(Double(Self.width), Double(Self.height)),
                                      buttonDown: true)
        let engine = try XCTUnwrap(renderer.script?.engine)
        XCTAssertFalse(engine.exceptions.contains { $0.contains("TypeError") }, engine.exceptions.joined(separator: "\n"))
        XCTAssertNotNil(idle, "objects[16] uploads no g_Bones")
        XCTAssertEqual(first, idle, "bones moved without a script write")
        XCTAssertNotEqual(held, dragged, "the dragged bone did not reach g_Bones")
    }

    /// Loads a Workshop scene through the product driver, scripts included, from `library` (default: the Steam
    /// library's steamapps); WPE's own assets always come from the Steam library or WPE_ASSETS_DIR.
    private func loadWorkshopScene(_ workshopID: String, library: URL? = nil) async throws -> WPEParitySceneDriver {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let folder = (library ?? steam).appending(path: "workshop/content/431960/\(workshopID)", directoryHint: .isDirectory)
        let package = folder.appending(path: "scene.pkg")
        let engineRoot = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop \(workshopID) and WPE's assets (or WPE_ASSETS_DIR)")
        }
        let assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engineRoot)
        let document = try WPESceneDocumentParser.parse(data: XCTUnwrap(assets.data("scene.json")), userValues: [:])
        // Kept across runs: the shader cache is keyed by compiler identity.
        let cache = FileManager.default.temporaryDirectory.appending(path: "wpe-parity-workshop-\(workshopID)",
                                                                     directoryHint: .isDirectory)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: cache.appending(path: "shaderc"))
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let host = WPEParitySceneScript.Host(
            userPropertiesJSON: WPEParitySceneScript.userPropertiesJSON(projectRoot: folder, values: [:])
        )
        try await driver.load(document: document, assets: assets, settings: WPEParityProgramSettings(),
                              drawableSize: CGSize(width: Self.width, height: Self.height),
                              pixelFormat: .bgra8Unorm_srgb, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: cache.appending(path: "shaders")),
                              workshopID: workshopID, scriptHost: host, particleSeed: 1)
        XCTAssertNil(driver.loadDiagnostics)
        return driver
    }

    private func presentFrames(_ driver: WPEParitySceneDriver, count: Int, label: String) async throws {
        let layer = CAMetalLayer()
        layer.device = try XCTUnwrap(driver.renderer).backbuffer.device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: Self.width, height: Self.height)
        for frame in 1 ... count {
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100 + Double(frame) / 60,
                                                                     pointer: SIMD2(0.5, 0.5)),
                                        "\(label) frame \(frame) was not presented")
            await command.completed()
            XCTAssertNil(command.error, "\(label) frame \(frame)")
        }
    }

    private func sceneDraws(_ renderer: WPEParityFrameRenderer,
                            objectID: String) -> [(operation: Int, draw: WPEParitySceneDraw)] {
        renderer.frames[0].draws.compactMap { operation, draw in
            guard case let .scene(scene) = draw, scene.objectID == objectID else { return nil }
            return (operation, scene)
        }
    }

    /// Each offscreen scale tier allocates no more render-target bytes than the one below it.
    func testScene3509243656OffscreenScaleTiersShrinkRenderTargets() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "offscreen-tiers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes: [Int] = []
        for tier in 0 ... 3 {
            var settings = Self.settings
            settings.offscreenScaleTier = tier
            let (_, renderer, device, queue) = try await makeRenderer("3509243656", settings: settings)
            for frame in 1 ... 60 {
                try await renderFrame(renderer, label: "scene 3509243656 tier \(tier) frame \(frame)")
            }
            bytes.append(renderer.heapBytes + renderer.dedicatedTextureBytes)
            print("scene 3509243656 tier \(tier): heap \(renderer.heapBytes) bytes, dedicated textures "
                + "\(renderer.dedicatedTextureBytes) bytes")
            let backbuffer = renderer.backbuffer
            let url = directory.appending(path: "tier-\(tier).png")
            try writePNG(readBack(backbuffer, device: device, queue: queue), width: backbuffer.width,
                         height: backbuffer.height, to: url)
            print("scene 3509243656 tier \(tier): frame 60 written to \(url.path)")
        }
        for tier in 1 ... 3 {
            XCTAssertLessThanOrEqual(bytes[tier], bytes[tier - 1], "tier \(tier)")
        }
        XCTAssertLessThan(bytes[3], bytes[0])
    }

    /// Measures every TEX in the scene's directory without and with texture compression, cold and warm disk cache,
    /// then renders frame 60 with the preference on. Prints only; no pixel comparison.
    func testScene3509243656TextureCompressionMeasurement() async throws {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let sceneDirectory = root.appending(path: "scene-sources/3509243656")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let urls = (FileManager.default.enumerator(at: sceneDirectory, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "tex" }
        let textures = try urls.map { try Data(contentsOf: $0) }
        XCTAssertFalse(textures.isEmpty)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "texture-compression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        func load(_ compression: WPEParityTextureCompression?) -> (seconds: Double, bytes: Int, failures: Int) {
            var bytes = 0
            var failures = 0
            let start = ContinuousClock.now
            for data in textures {
                do {
                    // A fresh path per load keeps the process-wide share from returning an earlier upload.
                    let image = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: data), device: device,
                                                                path: "materials/measure-\(UUID().uuidString).tex",
                                                                compression: compression)
                    var seen = Set<ObjectIdentifier>()
                    for texture in [image.texture] + image.sprites.map(\.texture) where seen.insert(ObjectIdentifier(texture)).inserted {
                        bytes += texture.allocatedSize
                    }
                } catch {
                    failures += 1
                }
            }
            let elapsed = ContinuousClock.now - start
            return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, bytes, failures)
        }
        func median(_ runs: [(seconds: Double, bytes: Int, failures: Int)]) -> Double {
            runs.map(\.seconds).sorted()[runs.count / 2]
        }

        let off = (0 ..< 3).map { _ in load(nil) }
        let coldCompressors = (0 ..< 3).map { _ in WPEParityTextureCompressor() }
        let caches = (0 ..< 3).map { WPEParityCompressedTextureCache(cachesURL: scratch.appending(path: "cold-\($0)")) }
        let cold = zip(coldCompressors, caches).map { load(WPEParityTextureCompression(compressor: $0, cache: $1)) }
        let coldCompressor = coldCompressors[0]
        let cache = caches[2]
        let warmCompressor = WPEParityTextureCompressor()
        let warm = (0 ..< 3).map { _ in load(WPEParityTextureCompression(compressor: warmCompressor, cache: cache)) }
        print("scene 3509243656 textures: \(textures.count) TEX files, load failures \(off[0].failures)")
        print("scene 3509243656 off: allocated \(off[0].bytes) bytes, median load \(median(off)) s")
        print("scene 3509243656 on cold: allocated \(cold[0].bytes) bytes, median load \(median(cold)) s, "
            + "outcomes \(coldCompressor.outcomeCounts)")
        print("scene 3509243656 on warm: allocated \(warm[0].bytes) bytes, median load \(median(warm)) s, "
            + "encodes \(warmCompressor.encodeCount), outcomes \(warmCompressor.outcomeCounts)")
        XCTAssertLessThanOrEqual(cold[0].bytes, off[0].bytes)
        XCTAssertEqual(warmCompressor.encodeCount, 0)

        let defaults = UserDefaults.appScoped()
        defaults.set(true, forKey: WPEParityResourceSaverFlags.textureCompressionDefaultsKey)
        defer { defaults.removeObject(forKey: WPEParityResourceSaverFlags.textureCompressionDefaultsKey) }
        let (_, renderer, rendererDevice, queue) = try await makeRenderer("3509243656")
        for frame in 1 ... 60 {
            try await renderFrame(renderer, label: "scene 3509243656 compressed frame \(frame)")
        }
        print("scene 3509243656 renderer outcomes \(WPEParityTextureCompression.shared.compressor.outcomeCounts)")
        let backbuffer = renderer.backbuffer
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "wpe-parity-3509243656-compressed.png")
        try writePNG(readBack(backbuffer, device: rendererDevice, queue: queue), width: backbuffer.width,
                     height: backbuffer.height, to: url)
        print("scene 3509243656 compressed: frame 60 written to \(url.path)")
    }

    /// Two runs without aliasing must already agree, or a difference with it says nothing about aliasing.
    func testRenderTargetAliasingKeepsEveryBackbufferWithinGPUNoiseOver120Frames() async throws {
        for sceneID in ["3509243656", "3815666789"] {
            var runs: [(renderer: WPEParityFrameRenderer, device: MTLDevice, queue: MTLCommandQueue)] = []
            for aliasing in [false, false, true] {
                var settings = Self.settings
                settings.renderTargetAliasing = aliasing
                let (_, renderer, device, queue) = try await makeRenderer(sceneID, settings: settings)
                runs.append((renderer, device, queue))
            }
            let format = runs[0].renderer.backbuffer.pixelFormat
            var repeated = BackbufferDifference(format: format), aliased = BackbufferDifference(format: format)
            for frame in 1 ... 120 {
                var pixels: [[UInt8]] = []
                for (index, run) in runs.enumerated() {
                    try await renderFrame(run.renderer, label: "scene \(sceneID) run \(index) frame \(frame)")
                    try pixels.append(readBack(run.renderer.backbuffer, device: run.device, queue: run.queue))
                }
                repeated.keepWorse(BackbufferDifference(pixels[0], pixels[1], format: format, frame: frame))
                aliased.keepWorse(BackbufferDifference(pixels[0], pixels[2], format: format, frame: frame))
            }
            print("scene \(sceneID): repeat \(repeated); aliasing \(aliased)")
            guard repeated.isWithinGPUNoise else {
                return XCTFail("scene \(sceneID): two runs without aliasing differ beyond GPU noise: \(repeated)")
            }
            print("scene \(sceneID): aliased \(runs[2].renderer.aliasedRenderTargets.sorted())")
            XCTAssertFalse(runs[2].renderer.aliasedRenderTargets.isEmpty, "scene \(sceneID) aliases nothing")
            XCTAssertTrue(aliased.isWithinGPUNoise, "scene \(sceneID): aliasing changes the backbuffer: \(aliased)")
        }
    }

    /// Only the capture's settings draw every pass; with others the fixture lacks programs and the graph is smaller.
    func testScene3509243656RenderTargetAliasingSavesTargetMemoryAt4K() async throws {
        var bytes: [Int] = []
        for aliasing in [false, true] {
            var settings = Self.settings
            settings.renderTargetAliasing = aliasing
            let (_, renderer, _, _) = try await makeRenderer("3509243656", settings: settings, width: 3840, height: 2160)
            for frame in 1 ... 3 {
                try await renderFrame(renderer, label: "scene 3509243656 4K aliasing \(aliasing) frame \(frame)")
            }
            bytes.append(renderer.heapBytes + renderer.dedicatedTextureBytes)
            print("scene 3509243656 4K aliasing \(aliasing): heap \(renderer.heapBytes) bytes, dedicated textures "
                + "\(renderer.dedicatedTextureBytes) bytes, aliased \(renderer.aliasedRenderTargets.sorted())")
        }
        XCTAssertLessThan(bytes[1], bytes[0])
    }

    private func render(_ sceneID: String, editGeneral: (inout [String: Any]) -> Void = { _ in }) async throws {
        let (plan, renderer, device, queue) = try await makeRenderer(sceneID, editGeneral: editGeneral)

        let reasons = Dictionary(grouping: renderer.skipped.values, by: \.category).mapValues(\.count)
        // Every draw must reach a pipeline. Objects hidden at load are planned too, and the capture holds no shaders
        // for their programs.
        var hiddenSkips = 0
        for (index, skip) in renderer.skipped.sorted(by: { $0.key < $1.key }) {
            if case let .scene(draw)? = plan.frames[0].draws[index], !plan.state.isVisible(draw.objectID) {
                hiddenSkips += 1
                continue
            }
            XCTFail("\(sceneID) operation \(index): \(skip)")
        }
        print("scene \(sceneID): \(hiddenSkips) draws of objects hidden at load skipped")
        print("scene \(sceneID): draws \(renderer.drawCount) total, \(renderer.executedDrawCount) executed, "
            + "\(renderer.skipped.count) skipped \(reasons)")
        print("scene \(sceneID): transparent fallback textures \(renderer.fallbackTextures.sorted { $0.key < $1.key })")
        XCTAssertEqual(renderer.executedDrawCount + renderer.skipped.count, renderer.drawCount)
        if sceneID == "3660962877" {
            let visible = renderer.constants.keys.count { index in
                guard case let .scene(draw)? = plan.frames[0].draws[index] else { return true }
                return plan.state.isVisible(draw.objectID)
            }
            // 7 image and particle draws and 24 text draws, as the package matches 31/31.
            XCTAssertEqual(visible, 31)
        }

        if sceneID == "3815666789" {
            // foliagesway's vertex stage reads `speed` (default 1), its fragment stage `speeduv` (scene 5).
            let foliage = renderer.constants.filter { plan.programs[$0.key]?.shader == "effects/foliagesway" }
            XCTAssertFalse(foliage.isEmpty)
            func float(_ value: WPECBufferValue?) -> Float? {
                if case let .float(number)? = value {
                    number
                } else {
                    nil
                }
            }
            for (index, stages) in foliage {
                XCTAssertEqual(float(stages[.vertex]?["g_Speed"]), 1, "operation \(index) vertex")
                XCTAssertEqual(float(stages[.fragment]?["g_Speed"]), 5, "operation \(index) fragment")
            }
        }

        if sceneID == "3660962877" {
            try assertObject935(plan: plan, renderer: renderer)
        }

        for frame in 1 ... 3 {
            try await renderFrame(renderer, label: "scene \(sceneID) frame \(frame)")
        }
        print("scene \(sceneID): heap \(renderer.heapBytes) bytes, dedicated textures "
            + "\(renderer.dedicatedTextureBytes) bytes")
        if sceneID == "3660962877" {
            try await assertVideoPlays(renderer: renderer, device: device, queue: queue)
        } else {
            XCTAssertEqual(renderer.videoTextures.count, 0)
        }

        let backbuffer = renderer.backbuffer
        XCTAssertEqual(backbuffer.pixelFormat, .rgba8Unorm)
        let pixels = try readBack(backbuffer, device: device, queue: queue)
        let first = Array(pixels.prefix(3))
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { Array(pixels[$0 ..< $0 + 3]) != first },
                      "\(sceneID) backbuffer is one flat colour \(first)")
        let translucent = stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] != 255 }
        XCTAssertEqual(translucent, 0, "\(sceneID) pixels with alpha below 1")

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "wpe-parity-\(sceneID).png")
        try writePNG(pixels, width: backbuffer.width, height: backbuffer.height, to: url)
        print("scene \(sceneID): frame 3 written to \(url.path)")
    }

    private func makeRenderer(
        _ sceneID: String, settings: WPEParityProgramSettings = WPEParityRealSceneTests.settings,
        width: Int = WPEParityRealSceneTests.width, height: Int = WPEParityRealSceneTests.height,
        editGeneral: (inout [String: Any]) -> Void = { _ in }
    ) async throws -> (WPEParityFramePlan, WPEParityFrameRenderer, MTLDevice, MTLCommandQueue) {
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
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sceneDirectory.appending(path: "scene.json"))
        ) as? [String: Any])
        var general = json["general"] as? [String: Any] ?? [:]
        editGeneral(&general)
        json["general"] = general
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
        // The capture's wpeassets/ holds only shaders; util materials come from the WPE install.
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: settings,
                                          width: width, height: height)

        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let geometryCompiler = try WPEParityHelperShaderCompiler.local(workDirectory: cache.appending(path: "shaderc"))
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms,
                                                     geometryCompiler: geometryCompiler,
                                                     uncapturedUtilityPrograms: WPEParityFixtureShaderCompiler.utilityPrograms(in: plan)),
            diskCache: WPEParityShaderDiskCache(cachesURL: cache)
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: "hlsl-capture-2026-10-12",
                                                bindingABIVersion: 1),
            particleSeed: 1
        )
        return (plan, renderer, device, queue)
    }

    private func renderFrame(_ renderer: WPEParityFrameRenderer, label: String) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("\(label) was skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error, label)
        let milliseconds = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        print("\(label): GPU \(String(format: "%.3f", milliseconds)) ms")
    }

    /// Object 1003 samples a 4000x2300 video .tex. Playback follows AVPlayer's wall clock, so once the first decoded
    /// frame lands, a later frame holds different video pixels.
    private func assertVideoPlays(renderer: WPEParityFrameRenderer, device: MTLDevice,
                                  queue: MTLCommandQueue) async throws {
        XCTAssertEqual(renderer.videoTextures.count, 1)
        let video = try XCTUnwrap(renderer.videoTextures.first)
        XCTAssertEqual([video.width, video.height], [4000, 2300])
        XCTAssertEqual(video.pixelFormat, .bgra8Unorm)
        var before = try readBack(video, device: device, queue: queue)
        let deadline = Date().addingTimeInterval(10)
        var waits = 0
        while !before.contains(where: { $0 != 0 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            waits += 1
            try await renderFrame(renderer, label: "scene 3660962877 waiting for video frame \(waits)")
            before = try readBack(video, device: device, queue: queue)
        }
        XCTAssertTrue(before.contains { $0 != 0 }, "no decoded video frame reached the texture within 10 s")
        var changed = 0
        while changed == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            try await renderFrame(renderer, label: "scene 3660962877 waiting for the next video frame")
            let after = try readBack(video, device: device, queue: queue)
            changed = stride(from: 0, to: after.count, by: 4).count { after[$0 ..< $0 + 4] != before[$0 ..< $0 + 4] }
        }
        XCTAssertGreaterThan(changed, 0, "the video texture held one frame until the 10 s deadline")
    }

    /// Object 935's layer-mesh draw packs MVP rows as cbuffer registers. The spec values assume V = I, which
    /// this scene's camera gives; the package's camera and layer rules give the same matrix.
    private func assertObject935(plan: WPEParityFramePlan, renderer: WPEParityFrameRenderer) throws {
        let index = try XCTUnwrap(plan.frames[0].draws.first { _, draw in
            if case let .scene(scene) = draw {
                scene.objectID == "935" && scene.geometry == .layerMesh
            } else {
                false
            }
        }?.key)
        let draw = try XCTUnwrap(renderer.uniforms(index), "operation \(index) was skipped")
        guard case let .matrix(packed)? = draw.matrices.values["g_ModelViewProjectionMatrix"] else {
            return XCTFail("no g_ModelViewProjectionMatrix")
        }
        let layers = WPEParityLayerTransformSet(document: plan.document,
                                                renderTargetSize: SIMD2(Float(Self.width), Float(Self.height)))
        let expected = try layers.draw("935", kind: .layer, parallax: .zero).matrices.modelViewProjection
        let spec: [[Float]] = [
            [-1.15e-8, 1.02761e-3, 0, -0.805596], [-5.55231e-3, -6.7e-9, 0, -0.199726],
            [0, 0, 2.5e-4, 0.5], [0, 0, 0, 1],
        ]
        for register in 0 ..< 4 {
            for component in 0 ..< 4 {
                let value = packed.columns[register][component]
                XCTAssertEqual(value, spec[register][component], accuracy: 1e-5, "spec c\(register).\(component)")
                XCTAssertEqual(value, expected[component][register], accuracy: 1e-5, "package c\(register).\(component)")
            }
        }
        XCTAssertEqual((draw.matrices.projection * SIMD4<Float>(0, 0, -2000, 1)).z, 0, accuracy: 1e-6)
        XCTAssertEqual((draw.matrices.projection * SIMD4<Float>(0, 0, 2000, 1)).z, 1, accuracy: 1e-6)
    }

    private func readBack(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        // Raw texel bytes; an HDR backbuffer is rgba16Float, 8 bytes a pixel.
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

    private func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// The worst frame's difference between two runs' backbuffers, rgba16Float or 8-bit unorm.
private struct BackbufferDifference: CustomStringConvertible {
    // GPU noise of the particle geometry emulation under load: up to 277 pixels in one frame, a few half ulps each.
    // 16 half ulps near 0.8 is about 2/255, hence 2 steps for 8-bit unorm.
    static let halfULPTolerance = 16
    static let unormStepTolerance = 2
    static let pixelLimit = 1024

    var frame = 0
    /// Half ulps for rgba16Float, unorm steps otherwise.
    let stepTolerance: Int
    /// Pixels with any channel differing at all.
    var changedPixels = 0
    /// Pixels with a channel more than `stepTolerance` representable steps off.
    var pixelsBeyondTolerance = 0
    var maxSteps = 0
    var differingFrames = 0

    var isWithinGPUNoise: Bool {
        pixelsBeyondTolerance <= Self.pixelLimit
    }

    var description: String {
        "\(differingFrames) frames differ, worst frame \(frame): \(pixelsBeyondTolerance) pixels beyond "
            + "\(stepTolerance) steps (limit \(Self.pixelLimit)), \(changedPixels) changed, max \(maxSteps) steps"
    }

    init(format: MTLPixelFormat) {
        stepTolerance = format == .rgba16Float ? Self.halfULPTolerance : Self.unormStepTolerance
    }

    init(_ lhs: [UInt8], _ rhs: [UInt8], format: MTLPixelFormat, frame: Int) {
        self.init(format: format)
        self.frame = frame
        let half = format == .rgba16Float
        lhs.withUnsafeBytes { a in
            rhs.withUnsafeBytes { b in
                guard memcmp(a.baseAddress!, b.baseAddress!, min(a.count, b.count)) != 0 else { return }
                let wide = (a.bindMemory(to: UInt64.self), b.bindMemory(to: UInt64.self))
                let narrow = (a.bindMemory(to: UInt32.self), b.bindMemory(to: UInt32.self))
                let halves = (a.bindMemory(to: UInt16.self), b.bindMemory(to: UInt16.self))
                let pixelCount = min(a.count, b.count) / (half ? 8 : 4)
                for pixel in 0 ..< pixelCount {
                    guard half ? wide.0[pixel] != wide.1[pixel] : narrow.0[pixel] != narrow.1[pixel] else { continue }
                    var steps = 0
                    for channel in pixel * 4 ..< pixel * 4 + 4 {
                        steps = max(steps, half ? abs(Self.ordered(halves.0[channel]) - Self.ordered(halves.1[channel]))
                            : abs(Int(a[channel]) - Int(b[channel])))
                    }
                    changedPixels += steps > 0 ? 1 : 0
                    pixelsBeyondTolerance += steps > stepTolerance ? 1 : 0
                    maxSteps = max(maxSteps, steps)
                }
            }
        }
        differingFrames = changedPixels > 0 ? 1 : 0
    }

    mutating func keepWorse(_ other: Self) {
        let frames = differingFrames + other.differingFrames
        if (other.pixelsBeyondTolerance, other.maxSteps, other.changedPixels)
            > (pixelsBeyondTolerance, maxSteps, changedPixels) {
            self = other
        }
        differingFrames = frames
    }

    /// Half-float bits mapped to integers that are consecutive across adjacent representable values.
    private static func ordered(_ bits: UInt16) -> Int {
        bits & 0x8000 == 0 ? Int(bits) : -Int(bits & 0x7FFF)
    }
}

private struct NoScriptResolver: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
