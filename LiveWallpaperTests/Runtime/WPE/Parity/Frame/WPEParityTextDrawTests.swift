#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Text layer draws on Metal: the capture scenes' text, and a synthetic orthographic "Hi" in NotoSans
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
            try await encode(renderer, label: "scene \(sceneID)")
            // A sorted perspective scene replans on its first frame, so indices come from the encoded layout.
            let operations = renderer.frames[0].draws.compactMap { index, draw -> Int? in
                guard case let .scene(scene) = draw, texts.contains(scene.objectID),
                      renderer.state.isVisible(scene.objectID) else { return nil }
                return index
            }.sorted()
            print("scene \(sceneID): text objects \(texts.sorted()), visible text draws \(operations)")
            XCTAssertFalse(operations.isEmpty, sceneID)
            for index in operations {
                XCTAssertNil(renderer.skipped[index], "\(sceneID) operation \(index)")
            }
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

    /// A text layer's cursor box is model · anchor · blockOffset ± size/2 (1402585c0.c:35-148, 140256f20.c:302-325),
    /// so it centres on the drawn glyph block; an image layer's box stays model ± size/2.
    func testCursorBoxCentresOnTheDrawnTextBlockAndLeavesImagesAlone() async throws {
        for anchor in ["none", "topleft"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: false)) as? [String: Any])
            var general = try XCTUnwrap(json["general"] as? [String: Any])
            // A 1024x768 canvas on the 1024x512 target crops 128 px off its top and bottom.
            general["orthogonalprojection"] = ["width": Self.width, "height": 768]
            json["general"] = general
            var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
            let fields: [String: Any] = ["horizontalalign": "left", "anchor": anchor, "origin": "512 384 0"]
            objects[0].merge(fields) { _, next in next }
            objects.insert(["id": 2, "image": "models/util/solidlayer.json", "size": "200 100",
                            "origin": "300 200 0", "color": "0 0 1", "alpha": 1], at: 0)
            json["objects"] = objects
            let fixture = try await makeSyntheticRenderer(effect: false, scene: JSONSerialization.data(withJSONObject: json),
                                                          alignment: WPEParityCameraAlignment(mode: 0))
            let renderer = fixture.renderer
            try await encode(renderer, label: "cursor box \(anchor)")

            let text = try XCTUnwrap(renderer.texts[Self.textID])
            let mesh = try XCTUnwrap(text.layout.mesh)
            XCTAssertNotEqual(text.layout.blockOffset.x, 0, "a left-aligned block must shift off the origin")
            let anchorOffset = WPEParityTextMatrices.anchorOffset(text.object.anchor,
                                                                  margins: renderer.pathCamera.cropMargins,
                                                                  orthographic: true)
            XCTAssertEqual(anchorOffset == .zero, anchor == "none", "\(anchor) offset \(anchorOffset)")
            let operation = try XCTUnwrap(renderer.frames[0].draws.first { _, draw in
                guard case let .scene(scene) = draw else { return false }
                return scene.objectID == Self.textID && scene.geometry == .textGlyphs(.mono)
            }?.key)
            let mvp = try XCTUnwrap(renderer.uniforms(operation)).matrices.modelViewProjection
            let blockCentre = SIMD2<Float>(mesh.minX + mesh.maxX, mesh.bottom + mesh.top) * 0.5
            let clip: SIMD4<Float> = mvp * SIMD4(blockCentre.x, blockCentre.y, 0, 1)
            let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
            let drawn = SIMD2<Float>((ndc.x + 1) * 0.5, (1 - ndc.y) * 0.5) * SIMD2(Float(Self.width), Float(Self.height))
            let corners = try XCTUnwrap(renderer.cursorQuad(Self.textID, camera: renderer.pathCamera))
            let centre = (corners.0 + corners.1 + corners.2 + corners.3) / 4
            XCTAssertLessThan(simd_distance(centre, drawn), 0.01, "\(anchor): cursor box \(centre), glyph block \(drawn)")

            // The image spans canvas (200...400, 150...250); the visible canvas rows are 128...640.
            let image = try XCTUnwrap(renderer.cursorQuad("2", camera: renderer.pathCamera))
            let expected: [SIMD2<Float>] = [SIMD2(200, 490), SIMD2(400, 490), SIMD2(400, 390), SIMD2(200, 390)]
            for (actual, wanted) in zip([image.0, image.1, image.2, image.3], expected) {
                XCTAssertLessThan(simd_distance(actual, wanted), 0.01, "\(anchor): image corner \(actual), want \(wanted)")
            }
        }
    }

    /// FUN_1401e5b60 pushes onto the parent's composite camera before slot30 draws text. At FOV90, a 1024x512
    /// composite gives D=256; z=128 doubles the glyphs around pixel(256,384), versus the ortho(896,64).
    func testPerspectiveTextInParentCompositeUsesThePushedCameraOnce() async throws {
        let fixture = try await makeCompositeTextRenderer(effect: false)
        let renderer = fixture.renderer
        XCTAssertEqual(renderer.skipped, [:])
        let text = try sceneText(fixture.plan)
        let mesh = try XCTUnwrap(text.layout.mesh)
        let operation = try XCTUnwrap(fixture.plan.frames[0].draws.first { _, draw in
            guard case let .scene(scene) = draw else { return false }
            return scene.objectID == Self.textID && scene.geometry == .textGlyphs(.mono)
        })
        guard case let .scene(description) = operation.value else { return XCTFail("not a text draw") }
        XCTAssertEqual(description.compositeOwnerID, "1")
        XCTAssertFalse(description.fillsComposite)
        XCTAssertEqual(fixture.plan.programs[operation.key]?.shader, "font")
        let target = try XCTUnwrap(renderer.targets[description.target])
        XCTAssertEqual([target.width, target.height], [1024, 512])
        let glyphOffset = SIMD2(-(mesh.maxX - mesh.minX) * 0.5 - min(mesh.minX, 0),
                                (mesh.top - mesh.bottom) * 0.5 - mesh.top) + text.layout.blockOffset
        let creations = renderer.pipelineCreations
        var firstDraw: WPEParityDraw?
        for perspective in [true, false, true] {
            renderer.state.setScriptField("perspective", of: Self.textID,
                                          to: .vector(SIMD4(perspective ? 1 : 0, 0, 0, 0)), invalidating: .none)
            try await encode(renderer, label: "child perspective=\(perspective)")
            let draw = try textDraw(renderer, geometry: .textGlyphs(.mono))
            let matrices = try XCTUnwrap(renderer.uniforms(operation.key)).matrices
            // The owner's rotated/scaled world chain cancels once; only the child's local translation remains.
            let translation = SIMD4(384 + glyphOffset.x, 192 + glyphOffset.y, 128, 1)
            XCTAssertLessThanOrEqual(simd_reduce_max(abs(matrices.model.columns.3 - translation)), 0.001)
            XCTAssertLessThanOrEqual(simd_reduce_max(abs(matrices.model.columns.0 - SIMD4(1, 0, 0, 0))), 0.001)
            let expectedView = perspective ? SIMD4<Float>(-512, -256, -256, 1) : SIMD4(0, 0, 0, 1)
            XCTAssertLessThanOrEqual(simd_reduce_max(abs(matrices.view.columns.3 - expectedView)), 0.001)
            XCTAssertEqual(matrices.projection.columns.2.w, perspective ? -1 : 0)
            let points = mesh.mono.vertices.map { vertex in
                let local = SIMD2(vertex.x, vertex.y) + glyphOffset
                // Independent native projection arithmetic, without production camera/MVP helpers.
                return perspective ? SIMD2(256 + 2 * local.x, 384 - 2 * local.y)
                    : SIMD2(896 + local.x, 64 - local.y)
            }
            _ = try assertTextInk(in: target, points: points, fixture: fixture)
            try assertParentPublication(fixture)
            let presented = try readBack(renderer.backbuffer, fixture)
            XCTAssertTrue(stride(from: 0, to: presented.count, by: 4).contains { presented[$0] > 0 },
                          "the parent's real tint pass must publish its glyph pixels")
            if let firstDraw {
                XCTAssertTrue(draw.vertexBuffer === firstDraw.vertexBuffer)
                XCTAssertTrue(draw.pipeline.state === firstDraw.pipeline.state)
                let atlas = try XCTUnwrap(draw.textures["g_Texture0"])
                let initialAtlas = try XCTUnwrap(firstDraw.textures["g_Texture0"])
                XCTAssertTrue(atlas === initialAtlas)
            } else {
                firstDraw = draw
            }
            XCTAssertEqual(renderer.pipelineCreations, creations)
        }
    }

    /// slot29 always fills the text's own FBO with V=I and its extent's ortho, even when its final composite
    /// publishes through a perspective camera. An opaque black background isolates this from slot28's snapshot.
    func testPerspectiveTextOwnFBOGlyphsKeepTheFillCamera() async throws {
        let fixture = try await makeCompositeTextRenderer(effect: true)
        let renderer = fixture.renderer
        XCTAssertEqual(renderer.skipped, [:])
        let text = try sceneText(fixture.plan)
        let mesh = try XCTUnwrap(text.layout.mesh)
        let operation = try XCTUnwrap(fixture.plan.frames[0].draws.first { _, draw in
            guard case let .scene(scene) = draw else { return false }
            return scene.objectID == Self.textID && scene.geometry == .textGlyphs(.mono) && scene.fillsComposite
        })
        guard case let .scene(description) = operation.value else { return XCTFail("not an FBO glyph draw") }
        XCTAssertEqual(fixture.plan.programs[operation.key]?.shader, "font")
        let target = try XCTUnwrap(renderer.targets[description.target])
        XCTAssertEqual(SIMD2(target.width, target.height), text.layout.fboSize)
        let offset = SIMD2(text.padding.x - min(mesh.minX, 0), text.padding.y - mesh.bottom)
        let points = mesh.mono.vertices.map { SIMD2($0.x + offset.x, Float(target.height) - $0.y - offset.y) }
        var firstPixels: [UInt8]?
        var firstPresented: [UInt8]?
        for perspective in [true, false] {
            renderer.state.setScriptField("perspective", of: Self.textID,
                                          to: .vector(SIMD4(perspective ? 1 : 0, 0, 0, 0)), invalidating: .none)
            try await encode(renderer, label: "FBO child perspective=\(perspective)")
            _ = try textDraw(renderer, geometry: .textGlyphs(.mono))
            let matrices = try XCTUnwrap(renderer.uniforms(operation.key)).matrices
            XCTAssertEqual(matrices.view, matrix_identity_float4x4)
            XCTAssertEqual(matrices.projection.columns.2.w, 0)
            XCTAssertEqual(matrices.projection.columns.0.x, 2 / Float(target.width), accuracy: 0.00001)
            XCTAssertEqual(matrices.projection.columns.1.y, 2 / Float(target.height), accuracy: 0.00001)
            XCTAssertEqual(matrices.model.columns.3, SIMD4(offset.x, offset.y, 0, 1))
            let pixels = try assertTextInk(in: target, points: points, fixture: fixture)
            try assertParentPublication(fixture)
            let presented = try readBack(renderer.backbuffer, fixture)
            XCTAssertTrue(stride(from: 0, to: presented.count, by: 4).contains { presented[$0] > 0 })
            if let firstPixels, let firstPresented {
                XCTAssertTrue(pixels == firstPixels, "perspective belongs to publication, never the glyph FBO fill")
                XCTAssertTrue(presented != firstPresented, "the actual final composite still consumes perspective")
            } else {
                firstPixels = pixels
                firstPresented = presented
            }
        }
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
            try XCTUnwrap(renderer.lastFrameDraws.first?.draw.values(for: .fragment))
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
        XCTAssertFalse(fixture.plan.loadPrograms.contains { program in
            program.shader == "font" && program.combos.contains { $0.name == "MSDF" && $0.value == "1" }
        }, "Ordinary bitmap text must not precompile field variants")
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

        // Transport inputs exercise the existing COLOR owner/uploader, not a generated algorithm golden.
        // The original bitmap reader guard above remains; each pair below adds full-plane GPU witnesses.
        func pair(scale: Int, seed: UInt8) -> WPEParityColorGlyphField {
            let primary = WPEParityGlyphBitmap(width: 2, rows: 2, pixelMode: .rgba,
                                               pixels: Array(repeating: seed, count: 16))
            let field = WPEParityGlyphField(bitmap: primary, box: .init(xMin: 0, yMin: 0, xMax: 32 * Int32(scale), yMax: 30 * Int32(scale)),
                                            yPpem: 32 * scale, isColor: true,
                                            transform: .init(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0,
                                                             distanceScale: 1, distanceOffset: 0),
                                            beforeCorrection: [], afterCorrection: [])
            return WPEParityColorGlyphField(primary: field,
                                            companion: .init(width: 2 * scale, rows: 2 * scale, pixelMode: .rgba,
                                                             pixels: Array(repeating: seed + 19, count: 16 * scale * scale)),
                                            companionScale: scale)
        }
        for scale in [1, 2] {
            var color = WPEParityGlyphAtlasInstance(fontPath: "paired-readers-\(scale)", pointSize: 32, glyphMode: .distanceField)
            _ = try XCTUnwrap(color.insertColorField(key: 1, field: pair(scale: scale, seed: 37)))
            color.colorGroups[scale]?.retain([1])
            var paired = WPEParityTextAtlasTextures(atlases: [:])
            XCTAssertTrue(paired.replace([color.key: color], device: device))
            let baseline = try XCTUnwrap(paired.atlases[color.key])
            let group = try XCTUnwrap(baseline.colorGroups[scale])
            let primaryKey = WPEParityTextAtlasTextures.Key(atlasKey: color.key, atlas: .color, colorScale: scale, plane: .primary)
            let companionKey = WPEParityTextAtlasTextures.Key(atlasKey: color.key, atlas: .color, colorScale: scale, plane: .companion)
            let planes: [(key: WPEParityTextAtlasTextures.Key, pixels: [UInt8], factor: Int)] = try [
                (primaryKey, group.pixels, 1), (companionKey, XCTUnwrap(group.companionPixels), scale),
            ]
            let oldIDs = paired.textures.mapValues(ObjectIdentifier.init), oldGenerations = paired.contentGenerations
            let release = try XCTUnwrap(device.makeSharedEvent())
            defer { release.signaledValue = 1 }
            let reader = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(reader.retainedReferences)
            reader.encodeWaitForEvent(release, value: 1)
            let blit = try XCTUnwrap(reader.makeBlitCommandEncoder())
            var oldReads: [(buffer: MTLBuffer, expected: [UInt8])] = []
            for plane in planes {
                let texture = try XCTUnwrap(paired.textures[plane.key])
                XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
                XCTAssertEqual([texture.width, texture.height, texture.mipmapLevelCount], [512 * plane.factor, 512 * plane.factor, 1])
                XCTAssertEqual(paired.contentGenerations[plane.key], group.contentGeneration)
                let stride = texture.width * 4
                let buffer = try XCTUnwrap(device.makeBuffer(length: stride * texture.height, options: .storageModeShared))
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                          destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
                oldReads.append((buffer, plane.pixels))
            }
            blit.endEncoding()
            reader.commit()
            XCTAssertNotEqual(reader.status, .completed)

            color = baseline
            _ = try XCTUnwrap(color.insertColorField(key: 2, field: pair(scale: scale, seed: 101)))
            let changed = try XCTUnwrap(color.colorGroups[scale])
            XCTAssertTrue(changed.isDirty)
            XCTAssertGreaterThan(changed.contentGeneration, group.contentGeneration)
            var primaryAllocations = 0, companionFailures = 0
            XCTAssertFalse(paired.replace([color.key: color], device: device, makeTexture: { key, descriptor in
                if key == companionKey {
                    companionFailures += 1
                    XCTAssertEqual(primaryAllocations, 1, "The target pair's primary really allocated first")
                    return nil
                }
                let texture = device.makeTexture(descriptor: descriptor)
                if key == primaryKey {
                    primaryAllocations += 1
                    XCTAssertNotNil(texture)
                }
                return texture
            }))
            XCTAssertEqual(primaryAllocations, 1)
            XCTAssertEqual(companionFailures, 1)
            XCTAssertEqual(paired.textures.mapValues(ObjectIdentifier.init), oldIDs, "Neither plane may partially publish")
            XCTAssertEqual(paired.contentGenerations, oldGenerations)
            let rejected = try XCTUnwrap(paired.atlases[color.key])
            XCTAssertEqual(Set(paired.atlases.keys), [color.key])
            XCTAssertEqual(Set(rejected.colorGroups.keys), Set(baseline.colorGroups.keys))
            assertTextAtlasState(paired.atlases, equals: [color.key: baseline], texts: [])
            let rejectedGroup = try XCTUnwrap(rejected.colorGroups[scale])
            XCTAssertEqual([rejectedGroup.width, rejectedGroup.height, rejectedGroup.companionScale ?? 0], [group.width, group.height, scale])
            XCTAssertEqual(rejectedGroup.pixels, group.pixels)
            XCTAssertEqual(rejectedGroup.companionPixels, group.companionPixels)
            XCTAssertEqual(rejectedGroup.isDirty, group.isDirty)
            XCTAssertEqual(rejectedGroup.generation, group.generation)
            XCTAssertEqual(rejectedGroup.contentGeneration, group.contentGeneration)
            XCTAssertEqual(rejectedGroup.resetGeneration, group.resetGeneration)
            XCTAssertEqual(rejectedGroup.entry(forKey: 1), group.entry(forKey: 1))
            XCTAssertNil(rejectedGroup.entry(forKey: 2))
            XCTAssertFalse(group.isDirty, "Baseline was actually uploaded before failure")
            XCTAssertTrue(color.colorGroups[scale]?.isDirty == true, "The caller's failed candidate stays retryable")
            XCTAssertNotEqual(reader.status, .completed)

            var malformed = color
            malformed.colorGroups[scale] = WPEParityGlyphAtlas(format: .rgba8)
            XCTAssertFalse(paired.replace([malformed.key: malformed], device: device), "A field group must not omit its companion")
            XCTAssertEqual(paired.textures.mapValues(ObjectIdentifier.init), oldIDs)
            XCTAssertEqual(paired.contentGenerations, oldGenerations)
            assertTextAtlasState(paired.atlases, equals: [color.key: baseline], texts: [])
            let afterMalformed = try XCTUnwrap(paired.atlases[color.key]?.colorGroups[scale])
            XCTAssertEqual(afterMalformed.pixels, group.pixels)
            XCTAssertEqual(afterMalformed.companionPixels, group.companionPixels)
            XCTAssertEqual(afterMalformed.isDirty, group.isDirty)
            XCTAssertEqual(afterMalformed.contentGeneration, group.contentGeneration)
            XCTAssertEqual(afterMalformed.entry(forKey: 1), group.entry(forKey: 1))

            XCTAssertTrue(paired.replace([color.key: color], device: device))
            let recovered = try XCTUnwrap(paired.atlases[color.key]?.colorGroups[scale])
            XCTAssertFalse(recovered.isDirty)
            XCTAssertEqual(recovered.contentGeneration, changed.contentGeneration)
            for (key, expected, factor) in try [(primaryKey, changed.pixels, 1), (companionKey, XCTUnwrap(changed.companionPixels), scale)] {
                let texture = try XCTUnwrap(paired.textures[key])
                XCTAssertNotEqual(ObjectIdentifier(texture), oldIDs[key])
                XCTAssertEqual([texture.width, texture.height, texture.mipmapLevelCount], [512 * factor, 512 * factor, 1])
                XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
                XCTAssertEqual(paired.contentGenerations[key], changed.contentGeneration)
                // Shared texture CPU read avoids enqueueing behind the intentionally blocked GPU reader.
                var bytes = [UInt8](repeating: 0, count: expected.count)
                texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
                XCTAssertEqual(bytes, expected)
            }
            let recoveredIDs = paired.textures.mapValues(ObjectIdentifier.init)
            XCTAssertTrue(paired.upload(device: device))
            XCTAssertEqual(paired.textures.mapValues(ObjectIdentifier.init), recoveredIDs, "Both clean plane versions reuse their textures")
            XCTAssertNotEqual(reader.status, .completed, "Old pair readers overlap both failure and successful replacement")
            release.signaledValue = 1
            await reader.completed()
            XCTAssertNil(reader.error)
            for read in oldReads {
                XCTAssertEqual(Array(UnsafeRawBufferPointer(start: read.buffer.contents(), count: read.expected.count)), read.expected,
                               "Each old GPU reader retains its complete earlier plane, including empty cells")
            }
        }
    }

    /// Authored effects enter the real mono font material; original GLSL compiles, consumes all four RVs and
    /// presents changed outline/shadow pixels without replacing a parameter-only update's field texture/mesh.
    func testRequestedMonoFieldsConsumeOriginalShaderRVsAndKeepParameterOnlyResources() async throws {
        let assets: URL
        do { assets = try wpeAssets() } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(domain: "WPEParityMono.RequiredInputs", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
        }
        for (path, expected) in [
            ("shaders/font.frag", "d9f4e7198e2cc417c50a62d65e7dd2a654a13657b4d61df358bb1c016d4d7b26"),
            ("shaders/font.vert", "8b337706d01a9a7ee5919c3cd3e489190d753e26e191e68b4014cb732c26f944"),
            ("materials/fonts/basefont_msdf.json", "50bbde8eb0424fdb36aa02d61ab8ae36dff70d99da78955f599ff372303e7dee"),
            ("fonts/NotoSans-Regular.ttf", "6b04c8dd65af6b73eb4279472ed1580b29102d6496a377340e80a40cdb3b22c9"),
        ] {
            let bytes = try Data(contentsOf: assets.appending(path: path))
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected, path)
        }
        for effect in [false, true] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: effect, text: "H")) as? [String: Any])
            var object = try XCTUnwrap((json["objects"] as? [[String: Any]])?.first)
            object["pointsize"] = 8
            object["outline"] = true; object["outlinethickness"] = 2; object["outlinecolor"] = "1 0 0"
            object["blur"] = true; object["blursize"] = 0.1
            object["dropshadow"] = true; object["dropshadowcolor"] = "0 0 1"
            object["dropshadowsize"] = 1; object["dropshadowopacity"] = 1; object["dropshadowoffset"] = "5 -4"
            if effect {
                // Original tint defaults to full red tint (BlendTint=maxRGB*red). Its authored alpha=0
                // preserves the font's RGB while retaining the real effect/FBO/publication path.
                var effects = try XCTUnwrap(object["effects"] as? [[String: Any]])
                effects[0]["passes"] = [["constantshadervalues": ["alpha": 0]]]
                object["effects"] = effects
            }
            json["objects"] = [object]
            let beforeJSON = try JSONSerialization.data(withJSONObject: json)
            let fixture: Fixture
            do { fixture = try await makeSyntheticRenderer(effect: effect, scene: beforeJSON) } catch {
                throw TestScratch.requiredInputError(error, failure: NSError(domain: "WPEParityMono.RequiredInputs", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
            }
            let renderer = fixture.renderer
            let warmed = fixture.plan.loadPrograms.filter {
                $0.shader == "font" && $0.combos.contains { $0.name == "MSDF" && $0.value == "1" }
                    && !$0.combos.contains { $0.name == "COLORFONT" && $0.value == "1" }
            }
            XCTAssertGreaterThan(warmed.count, 0)
            XCTAssertLessThanOrEqual(warmed.count, 16, "Existing HLSL view deduplicates the finite mono source variants")
            XCTAssertFalse(fixture.plan.loadPrograms.contains {
                $0.combos.contains { $0.name == "MSDF" && $0.value == "1" }
                    && $0.combos.contains { $0.name == "COLORFONT" && $0.value == "1" }
            }, "The resolved Noto primary cannot admit COLOR fields through fallback")
            print("mono authored effect=\(effect): unique field HLSL compile requests=\(warmed.count); all programs=\(fixture.plan.loadPrograms.count)")
            try await encode(renderer, label: "mono initial effect=\(effect)")
            XCTAssertTrue(renderer.skipped.isEmpty)
            let before = renderer.textPreparationState
            let text = try XCTUnwrap(before.texts[Self.textID])
            let mesh = try XCTUnwrap(text.layout.mesh)
            XCTAssertEqual(mesh.glyphMode, .distanceField)
            let key = WPEParityTextAtlasTextures.Key(atlasKey: text.atlasKey, atlas: .mono)
            let texture = try XCTUnwrap(before.atlases.textures[key])
            XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
            let entry = try XCTUnwrap(before.atlases.atlases[text.atlasKey]?.mono.entry(forKey: 43))
            XCTAssertEqual([entry.x0, entry.y0, entry.x1, entry.y1], [0, 0, 42, 47], "Original qualified H/33ppem cell dimensions")
            let first = try textDraw(renderer, geometry: .textGlyphs(.mono))
            let writes = try XCTUnwrap(text.fieldParameters)
            try assertFontRVConstants(first, expected: writes)
            let target = try XCTUnwrap(before.frames[0].draws.first { _, draw in
                if case let .scene(scene) = draw {
                    return scene.objectID == Self.textID && scene.geometry == .textGlyphs(.mono)
                }
                return false
            }.flatMap { _, draw -> MTLTexture? in
                if case let .scene(scene) = draw {
                    return before.targets[scene.target]
                }
                return nil
            })
            let initial = try readBack(target, fixture)
            XCTAssertGreaterThan(stride(from: 0, to: initial.count, by: 4).count { Int(initial[$0]) > Int(initial[$0 + 1]) + 30 }, 0,
                                 "Actual outline RGB must reach the original font shader")
            let blueBefore = stride(from: 0, to: initial.count, by: 4).count {
                Int(initial[$0 + 2]) > max(Int(initial[$0]), Int(initial[$0 + 1])) + 30
            }
            XCTAssertGreaterThan(blueBefore, 0, "RV2 shadow colour and RV3 opacity must affect actual pixels")
            object["outlinecolor"] = "0 1 0"; object["dropshadowopacity"] = 0
            json["objects"] = [object]
            let changed = try Self.parse(JSONSerialization.data(withJSONObject: json))
            let update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: Self.parse(beforeJSON), to: changed))
            try renderer.applyUserProperties(update)
            try await encode(renderer, label: "mono parameter only effect=\(effect)")
            let after = renderer.textPreparationState
            let current = try XCTUnwrap(after.texts[Self.textID])
            XCTAssertEqual(current.layout, text.layout)
            XCTAssertTrue(after.atlases.textures[key] === texture)
            XCTAssertEqual(after.atlases.contentGenerations, before.atlases.contentGenerations)
            let emitted = try textDraw(renderer, geometry: .textGlyphs(.mono))
            XCTAssertTrue(emitted.vertexBuffer === first.vertexBuffer)
            XCTAssertTrue(emitted.indexBuffer === first.indexBuffer)
            XCTAssertTrue(emitted.pipeline.state === first.pipeline.state)
            try assertFontRVConstants(emitted, expected: XCTUnwrap(current.fieldParameters))
            let pixels = try readBack(target, fixture)
            XCTAssertNotEqual(pixels, initial, "Live four-RV update must change actual GPU pixels")
            XCTAssertGreaterThan(stride(from: 0, to: pixels.count, by: 4).count { Int(pixels[$0 + 1]) > Int(pixels[$0]) + 30 }, 0)
            let blueAfter = stride(from: 0, to: pixels.count, by: 4).count {
                Int(pixels[$0 + 2]) > max(Int(pixels[$0]), Int(pixels[$0 + 1])) + 30
            }
            XCTAssertEqual(blueAfter, 0, "RV3.x=0 removes the real blue shadow while the green outline remains")
            XCTAssertTrue(renderer.lastFrameDraws.contains { $0.draw.textures["g_Texture0"] === texture })
            let presented = try readBack(renderer.backbuffer, fixture)
            printTextPixels(initial, in: target, label: "mono effect=\(effect) initial font target")
            printTextPixels(pixels, in: target, label: "mono effect=\(effect) updated font target")
            printTextPixels(presented, in: renderer.backbuffer, label: "mono effect=\(effect) publication")
            for (operation, description) in after.frames[0].draws.sorted(by: { $0.key < $1.key }).prefix(8) {
                guard case let .scene(scene) = description, scene.objectID == Self.textID else { continue }
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
                let source = draw.textures["g_Texture0"]
                print("mono effect=\(effect) op=\(operation) geometry=\(scene.geometry) effectID=\(scene.effectID ?? "none") "
                    + "target=\(scene.target.rawValue) source=\(source.map { "\($0.width)x\($0.height)" } ?? "none") "
                    + "tint=\(String(describing: draw.constants[.fragment]?["g_TintColor"])) "
                    + "blendAlpha=\(String(describing: draw.constants[.fragment]?["g_BlendAlpha"]))")
                if scene.effectID == "7" {
                    guard case let .float(alpha)? = draw.constants[.fragment]?["g_BlendAlpha"] else {
                        return XCTFail("Real tint pass must consume authored passthrough alpha")
                    }
                    XCTAssertEqual(alpha, 0)
                }
            }
            XCTAssertTrue(stride(from: 0, to: presented.count, by: 4).contains { presented[$0 + 1] > 0 })

            // The field atlas key carries no size, so 8 -> 32 reuses the loaded H field and its texture.
            object["pointsize"] = 32
            json["objects"] = [object]
            let resized = try Self.parse(JSONSerialization.data(withJSONObject: json))
            try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: changed, to: resized)))
            try await encode(renderer, label: "mono 8 to 32 effect=\(effect)")
            let stable = renderer.textPreparationState
            XCTAssertEqual(stable.pendingRequests, 0)
            XCTAssertEqual(stable.texts[Self.textID]?.object.pointSize, 32)
            XCTAssertEqual(stable.texts[Self.textID]?.atlasKey, text.atlasKey)
            XCTAssertTrue(stable.atlases.textures[key] === texture)
            XCTAssertEqual(stable.atlases.contentGenerations, before.atlases.contentGenerations)
            XCTAssertTrue(renderer.skipped.isEmpty)
            let resizedPixels = try readBack(renderer.backbuffer, fixture)
            XCTAssertNotEqual(resizedPixels, presented, "The 32 pt layout must actually render")

            // A failed fallback-face cohort must not poison a later legal input with its old request prefix.
            var invalidObject = object
            invalidObject["text"] = "H你"
            var invalidJSON = json
            invalidJSON["objects"] = [invalidObject]
            let invalid = try Self.parse(JSONSerialization.data(withJSONObject: invalidJSON))
            try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: resized, to: invalid)))
            XCTAssertThrowsError(try renderer.encodeFrame(elapsed: 1.0 / 60)) { error in
                XCTAssertEqual(error as? WPEParityTextPreparationError, .unqualifiedDistanceFieldGroup)
            }
            let rejected = renderer.textPreparationState
            XCTAssertGreaterThan(rejected.pendingRequests, 0)
            XCTAssertEqual(rejected.texts, stable.texts)
            XCTAssertEqual(rejected.frames, stable.frames)
            XCTAssertEqual(rejected.layers.layers, stable.layers.layers)
            XCTAssertEqual(rejected.executorIDs, stable.executorIDs)
            XCTAssertEqual(textGeometryIdentities(rejected), textGeometryIdentities(stable))
            XCTAssertEqual(rejected.atlases.textures.mapValues(ObjectIdentifier.init), stable.atlases.textures.mapValues(ObjectIdentifier.init))
            XCTAssertEqual(rejected.targets.mapValues(ObjectIdentifier.init), stable.targets.mapValues(ObjectIdentifier.init))
            XCTAssertEqual(try readBack(renderer.backbuffer, fixture), resizedPixels)
            object["text"] = "HH" // A real new legal layout rather than a discarded retry.
            json["objects"] = [object]
            let corrected = try Self.parse(JSONSerialization.data(withJSONObject: json))
            try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: invalid, to: corrected)))
            try await encode(renderer, label: "mono rejected fallback then corrected input effect=\(effect)")
            let recovered = renderer.textPreparationState
            XCTAssertEqual(recovered.pendingRequests, 0)
            XCTAssertEqual(recovered.texts[Self.textID]?.object.text, "HH")
            XCTAssertEqual(recovered.texts[Self.textID]?.object.pointSize, 32)
            XCTAssertTrue(recovered.atlases.textures[key] === texture, "Correction reuses actual H fields")
            XCTAssertTrue(renderer.skipped.isEmpty)
            XCTAssertNotEqual(try readBack(renderer.backbuffer, fixture), resizedPixels, "Legal correction must actually render")
        }
    }

    /// Original COLOR shaders consume the paired atlas at both qualified physical scales. This verifies
    /// Mac product consumption and parameter reuse, not a Windows GPU pixel comparison.
    func testColorFieldsConsumePairedOriginalShaderTextures() async throws {
        let assets = try wpeAssets()
        let font = try Data(contentsOf: assets.appending(path: "fonts/TwemojiMozilla.ttf"))
        XCTAssertEqual(SHA256.hash(data: font).map { String(format: "%02x", $0) }.joined(),
                       "063b2a145c2331e1aede451242b5107a0f29a44d782fdb24a6adb9754dc48d14")
        for (path, expected) in [
            ("shaders/font.frag", "d9f4e7198e2cc417c50a62d65e7dd2a654a13657b4d61df358bb1c016d4d7b26"),
            ("shaders/font.vert", "8b337706d01a9a7ee5919c3cd3e489190d753e26e191e68b4014cb732c26f944"),
            ("materials/fonts/basefontrgba_msdf.json", "66f3e264b1f7a7b401ba44cbd693520da065046c7e7dbb7894d7e67d787e12cc"),
        ] {
            let bytes = try Data(contentsOf: assets.appending(path: path))
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected, path)
        }
        for (pointSize, scale) in [(7.68, 1), (15.36, 2)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: false, text: "❤")) as? [String: Any])
            var object = try XCTUnwrap((json["objects"] as? [[String: Any]])?.first)
            object["font"] = "fonts/TwemojiMozilla.ttf"; object["pointsize"] = pointSize; object["msdf"] = true
            object["outline"] = true; object["outlinethickness"] = 1; object["outlinecolor"] = "0 1 0"
            object["blur"] = true; object["blursize"] = 0.1
            object["dropshadow"] = true; object["dropshadowcolor"] = "0 0 1"
            object["dropshadowsize"] = 1; object["dropshadowopacity"] = 1; object["dropshadowoffset"] = "5 -4"
            json["objects"] = [object]
            let initialJSON = try JSONSerialization.data(withJSONObject: json)
            let fixture = try await makeSyntheticRenderer(effect: false, scene: initialJSON)
            let renderer = fixture.renderer
            let warmed = fixture.plan.loadPrograms.filter {
                $0.shader == "font" && $0.combos.contains { $0.name == "MSDF" && $0.value == "1" }
                    && $0.combos.contains { $0.name == "COLORFONT" && $0.value == "1" }
            }
            XCTAssertGreaterThan(warmed.count, 0)
            XCTAssertLessThanOrEqual(warmed.count, 16, "COLOR variants share the existing HLSL dedup view")
            try await encode(renderer, label: "COLOR scale\(scale) initial")
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            let before = renderer.textPreparationState
            let text = try XCTUnwrap(before.texts[Self.textID])
            let mesh = try XCTUnwrap(text.layout.mesh)
            XCTAssertEqual(mesh.glyphMode, .distanceField)
            XCTAssertEqual(mesh.colorAtlasScale, scale)
            XCTAssertEqual(mesh.fieldPrimaryFaceIsColor, true)
            XCTAssertTrue(mesh.mono.glyphKeys.isEmpty)
            XCTAssertEqual(mesh.color.glyphKeys, [166])
            let group = try XCTUnwrap(before.atlases.atlases[text.atlasKey]?.colorGroups[scale])
            let primaryKey = WPEParityTextAtlasTextures.Key(atlasKey: text.atlasKey, atlas: .color, colorScale: scale)
            let companionKey = WPEParityTextAtlasTextures.Key(atlasKey: text.atlasKey, atlas: .color,
                                                              colorScale: scale, plane: .companion)
            let primary = try XCTUnwrap(before.atlases.textures[primaryKey])
            let companion = try XCTUnwrap(before.atlases.textures[companionKey])
            XCTAssertEqual(SIMD2(primary.width, primary.height), SIMD2(group.width, group.height))
            XCTAssertEqual(SIMD2(companion.width, companion.height), SIMD2(group.width * scale, group.height * scale))
            XCTAssertEqual(try readBack(primary, fixture), group.pixels)
            XCTAssertEqual(try readBack(companion, fixture), try XCTUnwrap(group.companionPixels))
            let draw = try textDraw(renderer, geometry: .textGlyphs(.color))
            XCTAssertTrue(draw.textures["g_Texture0"] === primary)
            XCTAssertTrue(draw.textures["g_Texture1"] === companion)
            try assertFontRVConstants(draw, expected: XCTUnwrap(text.fieldParameters))
            let initial = try readBack(renderer.backbuffer, fixture)
            XCTAssertGreaterThan(stride(from: 0, to: initial.count, by: 4).count {
                Int(initial[$0]) > max(Int(initial[$0 + 1]), Int(initial[$0 + 2])) + 30
            }, 0, "Original COLOR shader must preserve actual red heart pixels")
            object["outlinecolor"] = "0 0 1"; json["objects"] = [object]
            let changed = try Self.parse(JSONSerialization.data(withJSONObject: json))
            try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: Self.parse(initialJSON), to: changed)))
            try await encode(renderer, label: "COLOR scale\(scale) parameter only")
            let after = renderer.textPreparationState
            XCTAssertEqual(after.texts[Self.textID]?.layout, text.layout)
            XCTAssertTrue(after.atlases.textures[primaryKey] === primary)
            XCTAssertTrue(after.atlases.textures[companionKey] === companion)
            XCTAssertEqual(after.atlases.contentGenerations, before.atlases.contentGenerations)
            let current = try textDraw(renderer, geometry: .textGlyphs(.color))
            XCTAssertTrue(current.vertexBuffer === draw.vertexBuffer)
            XCTAssertTrue(current.indexBuffer === draw.indexBuffer)
            XCTAssertTrue(current.pipeline.state === draw.pipeline.state)
            XCTAssertTrue(current.textures["g_Texture0"] === primary)
            XCTAssertTrue(current.textures["g_Texture1"] === companion)
            try assertFontRVConstants(current, expected: XCTUnwrap(after.texts[Self.textID]?.fieldParameters))
            XCTAssertNotEqual(try readBack(renderer.backbuffer, fixture), initial, "Live COLOR RV change must affect actual pixels")
        }
    }

    private func assertFontRVConstants(_ draw: WPEParityDraw, expected: WPEParityTextDrawParameters) throws {
        let values = [expected.renderVar0, expected.renderVar1, expected.renderVar2, SIMD4(expected.renderVar3X, 0, 0, 0)]
        for (index, expected) in values.enumerated() {
            let name = "g_RenderVar\(index)"
            let layout = try XCTUnwrap(draw.pipeline.fragment.cbuffers.first { $0[name] != nil }, "Real compiled fragment reflection: \(name)")
            let value = try XCTUnwrap(draw.constants[.fragment]?[name], "Actual emitted draw constant: \(name)")
            var pack = WPECBufferPacker(layout: layout)
            try pack.write(value, to: name)
            let offset = try XCTUnwrap(layout[name]).offset
            guard offset <= pack.bytes.count - 16 else { return XCTFail("Required four-lane RV layout: \(name)") }
            for lane in 0 ..< 4 {
                let base = offset + lane * 4
                let bits = UInt32(pack.bytes[base]) | UInt32(pack.bytes[base + 1]) << 8
                    | UInt32(pack.bytes[base + 2]) << 16 | UInt32(pack.bytes[base + 3]) << 24
                XCTAssertEqual(bits, expected[lane].bitPattern, "\(name)[\(lane)] CBuffer")
            }
        }
    }

    /// All allocations/uploads/graph initialization are real Metal. Only the final admission failure is
    /// injected; the old reader waits on a separate queue so candidate initialization cannot deadlock behind it.
    func testTextBatchPreparationFailureKeepsPublishedCohortAndRTContents() async throws {
        enum Injected: Error { case beforeAccept }
        let fixture = try await makeTextAdmissionFixture()
        let renderer = fixture.renderer
        try await encode(renderer, label: "text admission baseline")
        XCTAssertTrue(renderer.skipped.isEmpty)
        let before = renderer.textPreparationState
        XCTAssertEqual(before.texts.count, 2)
        XCTAssertEqual(before.atlases.atlases.count, 1, "Both objects must actually share one atlas")
        let text = try XCTUnwrap(before.texts[Self.textID])
        let key = WPEParityTextAtlasTextures.Key(atlasKey: text.atlasKey, atlas: .mono)
        let oldAtlas = try XCTUnwrap(before.atlases.textures[key])
        let oldPixels = try XCTUnwrap(before.atlases.atlases[text.atlasKey]).mono.pixels
        XCTAssertTrue(oldPixels.contains { $0 != 0 }, "Required real glyph pixels")
        XCTAssertEqual(oldAtlas.pixelFormat, .r8Unorm)
        let historyID = try XCTUnwrap(before.frames[0].resources.first {
            $0.id.rawValue == "History_7" && $0.initialClear != nil
        }?.id)
        let history = try XCTUnwrap(before.targets[historyID])
        let seed = try XCTUnwrap(fixture.queue.makeCommandBuffer())
        try WPEParityGraphExecutor.encodeColorClear(history, color: .init(red: 1, green: 0, blue: 1, alpha: 1),
                                                    on: seed)
        seed.commit()
        await seed.completed()
        XCTAssertNil(seed.error)
        let historyPixels = try readBack(history, fixture)
        XCTAssertEqual(Array(historyPixels.prefix(4)), [255, 0, 255, 255], "Different from authored green initialClear")
        let oldPresented = try readBack(renderer.backbuffer, fixture)

        let readQueue = try XCTUnwrap(fixture.device.makeCommandQueue())
        let release = try XCTUnwrap(fixture.device.makeSharedEvent())
        defer { release.signaledValue = 1 }
        let oldRead = try XCTUnwrap(readQueue.makeCommandBuffer())
        XCTAssertTrue(oldRead.retainedReferences)
        let readStride = (oldAtlas.width + 255) / 256 * 256
        let result = try XCTUnwrap(fixture.device.makeBuffer(length: readStride * oldAtlas.height, options: .storageModeShared))
        oldRead.encodeWaitForEvent(release, value: 1)
        let blit = try XCTUnwrap(oldRead.makeBlitCommandEncoder())
        blit.copy(from: oldAtlas, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: oldAtlas.width, height: oldAtlas.height, depth: 1), to: result,
                  destinationOffset: 0, destinationBytesPerRow: readStride,
                  destinationBytesPerImage: readStride * oldAtlas.height)
        blit.endEncoding()
        oldRead.commit()
        XCTAssertNotEqual(oldRead.status, .completed)

        var candidate: WPEParityFrameRenderer.TextPreparationSnapshot?
        var hits = 0
        renderer.textPreparationCheckpoint = { snapshot in
            hits += 1
            candidate = snapshot
            throw Injected.beforeAccept
        }
        defer { renderer.textPreparationCheckpoint = nil }
        renderer.state.setScriptField("text", of: Self.textID, to: .string("WWWW"), invalidating: .textLayout)
        renderer.state.setScriptField("text", of: "6", to: .string("MMM"), invalidating: .textLayout)
        XCTAssertThrowsError(try renderer.encodeFrame(elapsed: 1.0 / 60)) { error in
            XCTAssertTrue(error is Injected, "Must reach the late checkpoint, not fail at prerequisites: \(error)")
        }
        XCTAssertEqual(hits, 1)
        let prepared = try XCTUnwrap(candidate)
        XCTAssertEqual(prepared.texts[Self.textID]?.object.text, "WWWW")
        XCTAssertEqual(prepared.texts["6"]?.object.text, "MMM")
        XCTAssertFalse(try XCTUnwrap(prepared.atlases.textures[key]) === oldAtlas, "Actual new immutable upload")
        XCTAssertNotEqual(textGeometryIdentities(prepared), textGeometryIdentities(before), "Actual new Metal buffers")
        XCTAssertNotEqual(prepared.executorIDs, before.executorIDs, "Changed FBO extent must prepare new graphs")
        XCTAssertTrue(prepared.targets[historyID] === history, "Same descriptor retains the real history object")
        XCTAssertTrue(prepared.targets.contains { id, target in
            before.targets[id].map { $0 !== target } ?? true
        }, "At least one actual new/replacement RT")
        let initialization = try XCTUnwrap(prepared.initialization, "Real added-only initialization must be submitted")
        await initialization.completed()
        XCTAssertNil(initialization.error)
        XCTAssertNotEqual(oldRead.status, .completed, "Old GPU reader must overlap candidate preparation")

        let failed = renderer.textPreparationState
        XCTAssertGreaterThan(failed.pendingRequests, 0, "Failed cohort remains retryable")
        XCTAssertEqual(failed.texts, before.texts)
        XCTAssertEqual(failed.layers.layers, before.layers.layers)
        XCTAssertEqual(failed.frames, before.frames)
        XCTAssertEqual(failed.executorIDs, before.executorIDs)
        XCTAssertEqual(failed.bindings, before.bindings)
        XCTAssertEqual(textGeometryIdentities(failed), textGeometryIdentities(before))
        XCTAssertEqual(failed.targets.mapValues(ObjectIdentifier.init), before.targets.mapValues(ObjectIdentifier.init))
        XCTAssertEqual(failed.atlases.textures.mapValues(ObjectIdentifier.init), before.atlases.textures.mapValues(ObjectIdentifier.init))
        XCTAssertEqual(failed.atlases.contentGenerations, before.atlases.contentGenerations)
        assertTextAtlasState(failed.atlases.atlases, equals: before.atlases.atlases,
                             texts: Array(before.texts.values) + Array(prepared.texts.values))
        assertTextAtlasState(failed.pipelineAtlases, equals: before.pipelineAtlases,
                             texts: Array(before.texts.values) + Array(prepared.texts.values))
        XCTAssertEqual(try readBack(history, fixture), historyPixels, "Failure must not reapply initialClear to active RT")
        XCTAssertEqual(try readBack(renderer.backbuffer, fixture), oldPresented, "Failed preparation drew nothing into old targets")

        // With no new input the same failed cohort remains retryable, without consuming its text generation.
        XCTAssertThrowsError(try renderer.encodeFrame(elapsed: 1.0 / 60)) { error in
            XCTAssertTrue(error is Injected)
        }
        XCTAssertEqual(hits, 2)
        XCTAssertEqual(candidate?.texts[Self.textID]?.object.text, "WWWW")
        XCTAssertEqual(candidate?.texts["6"]?.object.text, "MMM")
        XCTAssertEqual(renderer.textPreparationState.texts, before.texts)
        XCTAssertEqual(renderer.textPreparationState.pendingRequests, failed.pendingRequests)

        // Only the effect generation advances after the failure. The unconsumed canonical text fields
        // must be re-projected after discarding the failed prefix, rather than replacing WWWW/MMM with Hi.
        renderer.textPreparationCheckpoint = nil
        let textGeneration = renderer.state.generation(.textLayout)
        let effectsGeneration = renderer.state.effectVisibilityGeneration
        XCTAssertTrue(renderer.state.setEffect("7", of: Self.textID, visible: false))
        XCTAssertEqual(renderer.state.generation(.textLayout), textGeneration)
        XCTAssertEqual(renderer.state.effectVisibilityGeneration, effectsGeneration + 1)
        try await encode(renderer, label: "text admission recovery after effect-only input")
        let after = renderer.textPreparationState
        XCTAssertEqual(after.pendingRequests, 0)
        XCTAssertEqual(after.texts[Self.textID]?.object.text, "WWWW")
        XCTAssertEqual(after.texts["6"]?.object.text, "MMM")
        XCTAssertEqual(after.texts[Self.textID]?.effectCount, 0)
        XCTAssertEqual(after.texts["6"]?.effectCount, 1)
        XCTAssertEqual(after.layers.layers[Self.textID]?.size,
                       after.texts[Self.textID].map { SIMD2(Float($0.layout.fboSize.x), Float($0.layout.fboSize.y)) })
        XCTAssertFalse(try XCTUnwrap(after.atlases.textures[key]) === oldAtlas)
        XCTAssertTrue(after.targets[historyID] === history)
        XCTAssertEqual(try readBack(history, fixture), historyPixels, "Successful graph rebuild also preserves history")
        let presented = try readBack(renderer.backbuffer, fixture)
        XCTAssertNotEqual(presented, oldPresented)
        XCTAssertTrue(stride(from: 0, to: presented.count, by: 4).contains { presented[$0] > 0 },
                      "Actual new glyph draw must present non-background RGB pixels")
        XCTAssertTrue(renderer.skipped.isEmpty)
        for (index, description) in after.frames[0].draws {
            guard case let .scene(draw) = description, case .textGlyphs = draw.geometry else { continue }
            let emitted = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == index }?.draw)
            XCTAssertTrue(emitted.textures["g_Texture0"] === after.atlases.textures[key], "Both real consumers use the accepted atlas")
            XCTAssertEqual(emitted.indexCount, draw.objectID == Self.textID ? 24 : 18,
                           "Actual submitted quads must draw WWWW/MMM, not the old two-glyph Hi")
        }
        try await encode(renderer, label: "text admission recovered next frame")
        let next = renderer.textPreparationState
        XCTAssertEqual(next.pendingRequests, 0)
        XCTAssertEqual(next.texts, after.texts, "The recovery must not mark a discarded old text as consumed")
        XCTAssertTrue(next.atlases.textures[key] === after.atlases.textures[key])
        XCTAssertEqual(try readBack(renderer.backbuffer, fixture), presented, "Recovered glyphs remain in the real next frame")
        release.signaledValue = 1
        await oldRead.completed()
        XCTAssertNil(oldRead.error)
        var readPixels: [UInt8] = []
        for row in 0 ..< oldAtlas.height {
            readPixels += UnsafeRawBufferPointer(start: result.contents() + row * readStride, count: oldAtlas.width)
        }
        XCTAssertEqual(readPixels, oldPixels, "Old reader retains the entire earlier atlas, including areas that were empty")
    }

    /// Bounded diagnosis of already-read RGBA8 targets; no extra images, allocations or shader inputs.
    private func printTextPixels(_ pixels: [UInt8], in texture: MTLTexture, label: String) {
        guard texture.pixelFormat == .rgba8Unorm, pixels.count == texture.width * texture.height * 4 else { return }
        var maxima = [UInt8](repeating: 0, count: 4)
        var covered = 0, red = 0, green = 0
        var minX = texture.width, minY = texture.height, maxX = -1, maxY = -1
        var samples: [String] = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            for lane in 0 ..< 4 {
                maxima[lane] = max(maxima[lane], pixels[offset + lane])
            }
            guard pixels[offset ..< offset + 3].contains(where: { $0 != 0 }) else { continue }
            let x = offset / 4 % texture.width, y = offset / 4 / texture.width
            covered += 1
            if Int(pixels[offset]) > Int(pixels[offset + 1]) + 30 {
                red += 1
            }
            if Int(pixels[offset + 1]) > Int(pixels[offset]) + 30 {
                green += 1
            }
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            if samples.count < 3 {
                samples.append("(\(x),\(y))=\(Array(pixels[offset ..< offset + 4]))")
            }
        }
        print("\(label): \(texture.width)x\(texture.height) rgbPixels=\(covered) redDominant=\(red) greenDominant=\(green) "
            + "maxRGBA=\(maxima) bounds=(\(minX),\(minY))...(\(maxX),\(maxY)) samples=\(samples)")
    }

    private func textGeometryIdentities(_ snapshot: WPEParityFrameRenderer.TextPreparationSnapshot)
        -> [Int: [ObjectIdentifier]] {
        snapshot.draws.mapValues { draw in
            if case let .mesh(vertices, indices, _, _) = draw.geometry {
                return [ObjectIdentifier(vertices), ObjectIdentifier(indices)]
            }
            return []
        }
    }

    private func assertTextAtlasState(_ actual: [String: WPEParityGlyphAtlasInstance],
                                      equals expected: [String: WPEParityGlyphAtlasInstance],
                                      texts: [WPEParitySceneText], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), file: file, line: line)
        for (key, instance) in expected {
            guard let atlas = actual[key]?.mono else { return XCTFail("Missing atlas \(key)", file: file, line: line) }
            let old = instance.mono
            XCTAssertEqual(atlas.pixels, old.pixels, file: file, line: line)
            XCTAssertEqual(atlas.width, old.width, file: file, line: line)
            XCTAssertEqual(atlas.height, old.height, file: file, line: line)
            XCTAssertEqual(atlas.isDirty, old.isDirty, file: file, line: line)
            XCTAssertEqual(atlas.generation, old.generation, file: file, line: line)
            XCTAssertEqual(atlas.contentGeneration, old.contentGeneration, file: file, line: line)
            XCTAssertEqual(atlas.resetGeneration, old.resetGeneration, file: file, line: line)
            for text in texts where text.atlasKey == key {
                for glyph in text.layout.mesh?.mono.glyphKeys ?? [] {
                    XCTAssertEqual(atlas.entry(forKey: glyph), old.entry(forKey: glyph), file: file, line: line)
                }
            }
        }
    }

    private func makeTextAdmissionFixture() async throws -> Fixture {
        do {
            let effect: [String: Any] = [
                "fbos": ["History", "HistoryOut"].map {
                    ["name": $0, "format": "rgba8888", "unique": true, "width": 4, "height": 4,
                     "clear": "0 1 0 1"] as [String: Any]
                },
                "passes": [["command": "copy", "source": "History", "target": "HistoryOut"],
                           ["material": "materials/effects/tint.json"]],
            ]
            let effectURL = scratch.appending(path: "effects/text-admission.json")
            try FileManager.default.createDirectory(at: effectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: effect).write(to: effectURL)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: true, text: "Hi")) as? [String: Any])
            var first = try XCTUnwrap((json["objects"] as? [[String: Any]])?.first)
            first["origin"] = "256 256 0"
            first["effects"] = [["file": "effects/text-admission.json", "id": 7, "visible": true]]
            var second = first
            second["id"] = 6
            second["origin"] = "768 256 0"
            second["effects"] = [["file": "effects/text-admission.json", "id": 8, "visible": true]]
            json["objects"] = [first, second]
            return try await makeSyntheticRenderer(effect: true, scene: JSONSerialization.data(withJSONObject: json))
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityTextAdmission.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required real font/shader/Metal fixture unavailable: \(error)"]
            ))
        }
    }

    func testDirectTextExtentReuseMatchesFullLayoutAndRollsBackWithTransformParents() async throws {
        let fixedInput = WPEParityFrameInput(cursor: SIMD2(Float(Self.width) * 0.5, Float(Self.height) * 0.5),
                                             date: Date(timeIntervalSince1970: 1_700_000_000))
        let flag = WPEParityFrameRenderer.directTextExtentReuseEnvironmentKey
        XCTAssertTrue(WPEParityFrameRenderer.resolveDirectTextExtentReuse(environment: [:]))
        XCTAssertTrue(WPEParityFrameRenderer.resolveDirectTextExtentReuse(environment: [flag: "YES"]))
        XCTAssertFalse(WPEParityFrameRenderer.resolveDirectTextExtentReuse(explicit: false, environment: [flag: "1"]))
        XCTAssertTrue(WPEParityFrameRenderer.resolveDirectTextExtentReuse(explicit: true, environment: [flag: "false"]))
        XCTAssertTrue(WPEParityFrameRenderer.resolveDirectTextExtentReuse(environment: [flag: "true"]))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsTextureSampleCount(4), "This paired resolve guard requires actual 4x MSAA support")
        func assertSamplesAndResolve(_ fixture: Fixture, samples: Int) throws {
            let renderer = fixture.renderer
            XCTAssertTrue(fixture.device.supportsTextureSampleCount(samples))
            XCTAssertEqual(renderer.backbuffer.sampleCount, 1, "The pixel oracle must read the resolved output")
            for frame in renderer.frames {
                let multisampled = frame.resources.filter { $0.sampleCount > 1 }
                XCTAssertEqual(multisampled.isEmpty, samples == 1, "The frame must exercise the requested sample count")
                for resource in multisampled {
                    XCTAssertEqual(resource.sampleCount, samples)
                    let target = try XCTUnwrap(renderer.renderTarget(resource.id))
                    XCTAssertEqual(target.sampleCount, samples, "Actual MSAA attachment for \(resource.id)")
                    XCTAssertEqual(target.textureType, .type2DMultisample)
                }
                let resolves = frame.operations.compactMap { operation -> (WPEResourceID, WPEResourceID)? in
                    if case let .resolve(source, destination) = operation.kind {
                        return (source, destination)
                    }
                    return nil
                }
                XCTAssertEqual(resolves.count, samples > 1 ? 1 : 0, "Direct text must resolve its scene attachment")
                for (source, destination) in resolves {
                    let sourceTexture = try XCTUnwrap(renderer.renderTarget(source))
                    let resolvedTexture = try XCTUnwrap(renderer.renderTarget(destination))
                    XCTAssertEqual(sourceTexture.sampleCount, samples)
                    XCTAssertEqual(resolvedTexture.sampleCount, 1)
                    XCTAssertTrue(resolvedTexture === renderer.backbuffer, "Compare the actual resolve destination pixels")
                }
            }
        }
        for (samples, parented) in [(1, false), (1, true), (4, false), (4, true)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: false)) as? [String: Any])
            var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
            if samples > 1 {
                // The product enables scene MSAA only when a real MDL model is present. Draw a blue quad
                // away from the white text, preserving the independent red-channel glyph bounds oracle.
                try writeDirectTextMSAAModel()
                objects.append(["id": 9, "name": "MSAA model", "image": "models/text-msaa.mdl",
                                "origin": "32 32 0"])
            }
            if parented {
                objects[0]["parent"] = 2
                objects[0]["origin"] = "420 230 0"
                objects.append(["id": 2, "origin": "40 10 0", "angles": "0 0 0.07", "scale": "0.9 0.9 1"])
            }
            json["objects"] = objects
            let scene = try JSONSerialization.data(withJSONObject: json)
            let settings = WPEParityProgramSettings(msaaSampleCount: samples)
            let slow = try await makeSyntheticRenderer(effect: false, scene: scene, settings: settings,
                                                       reuseDirectTextExtents: false)
            let fast = try await makeSyntheticRenderer(effect: false, scene: scene, settings: settings,
                                                       reuseDirectTextExtents: true)
            XCTAssertFalse(slow.renderer.reusesDirectTextExtentLayouts)
            XCTAssertTrue(fast.renderer.reusesDirectTextExtentLayouts)
            for fixture in [slow, fast] {
                try await encode(fixture.renderer, label: "direct extent initial", input: fixedInput)
                try assertSamplesAndResolve(fixture, samples: samples)
                try assertFullTextReference(fixture)
                if samples > 1 {
                    XCTAssertEqual(fixture.plan.scene.models["9"]?.meshes.count, 1, "A real MDL must enable MSAA")
                    let modelOperation = try XCTUnwrap(fixture.renderer.frames[0].draws.first { _, draw in
                        guard case let .scene(draw) = draw else { return false }
                        return draw.objectID == "9" && draw.geometry == .modelMesh
                    }?.key)
                    XCTAssertTrue(fixture.renderer.lastFrameDraws.contains { $0.operation == modelOperation },
                                  "The model must actually draw, rather than only toggle the MSAA flag")
                    let pixels = try readBack(fixture.renderer.backbuffer, fixture)
                    XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0 + 2] > pixels[$0] },
                                  "The resolved pixels must include the blue model")
                }
                fixture.renderer.startTextReplanDiagnostics()
            }
            let initial = try readBack(fast.renderer.backbuffer, fast)
            XCTAssertEqual(initial, try readBack(slow.renderer.backbuffer, slow))
            XCTAssertTrue(stride(from: 0, to: initial.count, by: 4).contains { initial[$0] > 0 })
            for caption in ["Hello", "WWW", "Hi"] {
                let previous = try XCTUnwrap(fast.renderer.texts[Self.textID]).layout.fboSize
                let reused = try XCTUnwrap(fast.renderer.textReplanDiagnostics).directExtentLayoutReuseCohorts
                for fixture in [slow, fast] {
                    fixture.renderer.state.setScriptField("text", of: Self.textID, to: .string(caption), invalidating: .textLayout)
                    try await encode(fixture.renderer, label: "direct extent \(caption)", input: fixedInput)
                    try assertFullTextReference(fixture)
                    try assertSamplesAndResolve(fixture, samples: samples)
                }
                let text = try XCTUnwrap(fast.renderer.texts[Self.textID])
                XCTAssertNotEqual(text.layout.fboSize, previous, "Must exercise an actual extent change")
                XCTAssertEqual(fast.renderer.textReplanDiagnostics?.directExtentLayoutReuseCohorts, reused + 1)
                XCTAssertEqual(slow.renderer.textReplanDiagnostics?.directExtentLayoutReuseCohorts, 0)
                XCTAssertEqual(try readBack(fast.renderer.backbuffer, fast), try readBack(slow.renderer.backbuffer, slow))
                let operation = try XCTUnwrap(fast.renderer.frames[0].draws.first { _, draw in
                    guard case let .scene(draw) = draw else { return false }
                    return draw.objectID == Self.textID && draw.geometry == .textGlyphs(.mono)
                }?.key)
                let actual = try XCTUnwrap(fast.renderer.uniforms(operation))
                let reference = try XCTUnwrap(slow.renderer.uniforms(operation))
                XCTAssertEqual(actual.effectPass?.size, SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y)))
                XCTAssertEqual(actual.matrices.model, reference.matrices.model)
                XCTAssertEqual(actual.matrices.view, reference.matrices.view)
                XCTAssertEqual(actual.matrices.projection, reference.matrices.projection)
                XCTAssertEqual(actual.effectPass?.effectTextureProjection, reference.effectPass?.effectTextureProjection)
                let emitted = try textDraw(fast.renderer, geometry: .textGlyphs(.mono))
                let expected = try textDraw(slow.renderer, geometry: .textGlyphs(.mono))
                for stage in [WPEHLSLStage.vertex, .fragment] {
                    assertTextBufferValues(emitted.values(for: stage), expected.values(for: stage))
                }
                let atlas = try XCTUnwrap(emitted.textures["g_Texture0"])
                let textureUniform = try XCTUnwrap(actual.textures.first ?? nil)
                XCTAssertEqual(textureUniform.textureWidth, UInt32(atlas.width))
                XCTAssertEqual(textureUniform.textureHeight, UInt32(atlas.height))
                let mesh = try XCTUnwrap(text.layout.mesh)
                let points = mesh.mono.vertices.map { vertex -> SIMD2<Float> in
                    let clip = actual.matrices.modelViewProjection * SIMD4(vertex.x, vertex.y, vertex.z, 1)
                    let ndc = SIMD2(clip.x, clip.y) / clip.w
                    return SIMD2((ndc.x + 1) * 0.5 * Float(Self.width), (1 - ndc.y) * 0.5 * Float(Self.height))
                }
                _ = try assertTextInk(in: fast.renderer.backbuffer, points: points, fixture: fast)
            }
            XCTAssertEqual(try readBack(fast.renderer.backbuffer, fast), initial, "Returning to Hi restores exact pixels")

            enum Injected: Error { case beforeAccept }
            let before = fast.renderer.textPreparationState
            let beforePixels = try readBack(fast.renderer.backbuffer, fast)
            let accepted = try XCTUnwrap(fast.renderer.textReplanDiagnostics).acceptedCohorts
            fast.renderer.textPreparationCheckpoint = { _ in throw Injected.beforeAccept }
            for fixture in [slow, fast] {
                fixture.renderer.state.setScriptField("text", of: Self.textID, to: .string("MMMM"), invalidating: .textLayout)
            }
            XCTAssertThrowsError(try fast.renderer.encodeFrame(elapsed: 1.0 / 60, input: fixedInput)) { XCTAssertTrue($0 is Injected) }
            let rejected = fast.renderer.textPreparationState
            XCTAssertEqual(rejected.texts, before.texts)
            XCTAssertEqual(rejected.frames, before.frames)
            XCTAssertEqual(rejected.layers.layers, before.layers.layers)
            XCTAssertEqual(rejected.targets.mapValues(ObjectIdentifier.init), before.targets.mapValues(ObjectIdentifier.init))
            XCTAssertEqual(rejected.atlases.textures.mapValues(ObjectIdentifier.init), before.atlases.textures.mapValues(ObjectIdentifier.init))
            XCTAssertEqual(textGeometryIdentities(rejected), textGeometryIdentities(before))
            XCTAssertEqual(try readBack(fast.renderer.backbuffer, fast), beforePixels)
            XCTAssertEqual(fast.renderer.textReplanDiagnostics?.acceptedCohorts, accepted)
            XCTAssertEqual(fast.renderer.textReplanDiagnostics?.failedCohorts, 1)
            fast.renderer.textPreparationCheckpoint = nil
            try await encode(slow.renderer, label: "reference after failed candidate", input: fixedInput)
            try await encode(fast.renderer, label: "retry direct extent", input: fixedInput)
            XCTAssertEqual(fast.renderer.textReplanDiagnostics?.acceptedCohorts, accepted + 1)
            XCTAssertEqual(fast.renderer.textPreparationState.pendingRequests, 0)
            XCTAssertEqual(try readBack(fast.renderer.backbuffer, fast), try readBack(slow.renderer.backbuffer, slow))
            try assertFullTextReference(fast)
            try assertSamplesAndResolve(fast, samples: samples)
            try assertSamplesAndResolve(slow, samples: samples)
            if parented {
                let reused = try XCTUnwrap(fast.renderer.textReplanDiagnostics).directExtentLayoutReuseCohorts
                for fixture in [slow, fast] {
                    XCTAssertTrue(fixture.renderer.state.setParent(Self.textID, to: nil))
                    fixture.renderer.state.setScriptField("text", of: Self.textID, to: .string("Hello"), invalidating: .textLayout)
                    try await encode(fixture.renderer, label: "pending parent generation slow control", input: fixedInput)
                    try assertFullTextReference(fixture)
                    try assertSamplesAndResolve(fixture, samples: samples)
                }
                XCTAssertEqual(fast.renderer.textReplanDiagnostics?.directExtentLayoutReuseCohorts, reused)
                XCTAssertEqual(try readBack(fast.renderer.backbuffer, fast), try readBack(slow.renderer.backbuffer, slow))
            }
        }
    }

    func testDirectExtentReuseFallsBackForEffectsEmptyGlyphsAndParentComposites() async throws {
        let fixedInput = WPEParityFrameInput(cursor: SIMD2(Float(Self.width) * 0.5, Float(Self.height) * 0.5),
                                             date: Date(timeIntervalSince1970: 1_700_000_000))
        for composite in [false, true] {
            let slow: Fixture, fast: Fixture
            if composite {
                slow = try await makeCompositeTextRenderer(effect: false, reuseDirectTextExtents: false)
                fast = try await makeCompositeTextRenderer(effect: false, reuseDirectTextExtents: true)
            } else {
                slow = try await makeSyntheticRenderer(effect: true, reuseDirectTextExtents: false)
                fast = try await makeSyntheticRenderer(effect: true, reuseDirectTextExtents: true)
            }
            for fixture in [slow, fast] {
                try await encode(fixture.renderer, label: "extent fallback initial", input: fixedInput)
                fixture.renderer.startTextReplanDiagnostics()
            }
            for caption in ["Hello", "", "Hi"] {
                for fixture in [slow, fast] {
                    fixture.renderer.state.setScriptField("text", of: Self.textID, to: .string(caption), invalidating: .textLayout)
                    try await encode(fixture.renderer, label: "extent fallback \(caption.debugDescription)", input: fixedInput)
                    try assertFullTextReference(fixture)
                }
                XCTAssertEqual(fast.renderer.textReplanDiagnostics?.directExtentLayoutReuseCohorts, 0)
                XCTAssertEqual(try readBack(fast.renderer.backbuffer, fast), try readBack(slow.renderer.backbuffer, slow))
                XCTAssertTrue(fast.renderer.skipped.isEmpty)
            }
            XCTAssertGreaterThan(try XCTUnwrap(fast.renderer.textReplanDiagnostics).fullLayoutCohorts, 0)
        }
        let direct = try await makeSyntheticRenderer(effect: false, reuseDirectTextExtents: true)
        try await encode(direct.renderer, label: "empty direct initial", input: fixedInput)
        direct.renderer.startTextReplanDiagnostics()
        direct.renderer.state.setScriptField("text", of: Self.textID, to: .string(""), invalidating: .textLayout)
        try await encode(direct.renderer, label: "empty direct slow control", input: fixedInput)
        XCTAssertEqual(direct.renderer.textReplanDiagnostics?.directExtentLayoutReuseCohorts, 0)
        XCTAssertEqual(direct.renderer.textReplanDiagnostics?.frameRebuildCohorts, 1)
        try assertFullTextReference(direct)
    }

    /// Full CPU composition is an independent oracle used only by tests, never by eligibility on the hot path.
    private func assertFullTextReference(_ fixture: Fixture) throws {
        let renderer = fixture.renderer
        let expected = try fixture.plan.layout(effects: renderer.state, texts: renderer.texts)
        let actual = renderer.textFrameLayoutForTesting
        XCTAssertEqual(actual.frames, expected.frames)
        XCTAssertEqual(actual.programs.mapValues(\.hlsl), expected.programs.mapValues(\.hlsl))
        XCTAssertEqual(actual.bindings.count, expected.bindings.count)
        for (variant, bindings) in expected.bindings.enumerated() {
            XCTAssertEqual(Set(actual.bindings[variant].keys), Set(bindings.keys))
            for (index, binding) in bindings {
                let kept = try XCTUnwrap(actual.bindings[variant][index])
                XCTAssertEqual(Set(kept.constants.keys), Set(binding.constants.keys))
                for (stage, values) in binding.constants {
                    assertTextBufferValues(kept.constants[stage] ?? [:], values)
                }
                XCTAssertEqual(kept.textures, binding.textures)
                XCTAssertEqual(kept.cullsBackFaces, binding.cullsBackFaces)
                XCTAssertEqual(kept.depthTest, binding.depthTest)
                XCTAssertEqual(kept.depthWrite, binding.depthWrite)
            }
        }
        for frame in expected.frames {
            for resource in frame.resources {
                guard let texture = renderer.textPreparationState.targets[resource.id] else { continue }
                XCTAssertEqual(texture.width, resource.width)
                XCTAssertEqual(texture.height, resource.height)
                XCTAssertEqual(texture.sampleCount, resource.sampleCount)
            }
        }
    }

    private func assertTextBufferValues(_ actual: [String: WPECBufferValue], _ expected: [String: WPECBufferValue],
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), file: file, line: line)
        for (name, expected) in expected {
            guard let actual = actual[name] else { continue }
            XCTAssertTrue(sameTextBufferValue(actual, expected), "Different cbuffer value for \(name)", file: file, line: line)
        }
    }

    private func sameTextBufferValue(_ actual: WPECBufferValue, _ expected: WPECBufferValue) -> Bool {
        switch (actual, expected) {
        case let (.float(a), .float(b)): a.bitPattern == b.bitPattern
        case let (.int(a), .int(b)): a == b
        case let (.uint(a), .uint(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case let (.vector(a), .vector(b)): a.map(\.bitPattern) == b.map(\.bitPattern)
        case let (.intVector(a), .intVector(b)): a == b
        case let (.uintVector(a), .uintVector(b)): a == b
        case let (.matrix(a), .matrix(b)):
            a.columns.map { $0.map(\.bitPattern) } == b.columns.map { $0.map(\.bitPattern) }
        case let (.array(a), .array(b)):
            a.count == b.count && zip(a, b).allSatisfy { sameTextBufferValue($0.0, $0.1) }
        default: false
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

    func testTextColourVisibilityAndEffectChangeLiveWithoutRelayout() async throws {
        let wpeAssets = try wpeAssets()
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let cache = FileManager.default.temporaryDirectory.appending(path: "parity-text-cache",
                                                                     directoryHint: .isDirectory)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func boundScene(effect: Bool) throws -> Data {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: effect))
                as? [String: Any])
            var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
            objects[0]["color"] = ["user": "tint", "value": "1 1 1"]
            objects[0]["visible"] = ["user": "show", "value": true]
            if effect {
                var effects = try XCTUnwrap(objects[0]["effects"] as? [[String: Any]])
                effects[0]["visible"] = ["user": "tinted", "value": true]
                objects[0]["effects"] = effects
            }
            json["objects"] = objects
            return try JSONSerialization.data(withJSONObject: json)
        }
        func load(_ scene: Data) async throws -> WPEParitySceneDriver {
            let driver = try WPEParitySceneDriver(device: device)
            try await driver.load(document: Self.parse(scene),
                                  assets: WPEParityProgramAssets(sceneDirectory: scratch,
                                                                 assetRoots: [wpeAssets, wpeAssets.appending(path: "effects/tint")]),
                                  settings: WPEParityProgramSettings(),
                                  drawableSize: CGSize(width: Self.width, height: Self.height), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
            return driver
        }
        var values: [String: WallpaperEngineProjectPropertyValue] = [:]
        func change(_ driver: WPEParitySceneDriver, scene: Data, _ key: String,
                    to value: WallpaperEngineProjectPropertyValue) throws -> Bool {
            let old = values[key] ?? (key == "tint" ? .string("1 1 1") : .bool(true))
            var next = values
            next[key] = value
            let patch = WPEScenePropertyPatch(bindingsByProperty: driver.userPropertyBindings,
                                              oldValues: [key: old], newValues: [key: value])
            guard try driver.prepareUserProperties(patch, document: Self.parse(scene, userValues: next)),
                  driver.commitUserProperties(patch) else { return false }
            values = next
            return true
        }
        func lit(_ pixels: [UInt8]) -> [Int] {
            stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 ..< $0 + 3].contains { $0 != 0 } }
        }

        let plain = try boundScene(effect: false)
        let driver = try await load(plain)
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        let generation = driver.loadGeneration
        try await encode(renderer, label: "white")
        let before = try glyphRect(XCTUnwrap(renderer.texts[Self.textID]), document: Self.parse(plain))

        XCTAssertTrue(try change(driver, scene: plain, "tint", to: .string("1 0 0")), "a colour change commits live")
        XCTAssertTrue(driver.renderer === renderer, "the renderer is not rebuilt")
        XCTAssertEqual(driver.loadGeneration, generation, "the scene did not reload")
        try await encode(renderer, label: "red")
        let after = try glyphRect(XCTUnwrap(renderer.texts[Self.textID]), document: Self.parse(plain))
        XCTAssertTrue(before == after, "the glyph block keeps its layout: \(before) -> \(after)")
        let red = try readBack(renderer.backbuffer, device: device, queue: queue)
        let redPixels = lit(red)
        XCTAssertFalse(redPixels.isEmpty)
        XCTAssertEqual(redPixels.filter { red[$0 + 1] != 0 || red[$0 + 2] != 0 }.count, 0, "every glyph pixel is red")

        XCTAssertTrue(try change(driver, scene: plain, "show", to: .bool(false)))
        try await encode(renderer, label: "hidden")
        XCTAssertEqual(try lit(readBack(renderer.backbuffer, device: device, queue: queue)).count, 0)
        XCTAssertEqual(driver.loadGeneration, generation)

        values = [:]
        let tinted = try boundScene(effect: true)
        let effectDriver = try await load(tinted)
        defer { effectDriver.cleanup() }
        let effectRenderer = try XCTUnwrap(effectDriver.renderer)
        try await encode(effectRenderer, label: "effect on")
        let shown = effectRenderer.lastFrameDraws.count
        XCTAssertTrue(try change(effectDriver, scene: tinted, "tinted", to: .bool(false)))
        XCTAssertTrue(effectDriver.renderer === effectRenderer)
        try await encode(effectRenderer, label: "effect off")
        XCTAssertLessThan(effectRenderer.lastFrameDraws.count, shown, "the hidden effect's passes leave the frame")
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

    /// `thisLayer.size` on text is the measured box (FUN_140258900), re-seeded after each relayout.
    func testScriptReadsTextSizeAsTheMeasuredBoxAcrossRelayout() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.syntheticScene(effect: false)) as? [String: Any])
        var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
        let script = """
        let frame = 0;
        export function update(value) {
            frame += 1;
            thisLayer.origin = new Vec3(thisLayer.size.x, thisLayer.size.y, frame);
            if (frame === 2) thisLayer.text = 'Hi';
            return value;
        }
        """
        let fields: [String: Any] = ["text": "Hello big World", "alpha": ["value": 1, "script": script]]
        objects[0].merge(fields) { _, next in next }
        json["objects"] = objects
        let fixture = try await makeSyntheticRenderer(effect: false, scene: JSONSerialization.data(withJSONObject: json),
                                                      scripted: true)
        let renderer = fixture.renderer
        try await encode(renderer, label: "first size read")
        let first = try XCTUnwrap(renderer.texts[Self.textID])
        let mesh = try XCTUnwrap(first.layout.mesh)
        let firstOrigin = try XCTUnwrap(renderer.state.object(Self.textID)?.origin)
        XCTAssertEqual(SIMD2(firstOrigin.x, firstOrigin.y), first.scriptSize)
        XCTAssertEqual(first.scriptSize, SIMD2(mesh.maxX - mesh.minX, mesh.top - mesh.bottom))

        try await encode(renderer, label: "text write")
        try await encode(renderer, label: "relaid size read")
        let relaid = try XCTUnwrap(renderer.texts[Self.textID])
        let origin = try XCTUnwrap(renderer.state.object(Self.textID)?.origin)
        XCTAssertEqual(origin.z, 3)
        XCTAssertEqual(SIMD2(origin.x, origin.y), relaid.scriptSize)
        XCTAssertNotEqual(relaid.scriptSize, first.scriptSize)
        let engine = try XCTUnwrap(renderer.script).engine
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
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
        let mvp = try layers.projection(Self.textID) * layers.view(Self.textID, parallax: .zero) * model
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

    /// A real static MDLV0016 quad, with the same 0x0F position/normal/tangent/UV layout as the shadow guard.
    private func writeDirectTextMSAAModel() throws {
        for directory in ["models", "materials"] {
            try FileManager.default.createDirectory(at: scratch.appending(path: directory), withIntermediateDirectories: true)
        }
        let material: [String: Any] = ["passes": [[
            "shader": "generic4", "blending": "normal", "textures": ["util/white"],
            "combos": ["LIGHTING": 0, "FOG": 0, "REFLECTION": 0],
            "constantshadervalues": ["color": "0 0 1"],
        ]]]
        try JSONSerialization.data(withJSONObject: material).write(to: scratch.appending(path: "materials/text-msaa.json"))
        var data = Data("MDLV0016".utf8)
        func append(_ words: [UInt32]) {
            for word in words {
                withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        append([0x0F00])
        data.append(0)
        append([1, 1])
        data.append(contentsOf: Array("materials/text-msaa.json".utf8) + [0])
        append([0, 0x0F])
        let corners: [(Float, Float, Float, Float)] = [(-4, -4, 0, 1), (4, -4, 1, 1), (-4, 4, 0, 0), (4, 4, 1, 0)]
        append([UInt32(corners.count * 12 * 4)])
        for (x, y, u, v) in corners {
            append([x, y, 0, 0, 0, 1, 1, 0, 0, 1, u, v].map(\.bitPattern))
        }
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        append([UInt32(indices.count * 2)])
        for index in indices {
            withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: scratch.appending(path: "models/text-msaa.mdl"))
    }

    private func makeCompositeTextRenderer(effect: Bool, reuseDirectTextExtents: Bool? = nil) async throws -> Fixture {
        let scene = try Self.syntheticScene(effect: effect)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: scene) as? [String: Any])
        var general = try XCTUnwrap(json["general"] as? [String: Any])
        general["perspectiveoverridefov"] = 90
        json["general"] = general
        var objects = try XCTUnwrap(json["objects"] as? [[String: Any]])
        objects[0].merge(["parent": 1, "origin": "384 192 128", "pointsize": 8, "perspective": true,
                          "padding": "8 8", "opaquebackground": effect] as [String: Any]) { _, next in next }
        objects += [
            ["id": 2, "origin": "64 24 0", "angles": "0 0 0.08"],
            ["id": 1, "parent": 2, "image": "models/util/solidlayer.json", "size": "1024 512",
             "config": ["passthrough": true], "copybackground": false,
             "origin": "448 232 0", "angles": "0 0 -0.12", "scale": "0.75 0.75 1", "color": "0 0 0", "alpha": 1,
             "effects": [["file": "effects/tint/effect.json", "id": 10, "visible": true,
                          "passes": [["constantshadervalues": ["alpha": 0]]]]]],
        ]
        json["objects"] = objects
        return try await makeSyntheticRenderer(effect: effect, scene: JSONSerialization.data(withJSONObject: json),
                                               reuseDirectTextExtents: reuseDirectTextExtents)
    }

    /// Keep the parent world's nontrivial chain while diagnosing the actual final publication, after its child drew.
    private func assertParentPublication(_ fixture: Fixture) throws {
        let renderer = fixture.renderer
        let operation = try XCTUnwrap(fixture.plan.frames[0].draws.first { _, draw in
            guard case let .scene(scene) = draw else { return false }
            return scene.objectID == "1" && scene.effectID == "10" && scene.target == WPEParitySceneResource.backbuffer
        })
        guard case let .scene(description) = operation.value else { return XCTFail("not a parent publication") }
        let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation.key }?.draw)
        let source = try XCTUnwrap(draw.textures["g_Texture0"])
        let expectedSource = try XCTUnwrap(description.reads.first.flatMap { renderer.targets[$0] })
        XCTAssertTrue(source === expectedSource, "the real tint pass must sample the composite its child wrote")
        let input = try readBack(source, fixture)
        XCTAssertTrue(stride(from: 0, to: input.count, by: 4).contains { input[$0] > 0 },
                      "parent tint source is black before global publication")
        let matrices = try XCTUnwrap(renderer.uniforms(operation.key)).matrices
        let rootAngle: Float = 0.08
        let angle: Float = -0.04
        let translation = SIMD4<Float>(64 + cos(rootAngle) * 448 - sin(rootAngle) * 232,
                                       24 + sin(rootAngle) * 448 + cos(rootAngle) * 232, 0, 1)
        let right = SIMD4<Float>(0.75 * cos(angle), 0.75 * sin(angle), 0, 0)
        let up = SIMD4<Float>(-0.75 * sin(angle), 0.75 * cos(angle), 0, 0)
        XCTAssertLessThanOrEqual(simd_reduce_max(abs(matrices.model.columns.3 - translation)), 0.001)
        XCTAssertLessThanOrEqual(simd_reduce_max(abs(matrices.model.columns.0 - right)), 0.001)
        XCTAssertLessThanOrEqual(simd_reduce_max(abs(matrices.model.columns.1 - up)), 0.001)
        print("text parent publication \(description.pass.rawValue): source=\(source.width)x\(source.height), "
            + "modelOrigin=\(matrices.model.columns.3), "
            + "tintAlpha=\(String(describing: draw.constants[.fragment]?["g_BlendAlpha"]))")
    }

    /// Read the actual font target, requiring ink inside the independently projected glyph quads and none outside.
    private func assertTextInk(in texture: MTLTexture, points: [SIMD2<Float>], fixture: Fixture) throws -> [UInt8] {
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        var low = try XCTUnwrap(points.first)
        var high = low
        for point in points {
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        let lower = SIMD2<Int>(low, rounding: .down)
        let upper = SIMD2<Int>(high, rounding: .up)
        XCTAssertGreaterThanOrEqual(lower.x, 0)
        XCTAssertGreaterThanOrEqual(lower.y, 0)
        XCTAssertLessThanOrEqual(upper.x, texture.width)
        XCTAssertLessThanOrEqual(upper.y, texture.height)
        let pixels = try readBack(texture, fixture)
        var (inside, outside) = (0, 0)
        for y in 0 ..< texture.height {
            for x in 0 ..< texture.width where pixels[(y * texture.width + x) * 4] > 0 {
                if x >= lower.x, x < upper.x, y >= lower.y, y < upper.y {
                    inside += 1
                } else {
                    outside += 1
                }
            }
        }
        XCTAssertGreaterThan(inside, 0, "no font pixels inside \(lower)..<\(upper)")
        XCTAssertEqual(outside, 0, "font pixels escaped \(lower)..<\(upper)")
        return pixels
    }

    private static func parse(_ scene: Data,
                              userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(data: scene, userValues: userValues)
    }

    private func makeSyntheticRenderer(effect: Bool, scene: Data? = nil,
                                       settings: WPEParityProgramSettings = .init(), scripted: Bool = false,
                                       alignment: WPEParityCameraAlignment = .noCrop,
                                       reuseDirectTextExtents: Bool? = nil) async throws -> Fixture {
        let wpeAssets = try wpeAssets()
        let document = try Self.parse(scene ?? Self.syntheticScene(effect: effect))
        // The tint effect keeps its material and shaders in its own folder.
        let assets = WPEParityProgramAssets(sceneDirectory: scratch,
                                            assetRoots: [wpeAssets, wpeAssets.appending(path: "effects/tint")])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: settings,
                                          width: Self.width, height: Self.height, alignment: alignment)
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
            particleSeed: 1, reuseDirectTextExtentLayouts: reuseDirectTextExtents
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
                                                        userValues: [:])
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets,
                                          settings: WPEParityProgramSettings(bloom: true, hdrPostProcessing: true,
                                                                             msaaSampleCount: 2),
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

    private func encode(_ renderer: WPEParityFrameRenderer, label: String, input: WPEParityFrameInput? = nil) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60, input: input ?? .init()) else {
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

#endif
