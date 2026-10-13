#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
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

    /// Exercise the frame's camera and light consumers, including ancestor hiding and fallback to the authored
    /// root. Camera motion must move the actual glyph pixels; moving lights must keep the live ambient write.
    func testFrameConsumesLiveCameraAndLightsWithoutReloading() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: false)) as? [String: Any])
        var general = try XCTUnwrap(json["general"] as? [String: Any])
        general["lightconfig"] = ["point": 1]
        json["general"] = general
        var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
        objects += [
            ["id": 100, "origin": "10 20 0"],
            ["id": 101, "camera": "camera", "origin": "0 0 0"],
            ["id": 102, "camera": "camera", "parent": 100, "origin": "70 -20 0", "visible": false],
            ["id": 103, "light": "lpoint", "parent": 100, "origin": "1 2 3", "color": "0.25 0.5 1",
             "intensity": 2, "radius": 9],
        ]
        json["objects"] = objects
        let fixture = try await makeSyntheticRenderer(effect: false, scene: JSONSerialization.data(withJSONObject: json))
        let renderer = fixture.renderer
        XCTAssertEqual(renderer.skipped, [:])
        func constants() throws -> [String: WPECBufferValue] {
            try XCTUnwrap(renderer.lastFrameDraws.first?.draw.constants[.fragment])
        }
        func vector(_ name: String) throws -> [Float] {
            let value = try constants()[name]
            if case let .vector(components)? = value {
                return components
            }
            if case let .array(elements)? = value, elements.count == 1,
               case let .vector(components) = elements[0] {
                return components
            }
            XCTFail("missing or malformed \(name)")
            return []
        }
        func centroid() throws -> Double {
            let pixels = try readBack(renderer.backbuffer, fixture)
            var (total, count) = (0, 0)
            for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] > 0 {
                total += (index / 4) % Self.width
                count += 1
            }
            XCTAssertGreaterThan(count, 0)
            return Double(total) / Double(max(count, 1))
        }
        try await encode(renderer, label: "root-equivalent object camera")
        let original = try centroid()
        XCTAssertEqual(try vector("g_LPoint_Origin"), [11, 22, 3, 2])
        renderer.state.set(.visible, of: "102", to: SIMD4(1, 0, 0, 0))
        renderer.state.set(.color, of: "103", to: SIMD4(0.5, 0.25, 0.125, 0))
        renderer.state.setScriptField("ambientcolor", of: "", to: .vector(SIMD4(0.1, 0.2, 0.3, 0)), invalidating: .lighting)
        try await encode(renderer, label: "last-visible camera and live light color")
        XCTAssertEqual(try centroid(), original - 80, accuracy: 0.05)
        XCTAssertEqual(try vector("g_LPoint_Color"), [1, 0.5, 0.25, 9])
        renderer.state.set(.origin, of: "103", to: SIMD4(4, 5, 6, 0))
        try await encode(renderer, label: "moving light keeps ambient")
        XCTAssertEqual(try vector("g_LPoint_Origin"), [14, 25, 6, 2])
        XCTAssertEqual(try vector("g_LightAmbientColor"), [0.1, 0.2, 0.3])
        renderer.state.set(.visible, of: "100", to: .zero)
        renderer.state.set(.visible, of: "101", to: .zero)
        try await encode(renderer, label: "hidden camera ancestors restore authored root")
        XCTAssertEqual(try centroid(), original, accuracy: 0.05)
        XCTAssertNil(try constants()["g_LPoint_Origin"], "a hidden light must not leave the previous frame's array")
        XCTAssertEqual(try vector("g_LightAmbientColor"), [0.1, 0.2, 0.3])
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

    /// Four real GPU readers are held behind an event while later CPU atlas versions are published. Waiting
    /// after each upload would hide an in-place texture overwrite; each reader must see its own earlier pixels.
    func testAtlasVersionsStayImmutableAcrossOverlappingGPUReaders() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let ready = try XCTUnwrap(device.makeSharedEvent())
        defer { ready.signaledValue = 1 }
        var instance = WPEParityGlyphAtlasInstance(fontPath: "overlapping-readers", pointSize: 32)
        let key = WPEParityTextAtlasTextures.Key(atlasKey: instance.key, atlas: .mono)
        var cache = WPEParityTextAtlasTextures(atlases: [:])
        var submitted: [(commandBuffer: MTLCommandBuffer, result: MTLBuffer, expected: UInt8)] = []
        var versions: Set<ObjectIdentifier> = []

        for step in 1 ... 4 {
            let expected = UInt8(step * 37)
            instance.mono.reset()
            _ = try XCTUnwrap(instance.mono.insert(key: UInt32(step), bitmap: WPEParityGlyphBitmap(
                width: 2, rows: 2, pixelMode: .gray, pixels: Array(repeating: expected, count: 4)
            )))
            XCTAssertTrue(cache.replace([instance.key: instance], device: device))
            instance = try XCTUnwrap(cache.atlases[instance.key])
            let texture = try XCTUnwrap(cache.textures[key])
            XCTAssertTrue(versions.insert(ObjectIdentifier(texture)).inserted,
                          "a changed atlas must publish a new texture while earlier versions have readers")
            XCTAssertEqual(cache.contentGenerations[key], instance.mono.contentGeneration)
            XCTAssertFalse(instance.mono.isDirty)
            XCTAssertTrue(cache.upload(device: device))
            XCTAssertTrue(try XCTUnwrap(cache.textures[key]) === texture, "a clean atlas reuses its GPU version")

            let result = try XCTUnwrap(device.makeBuffer(length: 256, options: .storageModeShared))
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(commandBuffer.retainedReferences, "GPU readers must own the textures they encode")
            commandBuffer.encodeWaitForEvent(ready, value: 1)
            let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: result, destinationOffset: 0,
                      destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            blit.endEncoding()
            commandBuffer.commit()
            XCTAssertNotEqual(commandBuffer.status, .completed, "this reader must overlap the later CPU updates")
            submitted.append((commandBuffer, result, expected))
        }

        ready.signaledValue = 1
        for submission in submitted {
            await submission.commandBuffer.completed()
            XCTAssertNil(submission.commandBuffer.error)
            XCTAssertEqual(submission.result.contents().load(as: UInt8.self), submission.expected)
        }
    }

    func testTextUserPropertyRelaysTheLayerWithoutReloading() async throws {
        let wpeAssets = try wpeAssets()
        let scene = try Self.syntheticScene(effect: false, text: ["user": "caption", "value": "Hi"])
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let cache = FileManager.default.temporaryDirectory.appending(path: "parity-text-cache",
                                                                     directoryHint: .isDirectory)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let driver = try WPEParitySceneDriver(device: device)
        try await driver.load(document: Self.parse(scene),
                              assets: WPEParityProgramAssets(sceneDirectory: scratch, assetRoots: [wpeAssets]),
                              settings: WPEParityProgramSettings(),
                              drawableSize: CGSize(width: Self.width, height: Self.height), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        let generation = driver.loadGeneration
        try await encode(renderer, label: "Hi")
        let before = try XCTUnwrap(renderer.texts[Self.textID])

        let patch = WPEScenePropertyPatch(bindingsByProperty: driver.userPropertyBindings,
                                          oldValues: ["caption": .string("Hi")],
                                          newValues: ["caption": .string("Hello")])
        let changed = try Self.parse(scene, userValues: ["caption": .string("Hello")])
        XCTAssertTrue(driver.prepareUserProperties(patch, document: changed))
        XCTAssertTrue(driver.commitUserProperties(patch))
        XCTAssertTrue(driver.renderer === renderer, "the renderer is not rebuilt")
        XCTAssertEqual(driver.loadGeneration, generation, "the scene did not reload")
        try await encode(renderer, label: "Hello")
        XCTAssertEqual(renderer.skipped, [:])
        let after = try XCTUnwrap(renderer.texts[Self.textID])
        XCTAssertEqual(after.object.text, "Hello")
        let pixels = try readBack(renderer.backbuffer, device: device, queue: queue)

        let old = try glyphRect(before, document: changed)
        let rect = try glyphRect(after, document: changed)
        XCTAssertGreaterThan(rect.max.x - rect.min.x, old.max.x - old.min.x)
        var (inside, outside, beyondOld) = (0, 0, 0)
        for y in 0 ..< Self.height {
            for x in 0 ..< Self.width {
                let offset = (y * Self.width + x) * 4
                guard pixels[offset ..< offset + 3].contains(where: { $0 != 0 }) else { continue }
                if x >= rect.min.x, x < rect.max.x, y >= rect.min.y, y < rect.max.y {
                    inside += 1
                } else {
                    outside += 1
                }
                if x < old.min.x || x >= old.max.x {
                    beyondOld += 1
                }
            }
        }
        print("re-laid glyph block \(rect.min) ..< \(rect.max) (was \(old.min) ..< \(old.max)): covered inside "
            + "\(inside), outside \(outside), beyond the old block \(beyondOld)")
        XCTAssertGreaterThan(inside, 0)
        XCTAssertEqual(outside, 0)
        XCTAssertGreaterThan(beyondOld, 0, "the frame draws the new layout")
    }

    func testTextUserPropertyRebuildsItsFBOAndEmptyDrawsWithoutReloading() async throws {
        let wpeAssets = try wpeAssets()
        let scene = try Self.syntheticScene(effect: true, text: ["user": "caption", "value": "Hi"])
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let cache = FileManager.default.temporaryDirectory.appending(path: "parity-text-cache",
                                                                     directoryHint: .isDirectory)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let driver = try WPEParitySceneDriver(device: device)
        try await driver.load(document: Self.parse(scene),
                              assets: WPEParityProgramAssets(sceneDirectory: scratch,
                                                             assetRoots: [wpeAssets, wpeAssets.appending(path: "effects/tint")]),
                              settings: WPEParityProgramSettings(),
                              drawableSize: CGSize(width: Self.width, height: Self.height), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        let generation = driver.loadGeneration
        try await encode(renderer, label: "initial effect text")
        let initial = try readBack(renderer.backbuffer, device: device, queue: queue)
        let originalSize = try XCTUnwrap(renderer.texts[Self.textID]).layout.fboSize
        var caption = "Hi"

        for next in ["Hello", "", "Hi"] {
            let patch = WPEScenePropertyPatch(bindingsByProperty: driver.userPropertyBindings,
                                              oldValues: ["caption": .string(caption)],
                                              newValues: ["caption": .string(next)])
            let changed = try Self.parse(scene, userValues: ["caption": .string(next)])
            XCTAssertTrue(driver.prepareUserProperties(patch, document: changed), next.debugDescription)
            XCTAssertTrue(driver.commitUserProperties(patch))
            XCTAssertTrue(driver.renderer === renderer)
            XCTAssertEqual(driver.loadGeneration, generation)
            try await encode(renderer, label: "effect text \(next.debugDescription)")
            XCTAssertEqual(renderer.skipped, [:])
            let text = try XCTUnwrap(renderer.texts[Self.textID])
            XCTAssertEqual(text.object.text, next)
            let glyphs = renderer.frames[0].draws.values.compactMap { draw -> WPEParitySceneDraw? in
                guard case let .scene(scene) = draw, scene.objectID == Self.textID,
                      scene.fillsComposite, scene.geometry == .textGlyphs(.mono) else { return nil }
                return scene
            }
            let pixels = try readBack(renderer.backbuffer, device: device, queue: queue)
            let covered = stride(from: 0, to: pixels.count, by: 4).count { pixels[$0 ..< $0 + 3].contains { $0 != 0 } }
            if next.isEmpty {
                XCTAssertTrue(glyphs.isEmpty, "the old glyph draw must leave the current graph")
                XCTAssertEqual(covered, 0, "the old text must leave the actual frame")
            } else {
                let glyph = try XCTUnwrap(glyphs.first)
                let target = try XCTUnwrap(renderer.frames[0].resources.first { $0.id == glyph.target })
                XCTAssertEqual(SIMD2(target.width, target.height), text.layout.fboSize)
                XCTAssertGreaterThan(covered, 0)
                if next == "Hello" {
                    XCTAssertGreaterThan(target.width, originalSize.x, "the FBO grows in the current renderer")
                } else {
                    XCTAssertEqual(pixels, initial, "returning to Hi restores its original output")
                }
            }
            caption = next
        }
    }

    /// Fixed NotoSans32 metrics: Hello + space + big has ink width542; the sole blank gains58 at width600.
    /// The World suffix is the final, unwrapped line and must keep its geometry and actual pixels.
    func testScriptBlockAlignJustifiesOnlyTheWrappedRowAndKeepsItsAtlas() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: false)) as? [String: Any])
        var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
        objects[0].merge(["text": "Hello big World", "pointsize": 32, "origin": "100 400 0", "padding": "0 0",
                          "limitwidth": true, "maxwidth": 600, "horizontalalign": "left", "verticalalign": "top",
                          "alpha": ["value": 1, "script": """
                          let frame = 0;
                          export function update(value) {
                              frame += 1;
                              thisLayer.blockalign = frame >= 2;
                              thisLayer.backgroundbrightness = frame >= 2 ? 2.25 : 1;
                              return value;
                          }
                          """]] as [String: Any]) { _, next in next }
        json["objects"] = objects
        let fixture = try await makeSyntheticRenderer(effect: false, scene: JSONSerialization.data(withJSONObject: json),
                                                      scripted: true)
        let renderer = fixture.renderer
        XCTAssertEqual(renderer.skipped, [:])
        try await encode(renderer, label: "unjustified wrapped row")
        let before = try XCTUnwrap(renderer.texts[Self.textID])
        let beforeMesh = try XCTUnwrap(before.layout.mesh)
        XCTAssertEqual(beforeMesh.lineCount, 2)
        XCTAssertEqual(beforeMesh.mono.glyphKeys.count, 14)
        guard beforeMesh.mono.vertices.count == 56 else { return XCTFail("unexpected fixed glyph geometry") }
        XCTAssertEqual(beforeMesh.mono.vertices[6 * 4].x, 366)
        XCTAssertEqual(beforeMesh.maxX, 542)
        let beforeDraw = try textDraw(renderer, geometry: .textGlyphs(.mono))
        let atlasTexture = try XCTUnwrap(beforeDraw.textures["g_Texture0"])
        let atlasGeneration = try XCTUnwrap(renderer.textAtlases[before.atlasKey]).mono.contentGeneration
        let initialPipelines = renderer.pipelineCreations
        let initialLayout = renderer.state.generation(.textLayout)
        let beforePixels = try readBack(renderer.backbuffer, fixture)

        try await encode(renderer, label: "justified wrapped row")
        let after = try XCTUnwrap(renderer.texts[Self.textID])
        let mesh = try XCTUnwrap(after.layout.mesh)
        XCTAssertTrue(after.object.blockAlign)
        XCTAssertEqual(after.object.backgroundBrightness, 2.25, "layout applying must read the live brightness seed")
        XCTAssertEqual(mesh.mono.glyphKeys, beforeMesh.mono.glyphKeys)
        guard mesh.mono.vertices.count == 56 else { return XCTFail("unexpected justified glyph geometry") }
        XCTAssertEqual(mesh.mono.vertices[6 * 4].x, 424, "b moves by the independent58 pixel blank expansion")
        XCTAssertEqual(mesh.mono.vertices[8 * 4 + 1].x, 600, "wrapped row reaches the authored right edge")
        XCTAssertEqual(mesh.maxX, 600)
        XCTAssertEqual(Array(mesh.mono.vertices[9 * 4 ..< 14 * 4]),
                       Array(beforeMesh.mono.vertices[9 * 4 ..< 14 * 4]), "unwrapped World row cannot stretch")
        let afterDraw = try textDraw(renderer, geometry: .textGlyphs(.mono))
        XCTAssertFalse(afterDraw.vertexBuffer === beforeDraw.vertexBuffer, "changed positions need current geometry")
        XCTAssertTrue(try XCTUnwrap(afterDraw.textures["g_Texture0"]) === atlasTexture)
        XCTAssertTrue(afterDraw.pipeline.state === beforeDraw.pipeline.state)
        XCTAssertEqual(after.atlasKey, before.atlasKey)
        XCTAssertEqual(try XCTUnwrap(renderer.textAtlases[after.atlasKey]).mono.contentGeneration, atlasGeneration)
        XCTAssertEqual(renderer.pipelineCreations, initialPipelines)
        XCTAssertEqual(renderer.state.generation(.textLayout), initialLayout + 1)
        let afterPixels = try readBack(renderer.backbuffer, fixture)
        // Origin(100,400), top anchor ascender143: first row screen y153...287, final row y335...438.
        // The old ink ends at x642. New g ink occupies x636...700; x>=701 must stay black.
        var (oldBeyond, newBeyond, leaked) = (0, 0, 0)
        for y in 150 ..< 290 {
            for x in 650 ..< 700 {
                let at = (y * Self.width + x) * 4
                if beforePixels[at] > 0 {
                    oldBeyond += 1
                }
                if afterPixels[at] > 0 {
                    newBeyond += 1
                }
            }
            for x in 701 ..< Self.width where afterPixels[(y * Self.width + x) * 4] > 0 {
                leaked += 1
            }
        }
        XCTAssertEqual(oldBeyond, 0)
        XCTAssertGreaterThan(newBeyond, 0, "the shifted word must reach the actual GPU frame")
        XCTAssertEqual(leaked, 0, "no ink may cross the fixed600-pixel right edge")
        let lastRowStart = 330 * Self.width * 4
        XCTAssertEqual(Array(afterPixels[lastRowStart...]), Array(beforePixels[lastRowStart...]),
                       "the final unwrapped row retains its actual pixels")

        try await encode(renderer, label: "same block-align value")
        let sameDraw = try textDraw(renderer, geometry: .textGlyphs(.mono))
        XCTAssertTrue(sameDraw.vertexBuffer === afterDraw.vertexBuffer)
        XCTAssertTrue(try XCTUnwrap(sameDraw.indexBuffer) === XCTUnwrap(afterDraw.indexBuffer))
        XCTAssertTrue(try XCTUnwrap(sameDraw.textures["g_Texture0"]) === atlasTexture)
        XCTAssertTrue(sameDraw.pipeline.state === beforeDraw.pipeline.state)
        XCTAssertEqual(renderer.state.generation(.textLayout), initialLayout + 1)
        XCTAssertEqual(renderer.pipelineCreations, initialPipelines)
        let script = try XCTUnwrap(renderer.script)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    /// Native background color is scaled only in HDR, then flat/translucent blends RGB by the existing alpha.
    /// Read combine_srgb's real rgba16Float input so gamma conversion cannot hide incorrect linear values.
    func testScriptBackgroundBrightnessConsumesLiveHDRColorWithoutRebuildingText() async throws {
        for hdr in [false, true] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: false)) as? [String: Any])
            var general = try XCTUnwrap(json["general"] as? [String: Any])
            general["bloom"] = hdr
            general["hdr"] = hdr
            json["general"] = general
            var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
            objects[0].merge(["pointsize": 32, "opaquebackground": true, "backgroundcolor": "0.125 0.25 0.375",
                              "backgroundbrightness": ["value": 1.5, "script": """
                              if (thisLayer.backgroundbrightness !== 1.5) throw Error('authored background seed');
                              let frame = 0;
                              export function update(value) {
                                  frame += 1;
                                  return frame === 1 ? 1.5 : (frame <= 3 ? 3 : 6);
                              }
                              """], "alpha": 0.5] as [String: Any]) { _, next in next }
            json["objects"] = objects
            let fixture = try await makeSyntheticRenderer(effect: false, scene: JSONSerialization.data(withJSONObject: json),
                                                          settings: .init(bloom: false, hdrPostProcessing: hdr), scripted: true)
            let renderer = fixture.renderer
            XCTAssertEqual(fixture.plan.scene.engineFlags.hdr, hdr, "HDR positive must exercise the real HDR path")
            XCTAssertEqual(renderer.skipped, [:])
            var originalBackground: WPEParityDraw?
            var originalGlyph: WPEParityDraw?
            var originalAtlas: MTLTexture?
            var originalGeneration: UInt64?
            var initialLayout = 0, initialPipelines = 0, priorFields = 0
            for (frame, brightness) in [Float(1.5), 3, 3, 6].enumerated() {
                try await encode(renderer, label: "background hdr=\(hdr) frame\(frame)")
                let background = try textDraw(renderer, geometry: .textBackground)
                let glyph = try textDraw(renderer, geometry: .textGlyphs(.mono))
                let text = try XCTUnwrap(renderer.texts[Self.textID])
                let atlas = try XCTUnwrap(glyph.textures["g_Texture0"])
                let generation = try XCTUnwrap(renderer.textAtlases[text.atlasKey]).mono.contentGeneration
                XCTAssertEqual(renderer.state.scriptField("backgroundbrightness", of: Self.textID),
                               .vector(SIMD4(brightness, 0, 0, 0)))
                guard case let .float(alpha)? = background.constants[.fragment]?["g_Alpha"] else {
                    return XCTFail("missing real background alpha constant")
                }
                XCTAssertEqual(alpha, 0.5)
                var checkedForegroundColor = false
                for (stage, layout) in [(WPEHLSLStage.vertex, glyph.pipeline.vertex), (.fragment, glyph.pipeline.fragment)] {
                    for name in ["g_Color", "g_Color4"] where layout.cbuffers.contains(where: { $0[name] != nil }) {
                        guard case let .vector(color)? = glyph.constants[stage]?[name] else {
                            return XCTFail("missing real foreground \(name) constant in \(stage)")
                        }
                        XCTAssertEqual(color, name == "g_Color" ? [1, 1, 1] : [1, 1, 1, 0.5],
                                       "background scale cannot change the foreground color or alpha")
                        checkedForegroundColor = true
                    }
                    if layout.cbuffers.contains(where: { $0["g_Alpha"] != nil }) {
                        guard case let .float(glyphAlpha)? = glyph.constants[stage]?["g_Alpha"] else {
                            return XCTFail("missing real foreground alpha constant in \(stage)")
                        }
                        XCTAssertEqual(glyphAlpha, 0.5)
                    }
                }
                XCTAssertTrue(checkedForegroundColor, "the glyph pipeline must consume a real foreground color constant")
                let texture: MTLTexture
                if hdr {
                    let combine = try XCTUnwrap(renderer.lastFrameDraws.first { entry in
                        guard case let .post(post)? = renderer.frames[0].draws[entry.operation] else { return false }
                        return post.shader == "combine_srgb"
                    })
                    texture = try XCTUnwrap(combine.draw.textures["g_Texture0"])
                    XCTAssertEqual(texture.pixelFormat, .rgba16Float)
                } else {
                    texture = renderer.backbuffer
                    XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
                }
                // NotoSans32 "Hi" width123 + padding32 puts x430 inside left background padding, outside glyphs.
                let actual = try readPixel(texture, x: 430, y: 256, fixture: fixture)
                let scale: Float = hdr ? brightness : 1
                let expected = SIMD3<Float>(0.125, 0.25, 0.375) * scale * 0.5
                let tolerance: Float = hdr ? 0.002 : 1.0 / 255
                for lane in 0 ..< 3 {
                    XCTAssertEqual(actual[lane], expected[lane], accuracy: tolerance)
                }
                if hdr, frame == 3 {
                    XCTAssertGreaterThan(actual.z, 1, "linear HDR input must preserve overbright values")
                }
                if frame == 0 {
                    originalBackground = background
                    originalGlyph = glyph
                    originalAtlas = atlas
                    originalGeneration = generation
                    initialLayout = renderer.state.generation(.textLayout)
                    initialPipelines = renderer.pipelineCreations
                } else {
                    let initialBackground = try XCTUnwrap(originalBackground)
                    let initialGlyph = try XCTUnwrap(originalGlyph)
                    let initialAtlas = try XCTUnwrap(originalAtlas)
                    XCTAssertTrue(background.vertexBuffer === initialBackground.vertexBuffer)
                    XCTAssertTrue(try XCTUnwrap(background.indexBuffer) === XCTUnwrap(initialBackground.indexBuffer))
                    XCTAssertTrue(glyph.vertexBuffer === initialGlyph.vertexBuffer)
                    XCTAssertTrue(try XCTUnwrap(glyph.indexBuffer) === XCTUnwrap(initialGlyph.indexBuffer))
                    XCTAssertTrue(background.pipeline.state === initialBackground.pipeline.state)
                    XCTAssertTrue(glyph.pipeline.state === initialGlyph.pipeline.state)
                    XCTAssertTrue(atlas === initialAtlas)
                    XCTAssertEqual(generation, originalGeneration)
                    XCTAssertEqual(renderer.state.generation(.textLayout), initialLayout)
                    XCTAssertEqual(renderer.pipelineCreations, initialPipelines)
                    if frame == 2 {
                        XCTAssertEqual(renderer.state.scriptFieldsGeneration, priorFields, "same scale schedules no new work")
                    }
                }
                priorFields = renderer.state.scriptFieldsGeneration
            }
            let script = try XCTUnwrap(renderer.script)
            XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        }
    }

    /// Opaque text with an effect clears its FBO directly: RGB is not multiplied by alpha at this stage.
    func testScriptBackgroundBrightnessAndAlphaReachTheOpaqueEffectFBOClearWithoutRebuildingText() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: true)) as? [String: Any])
        var general = try XCTUnwrap(json["general"] as? [String: Any])
        general["bloom"] = true
        general["hdr"] = true
        json["general"] = general
        var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
        objects[0].merge(["pointsize": 32, "opaquebackground": true, "backgroundcolor": "0.125 0.25 0.375",
                          "backgroundbrightness": ["value": 1.5, "script": """
                          let frame = 0;
                          export function update(value) {
                              frame += 1;
                              if (frame === 4) thisLayer.alpha = 0.25;
                              return frame === 1 ? 1.5 : (frame <= 3 ? 3 : 6);
                          }
                          """], "alpha": 0.5] as [String: Any]) { _, next in next }
        json["objects"] = objects
        let fixture = try await makeSyntheticRenderer(effect: true, scene: JSONSerialization.data(withJSONObject: json),
                                                      settings: .init(bloom: false, hdrPostProcessing: true), scripted: true)
        let renderer = fixture.renderer
        XCTAssertTrue(fixture.plan.scene.engineFlags.hdr)
        XCTAssertEqual(renderer.skipped, [:])
        var originalGlyph: WPEParityDraw?
        var originalEffect: WPEParityDraw?
        var originalAtlas: MTLTexture?
        var originalGeneration: UInt64?
        var initialLayout = 0, initialPipelines = 0, priorFields = 0
        for (frame, brightness) in [Float(1.5), 3, 3, 6].enumerated() {
            try await encode(renderer, label: "opaque text effect clear frame\(frame)")
            let description = renderer.frames[frame % renderer.frames.count]
            XCTAssertFalse(description.draws.values.contains { draw in
                guard case let .scene(scene) = draw else { return false }
                return scene.objectID == Self.textID && scene.geometry == .textBackground
            }, "this guard must exercise the composite clear, not a direct background draw")
            let glyphOperation = try XCTUnwrap(description.draws.first { _, draw in
                guard case let .scene(scene) = draw else { return false }
                return scene.objectID == Self.textID && scene.geometry == .textGlyphs(.mono) && scene.fillsComposite
            })
            guard case let .scene(glyphDescription) = glyphOperation.value else { return XCTFail("missing composite glyphs") }
            let glyph = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == glyphOperation.key }?.draw)
            let effect = try XCTUnwrap(renderer.lastFrameDraws.first { entry in
                guard case let .scene(scene)? = description.draws[entry.operation] else { return false }
                return scene.objectID == Self.textID && scene.source?.effectFile == "effects/tint/effect.json"
                    && scene.source?.effectPass == 0 && scene.reads.contains(glyphDescription.target)
            })
            let input = try XCTUnwrap(effect.draw.textures["g_Texture0"])
            let resource = try XCTUnwrap(description.resources.first { $0.id == glyphDescription.target })
            let text = try XCTUnwrap(renderer.texts[Self.textID])
            XCTAssertEqual(resource.lifetime, .pooled, "the captured input must survive its effect reader")
            XCTAssertEqual(SIMD2(input.width, input.height), text.layout.fboSize)
            XCTAssertEqual(input.pixelFormat, .rgba16Float)
            guard input.width > 4, input.height > 4 else { return XCTFail("missing text FBO padding") }
            // Glyphs start at padding32 + H bearing12; pixel(4,4) is untouched by every glyph draw.
            let actual = try readPixel(input, x: 4, y: 4, fixture: fixture)
            let expected = SIMD3<Float>(0.125, 0.25, 0.375) * brightness
            for lane in 0 ..< 3 {
                XCTAssertEqual(actual[lane], expected[lane], accuracy: 0.002)
            }
            XCTAssertEqual(actual.w, frame == 3 ? 0.25 : 0.5, accuracy: 0.0005)
            if frame == 3 {
                XCTAssertGreaterThan(actual.z, 1, "raw HDR clear cannot clamp or multiply by alpha")
            }
            let atlas = try XCTUnwrap(glyph.textures["g_Texture0"])
            let generation = try XCTUnwrap(renderer.textAtlases[text.atlasKey]).mono.contentGeneration
            if frame == 0 {
                originalGlyph = glyph
                originalEffect = effect.draw
                originalAtlas = atlas
                originalGeneration = generation
                initialLayout = renderer.state.generation(.textLayout)
                initialPipelines = renderer.pipelineCreations
            } else {
                let initialGlyph = try XCTUnwrap(originalGlyph)
                let initialEffect = try XCTUnwrap(originalEffect)
                let initialAtlas = try XCTUnwrap(originalAtlas)
                XCTAssertTrue(glyph.vertexBuffer === initialGlyph.vertexBuffer)
                XCTAssertTrue(try XCTUnwrap(glyph.indexBuffer) === XCTUnwrap(initialGlyph.indexBuffer))
                XCTAssertTrue(glyph.pipeline.state === initialGlyph.pipeline.state)
                XCTAssertTrue(effect.draw.vertexBuffer === initialEffect.vertexBuffer)
                XCTAssertTrue(try XCTUnwrap(effect.draw.indexBuffer) === XCTUnwrap(initialEffect.indexBuffer))
                XCTAssertTrue(effect.draw.pipeline.state === initialEffect.pipeline.state)
                XCTAssertTrue(atlas === initialAtlas)
                XCTAssertEqual(generation, originalGeneration)
                XCTAssertEqual(renderer.state.generation(.textLayout), initialLayout)
                XCTAssertEqual(renderer.pipelineCreations, initialPipelines)
                if frame == 2 {
                    XCTAssertEqual(renderer.state.scriptFieldsGeneration, priorFields)
                }
            }
            priorFields = renderer.state.scriptFieldsGeneration
        }
        let script = try XCTUnwrap(renderer.script)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
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
        try glyphRect(sceneText(plan), document: plan.document)
    }

    private func glyphRect(_ text: WPEParitySceneText,
                           document: WPESceneDocument) throws -> (min: SIMD2<Int>, max: SIMD2<Int>) {
        let mesh = try XCTUnwrap(text.layout.mesh)
        let layers = WPEParityLayerTransformSet(document: document,
                                                renderTargetSize: SIMD2(Float(Self.width), Float(Self.height)),
                                                textSizes: [Self.textID: SIMD2(Float(text.layout.fboSize.x),
                                                                               Float(text.layout.fboSize.y))])
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

    /// One white 64 pt `text` at the canvas centre of a black orthographic scene without bloom; `effect` adds a tint.
    private static func syntheticScene(effect: Bool, text value: Any = "Hi") throws -> Data {
        var text: [String: Any] = [
            "id": Int(textID)!, "name": "hi", "text": value, "font": "fonts/NotoSans-Regular.ttf",
            "pointsize": 64, "color": "1 1 1", "origin": "\(width / 2) \(height / 2) 0",
        ]
        if effect {
            text["effects"] = [["file": "effects/tint/effect.json", "id": 7, "name": "tint", "visible": true]]
        }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": width, "height": height], "clearcolor": "0 0 0",
                        "bloom": false],
            "objects": [text],
        ]
        return try JSONSerialization.data(withJSONObject: scene)
    }

    private static func parse(_ scene: Data,
                              userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(data: scene, userValues: userValues,
                                         makeTransformScriptResolver: { _, _ in TextNoScripts() })
    }

    private func makeSyntheticRenderer(effect: Bool, scene: Data? = nil,
                                       settings: WPEParityProgramSettings = .init(), scripted: Bool = false) async throws -> Fixture {
        let wpeAssets = try wpeAssets()
        let document = try Self.parse(scene ?? Self.syntheticScene(effect: effect))
        // The tint effect keeps its material and shaders in its own folder.
        let assets = WPEParityProgramAssets(sceneDirectory: scratch,
                                            assetRoots: [wpeAssets, wpeAssets.appending(path: "effects/tint")])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: settings,
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
        if scripted {
            try renderer.attachScript(WPEParitySceneScript(
                document: document, state: renderer.state, assets: assets, canvasSize: renderer.pathCamera.size,
                screenResolution: SIMD2(Float(Self.width), Float(Self.height)), fieldDefaults: renderer.scriptFieldDefaults, host: .init()
            ))
        }
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

    private func textDraw(_ renderer: WPEParityFrameRenderer,
                          geometry: WPEParitySceneDraw.Geometry) throws -> WPEParityDraw {
        let operation = try XCTUnwrap(renderer.frames[0].draws.first { _, draw in
            guard case let .scene(scene) = draw else { return false }
            return scene.objectID == Self.textID && scene.geometry == geometry
        }?.key)
        return try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
    }

    private func readPixel(_ texture: MTLTexture, x: Int, y: Int, fixture: Fixture) throws -> SIMD4<Float> {
        let bytes = try readBack(texture, fixture)
        if texture.pixelFormat == .rgba16Float {
            let offset = (y * texture.width + x) * 8
            var result = SIMD4<Float>.zero
            for lane in 0 ..< 4 {
                let word = UInt16(bytes[offset + lane * 2]) | UInt16(bytes[offset + lane * 2 + 1]) << 8
                result[lane] = Float(Float16(bitPattern: word))
            }
            return result
        }
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        let offset = (y * texture.width + x) * 4
        var result = SIMD4<Float>.zero
        for lane in 0 ..< 4 {
            result[lane] = Float(bytes[offset + lane]) / 255
        }
        return result
    }

    private func encode(_ renderer: WPEParityFrameRenderer, label: String) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("\(label): frame skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error, label)
    }

    private func readBack(_ texture: MTLTexture, _ fixture: Fixture) throws -> [UInt8] {
        try readBack(texture, device: fixture.device, queue: fixture.queue)
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
}

private struct TextNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
