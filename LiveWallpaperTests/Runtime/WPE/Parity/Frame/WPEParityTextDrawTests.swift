#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Text layer draws on Metal (R23 Q4–Q6): the capture scenes' text, and a synthetic orthographic "Hi" in NotoSans
/// compiled by wpe-shaderc.
final class WPEParityTextDrawTests: XCTestCase {
    private static let textID = "5"
    private static let width = 1024
    private static let height = 512

    private struct Fixture {
        let plan: WPEParityFramePlan
        let renderer: WPEParityFrameRenderer
        let device: MTLDevice
        let queue: MTLCommandQueue
    }

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-text-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testCaptureScenesEncodeEveryTextDraw() async throws {
        for sceneID in ["3509243656", "3660962877"] {
            let fixture = try await makeCaptureRenderer(sceneID)
            let (plan, renderer) = (fixture.plan, fixture.renderer)
            let texts = Set(plan.scene.scene.objects.compactMap { object -> String? in
                if case .text = object.kind {
                    object.id
                } else {
                    nil
                }
            })
            let operations = plan.frames[0].draws.compactMap { index, draw -> Int? in
                guard case let .scene(scene) = draw, texts.contains(scene.objectID),
                      plan.state.isVisible(scene.objectID) else { return nil }
                return index
            }.sorted()
            print("scene \(sceneID): text objects \(texts.sorted()), visible text draws \(operations)")
            XCTAssertFalse(operations.isEmpty, sceneID)
            for index in operations {
                XCTAssertNil(renderer.skipped[index], "\(sceneID) operation \(index)")
            }
            try await encode(renderer, label: "scene \(sceneID)")
            let encoded = Set(renderer.lastFrameDraws.map(\.operation))
            XCTAssertEqual(operations.filter { !encoded.contains($0) }, [], sceneID)
        }
    }

    func testDirectTextCoversOnlyItsGlyphBlock() async throws {
        let fixture = try await makeSyntheticRenderer(effect: false)
        let renderer = fixture.renderer
        XCTAssertEqual(renderer.skipped, [:])
        try await encode(renderer, label: "text shown")
        let shown = try readBack(renderer.backbuffer, fixture)
        XCTAssertTrue(renderer.state.set(.visible, of: Self.textID, to: .zero))
        try await encode(renderer, label: "text hidden")
        let hidden = try readBack(renderer.backbuffer, fixture)

        let rect = try glyphRect(fixture.plan)
        let background = Array(hidden[0 ..< 3])
        var (inside, outside, uncovered) = (0, 0, 0)
        for y in 0 ..< Self.height {
            for x in 0 ..< Self.width {
                let offset = (y * Self.width + x) * 4
                let within = x >= rect.min.x && x < rect.max.x && y >= rect.min.y && y < rect.max.y
                if shown[offset ..< offset + 3].contains(where: { $0 != 0 }) {
                    if within {
                        inside += 1
                    } else {
                        outside += 1
                    }
                }
                if within, Array(hidden[offset ..< offset + 3]) != background {
                    uncovered += 1
                }
            }
        }
        print("glyph block rectangle \(rect.min) ..< \(rect.max): covered pixels inside \(inside), outside \(outside); "
            + "hidden pixels unlike the background inside \(uncovered)")
        XCTAssertEqual(background, [0, 0, 0])
        XCTAssertGreaterThan(inside, 0)
        XCTAssertEqual(outside, 0)
        XCTAssertEqual(uncovered, 0)
    }

    func testTextWithAnEffectRendersThroughItsFBO() async throws {
        let fixture = try await makeSyntheticRenderer(effect: true)
        let (plan, renderer) = (fixture.plan, fixture.renderer)
        XCTAssertEqual(renderer.skipped, [:])
        let text = try sceneText(plan)
        let glyphs = try XCTUnwrap(plan.frames[0].draws.first { _, draw in
            if case let .scene(scene) = draw {
                scene.fillsComposite && scene.geometry == .textGlyphs(.mono)
            } else {
                false
            }
        })
        guard case let .scene(draw) = glyphs.value else { return XCTFail("not a scene draw") }
        let fbo = try XCTUnwrap(plan.frames[0].resources.first { $0.id == draw.target })
        print("text FBO \(fbo.id) \(fbo.width)x\(fbo.height), layout fboSize \(text.layout.fboSize)")
        XCTAssertEqual(SIMD2(fbo.width, fbo.height), text.layout.fboSize)
        try await encode(renderer, label: "text with effect")
        print("text with effect draws \(renderer.lastFrameDraws.map { plan.programs[$0.operation]?.shader ?? "?" })")
        XCTAssertTrue(renderer.lastFrameDraws.contains { $0.operation == glyphs.key })
        let pixels = try readBack(renderer.backbuffer, fixture)
        let covered = stride(from: 0, to: pixels.count, by: 4).count { pixels[$0 ..< $0 + 3].contains { $0 != 0 } }
        print("text with effect: \(covered) covered pixels")
        XCTAssertGreaterThan(covered, 0, "no text reached the frame")
    }

    func testBoundAtlasHoldsTheCPUPixelsAndIsClean() async throws {
        let fixture = try await makeSyntheticRenderer(effect: false)
        let renderer = fixture.renderer
        try await encode(renderer, label: "atlas")
        let text = try sceneText(fixture.plan)
        let atlas = try XCTUnwrap(renderer.textAtlases[text.atlasKey]).mono
        XCTAssertTrue(try XCTUnwrap(fixture.plan.scene.textAtlases[text.atlasKey]).mono.isDirty)
        XCTAssertFalse(atlas.isDirty)
        let operation = try XCTUnwrap(fixture.plan.frames[0].draws.first { _, draw in
            if case let .scene(scene) = draw {
                scene.geometry == .textGlyphs(.mono)
            } else {
                false
            }
        }?.key)
        let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
        let texture = try XCTUnwrap(draw.textures["g_Texture0"])
        XCTAssertEqual(texture.pixelFormat, .r8Unorm)
        XCTAssertEqual([texture.width, texture.height, texture.mipmapLevelCount], [atlas.width, atlas.height, 1])
        var bytes = [UInt8](repeating: 0, count: atlas.width * atlas.height)
        texture.getBytes(&bytes, bytesPerRow: atlas.width, from: MTLRegionMake2D(0, 0, atlas.width, atlas.height),
                         mipmapLevel: 0)
        XCTAssertTrue(atlas.pixels.contains { $0 != 0 })
        XCTAssertEqual(bytes, atlas.pixels)
    }

    // MARK: Helpers

    private func sceneText(_ plan: WPEParityFramePlan) throws -> WPEParitySceneText {
        guard case let .text(text)? = plan.scene.scene.objects.first(where: { $0.id == Self.textID })?.kind else {
            throw XCTSkip("no text object \(Self.textID)")
        }
        return text
    }

    /// Pixel bounds of the glyph quads under the direct draw's MVP: anchor none, the layer model, the block offset
    /// and the glyph translation (140258050.c:145-179).
    private func glyphRect(_ plan: WPEParityFramePlan) throws -> (min: SIMD2<Int>, max: SIMD2<Int>) {
        let text = try sceneText(plan)
        let mesh = try XCTUnwrap(text.layout.mesh)
        let layers = WPEParityLayerTransformSet(document: plan.document,
                                                renderTargetSize: SIMD2(Float(Self.width), Float(Self.height)),
                                                textSizes: plan.scene.textSizes)
        let layerModel = WPEParityTextMatrices.layerModel(layers.model(Self.textID), anchorOffset: .zero,
                                                          blockOffset: text.layout.blockOffset)
        let model = WPEParityTextMatrices.direct(layerModel: layerModel,
                                                 translation: WPEParityTextMatrices.glyphTranslation(mesh))
        let mvp = layers.projection(Self.textID) * layers.view(Self.textID, parallax: .zero) * model
        var low = SIMD2<Float>(repeating: .infinity)
        var high = SIMD2<Float>(repeating: -.infinity)
        for vertex in mesh.mono.vertices {
            let clip = mvp * SIMD4(vertex.x, vertex.y, 0, 1)
            let pixel = SIMD2((clip.x / clip.w + 1) * 0.5 * Float(Self.width),
                              (1 - clip.y / clip.w) * 0.5 * Float(Self.height))
            low = simd_min(low, pixel)
            high = simd_max(high, pixel)
        }
        return (SIMD2(Int(low.x.rounded(.down)), Int(low.y.rounded(.down))),
                SIMD2(Int(high.x.rounded(.up)), Int(high.y.rounded(.up))))
    }

    private func wpeAssets() throws -> URL {
        // The sandboxed test host's home is its container; the WPE install lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let assets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: assets.appending(path: "fonts/NotoSans-Regular.ttf").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (fonts, materials/fonts)")
        }
        return assets
    }

    /// One white 64 pt "Hi" at the canvas centre of a black orthographic scene without bloom; `effect` adds a tint.
    private func makeSyntheticRenderer(effect: Bool) async throws -> Fixture {
        let wpeAssets = try wpeAssets()
        var text: [String: Any] = [
            "id": Int(Self.textID)!, "name": "hi", "text": "Hi", "font": "fonts/NotoSans-Regular.ttf",
            "pointsize": 64, "color": "1 1 1", "origin": "\(Self.width / 2) \(Self.height / 2) 0",
        ]
        if effect {
            text["effects"] = [["file": "effects/tint/effect.json", "id": 7, "name": "tint", "visible": true]]
        }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": Self.width, "height": Self.height], "clearcolor": "0 0 0",
                        "bloom": false],
            "objects": [text],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in TextNoScripts() })
        // The tint effect keeps its material and shaders in its own folder.
        let assets = WPEParityProgramAssets(sceneDirectory: scratch,
                                            assetRoots: [wpeAssets, wpeAssets.appending(path: "effects/tint")])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                          width: Self.width, height: Self.height)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        // Shared between the tests of this class, so only the first compiles cold.
        let cache = FileManager.default.temporaryDirectory.appending(path: "parity-text-cache",
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

    /// The capture machine's settings, as `WPEParityRealSceneTests` renders the scene.
    private func makeCaptureRenderer(_ sceneID: String) async throws -> Fixture {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let wpeAssets = try wpeAssets()
        let sceneDirectory = root.appending(path: "scene-sources/\(sceneID)")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sceneDirectory.appending(path: "scene.json"))
        ) as? [String: Any])
        var general = json["general"] as? [String: Any] ?? [:]
        general["camerashake"] = false
        json["general"] = general
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in TextNoScripts() })
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets,
                                          settings: WPEParityProgramSettings(bloom: true, hdrPostProcessing: true,
                                                                             msaa: true),
                                          width: 1920, height: 1080)
        let geometryCompiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms,
                                                     geometryCompiler: geometryCompiler),
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

    private func encode(_ renderer: WPEParityFrameRenderer, label: String) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("\(label): frame skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error, label)
    }

    private func readBack(_ texture: MTLTexture, _ fixture: Fixture) throws -> [UInt8] {
        let bytesPerRow = texture.width * 4
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
}

private struct TextNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
