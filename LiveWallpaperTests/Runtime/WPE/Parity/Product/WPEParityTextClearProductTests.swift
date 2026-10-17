#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import simd
import XCTest

extension WPEParitySceneDriverTests {
    @objc func testTextClearAlphaTopLevelKeepsSceneCameraBeforePerspectiveAnchorAndBlock() async throws {
        try await textClearRun(.topLevel)
    }

    @objc func testTextClearAlphaInParentCompositeReplacesModelAndInheritsParentCamera() async throws {
        try await textClearRun(.parentComposite)
    }

    @objc func testTextClearAlphaInFullscreenParentInheritsTheSceneCamera() async throws {
        try await textClearRun(.fullscreenParent)
    }

    @objc func testTextClearAlphaInNestedFullscreenParentInheritsTheOuterCompositeCamera() async throws {
        try await textClearRun(.nestedFullscreenParent)
    }

    private enum TextClearContext: Equatable {
        case topLevel, parentComposite, fullscreenParent, nestedFullscreenParent

        var parentID: String? {
            switch self {
            case .topLevel: nil
            case .parentComposite, .fullscreenParent: "100"
            case .nestedFullscreenParent: "101"
            }
        }

        /// All values are fixed from the authored transforms and native slot28/caller contracts.
        /// No expected matrix is built with production camera, layer, or text placement helpers.
        var modelColumns: [[Float]] {
            let translation: [Float] = switch self {
            case .topLevel, .fullscreenParent: [208, 128, 64, 1]
            case .parentComposite: [16, 96, 32, 1]
            case .nestedFullscreenParent: [18, 48, 32, 1]
            }
            return [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], translation]
        }

        var projectionColumns: [[Float]] {
            switch self {
            case .topLevel, .fullscreenParent:
                // Scene384x256 cropped to384x192: bounds(0,384,32,224), depth±2000.
                [[1 / 192, 0, 0, 0], [0, 1 / 96, 0, 0], [0, 0, 1 / 4000, 0], [-1, -4 / 3, 0.5, 1]]
            case .parentComposite:
                // Ordinary parent384x256: centred ortho and depth±1000.
                [[1 / 192, 0, 0, 0], [0, 1 / 128, 0, 0], [0, 0, 1 / 2000, 0], [0, 0, 0.5, 1]]
            case .nestedFullscreenParent:
                // The fullscreen intermediate inherits ordinary outer256x192, not its own384x192.
                [[1 / 128, 0, 0, 0], [0, 1 / 96, 0, 0], [0, 0, 1 / 2000, 0], [0, 0, 0.5, 1]]
            }
        }

        var mvpColumns: [[Float]] {
            switch self {
            case .topLevel, .fullscreenParent:
                [[1 / 192, 0, 0, 0], [0, 1 / 96, 0, 0], [0, 0, 1 / 4000, 0], [1 / 12, 0, 0.516, 1]]
            case .parentComposite:
                [[1 / 192, 0, 0, 0], [0, 1 / 128, 0, 0], [0, 0, 1 / 2000, 0], [1 / 12, 0.75, 0.516, 1]]
            case .nestedFullscreenParent:
                [[1 / 128, 0, 0, 0], [0, 1 / 96, 0, 0], [0, 0, 1 / 2000, 0], [0.140625, 0.5, 0.516, 1]]
            }
        }

        var paddingRGB: [Int] {
            switch self {
            case .nestedFullscreenParent: [0, 0, 255]
            default: [255, 0, 0]
            }
        }
    }

    private func textClearRun(_ context: TextClearContext) async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (original, compiler) = try textClearRequiredInputs()
        let (document, assets) = try textClearDocument(context, original: original)
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityTextClearProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required isolated XCTest defaults are absent"])
        }
        let scaleKey = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let savedScale = defaults.object(forKey: scaleKey)
        defaults.set(1.0, forKey: scaleKey)
        defer {
            if let savedScale {
                defaults.set(savedScale, forKey: scaleKey)
            } else {
                defaults.removeObject(forKey: scaleKey)
            }
        }
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 384, height: 192), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        let renderer = try XCTUnwrap(driver.renderer)
        let generation = driver.loadGeneration
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.drawableSize = CGSize(width: 384, height: 192)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        let identity: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
        var firstFill: [UInt8]?
        var publicationMVPs: [[Float]] = []
        for perspective in [false, true, false] {
            renderer.state.setScriptField("perspective", of: "5", to: .vector(SIMD4(perspective ? 1 : 0, 0, 0, 0)),
                                          invalidating: .none)
            try await present(driver, layer: layer, label: "text clear \(context), perspective=\(perspective)")
            XCTAssertEqual(driver.loadGeneration, generation)
            XCTAssertEqual(driver.shaderErrorSummary.count, 0)
            XCTAssertEqual(renderer.skipped, [:])
            XCTAssertTrue(renderer.fallbackTextures.isEmpty)
            XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
            XCTAssertEqual([renderer.backbuffer.width, renderer.backbuffer.height], [384, 192])
            XCTAssertEqual(renderer.pathCamera.cropMargins.top, 32)
            XCTAssertEqual(renderer.pathCamera.cropMargins.bottom, 32)
            let text = try XCTUnwrap(renderer.texts["5"])
            XCTAssertFalse(text.object.opaqueBackground)
            XCTAssertEqual(String(describing: text.object.anchor), "topRight")
            XCTAssertGreaterThan(text.layout.blockOffset.x, 0, "left alignment must qualify a nonzero block offset")
            XCTAssertNotEqual(text.layout.blockOffset.y, 0, "top alignment must qualify a nonzero block offset")
            let mesh = try XCTUnwrap(text.layout.mesh)
            XCTAssertFalse(mesh.mono.glyphKeys.isEmpty)
            let frame = try XCTUnwrap(renderer.frames.first)
            let clears = frame.draws.compactMap { index, value -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = value, draw.objectID == "5",
                      draw.source?.materialPath == "materials/util/composelayer_clearalpha.json" else { return nil }
                return (index, draw)
            }
            XCTAssertEqual(clears.count, 1)
            let (index, description) = try XCTUnwrap(clears.first)
            XCTAssertEqual(description.shader, "composelayer")
            XCTAssertEqual(description.reads, ["_rt_FullFrameBuffer"])
            let encoded = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == index }?.draw)
            XCTAssertGreaterThan(encoded.indexCount + encoded.vertexCount, 0)
            let background = try XCTUnwrap(renderer.renderTarget("_rt_FullFrameBuffer"))
            XCTAssertTrue(try XCTUnwrap(encoded.textures["g_Texture0"]) === background)
            XCTAssertEqual([background.width, background.height], [384, 192])
            let originalBackground = try readBack(background, device: device)
            try textClearAssertPixel(originalBackground, width: 384, x: 32, y: 16, rgb: [0, 255, 0], alpha: 255,
                                     label: "actual green FFB producer")
            try textClearAssertPixel(originalBackground, width: 384, x: 208, y: 16, rgb: [255, 0, 0], alpha: 255,
                                     label: "actual narrow red FFB producer")
            try textClearAssertPixel(originalBackground, width: 384, x: 300, y: 16, rgb: [0, 0, 255], alpha: 255,
                                     label: "actual blue FFB producer")
            let matrices = try XCTUnwrap(renderer.uniforms(index)).matrices
            textClearAssertMatrix(matrices.model, columns: context.modelColumns, exact: true, label: "slot28 M \(context)")
            textClearAssertMatrix(matrices.view, columns: identity, exact: true, label: "slot28 inherited V \(context)")
            textClearAssertMatrix(matrices.projection, columns: context.projectionColumns, label: "slot28 inherited P \(context)")
            guard case let .matrix(mvp)? = encoded.values(for: .vertex)["g_ModelViewProjectionMatrix"] else {
                return XCTFail("original clearalpha VS must consume the actual encoded MVP")
            }
            // Native case9 uploads register i as mathematical row i (1400d8300.c); keep the fixed
            // authored MVP independent of production helpers, then explicitly transpose its columns.
            let expectedRegisters = (0 ..< 4).map { row in context.mvpColumns.map { $0[row] } }
            textClearAssertColumns(mvp.columns, expected: expectedRegisters, label: "actual slot28 encoded MVP")
            let target = try XCTUnwrap(renderer.renderTarget(description.target))
            XCTAssertEqual(target.pixelFormat, .rgba8Unorm)
            XCTAssertEqual([target.width, target.height], [text.layout.fboSize.x, text.layout.fboSize.y])
            let fill = try readBack(target, device: device)
            // y=1 is inside the authored16px top padding, beyond all glyph ink. The horizontal midpoint has
            // localx0...0.5. Native scene/parent MVP samples the independently authored constant-colour column.
            try textClearAssertPixel(fill, width: target.width, x: target.width / 2, y: 1,
                                     rgb: context.paddingRGB, alpha: 0, label: "actual clearalpha padding \(context)")
            XCTAssertTrue(stride(from: 0, to: fill.count, by: 4).contains {
                fill[$0] > 200 && fill[$0 + 1] > 200 && fill[$0 + 2] > 200
            }, "the real font draw must write white glyph ink into the actual text target")
            if let firstFill {
                XCTAssertEqual(fill, firstFill, "own perspective cannot change this offscreen fill")
            } else {
                firstFill = fill
            }
            let glyphs = frame.draws.compactMap { operation, value -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = value, draw.objectID == "5", draw.geometry == .textGlyphs(.mono),
                      draw.fillsComposite else { return nil }
                return (operation, draw)
            }
            XCTAssertEqual(glyphs.count, 1)
            let (glyphIndex, glyphDescription) = try XCTUnwrap(glyphs.first)
            XCTAssertEqual(glyphDescription.target, description.target)
            XCTAssertEqual(glyphDescription.source?.materialPath, "materials/fonts/basefont.json")
            let glyph = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == glyphIndex }?.draw)
            XCTAssertGreaterThan(glyph.indexCount, 0)
            XCTAssertEqual(try XCTUnwrap(glyph.textures["g_Texture0"]).pixelFormat, .r8Unorm)
            let glyphMatrices = try XCTUnwrap(renderer.uniforms(glyphIndex)).matrices
            textClearAssertMatrix(glyphMatrices.view, columns: identity, exact: true, label: "ownFBO glyph V")
            let publications = frame.draws.compactMap { operation, value -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = value, draw.objectID == "5", draw.effectID == "9" else { return nil }
                return (operation, draw)
            }
            XCTAssertEqual(publications.count, 1)
            let (publicationIndex, publication) = try XCTUnwrap(publications.first)
            XCTAssertEqual(publication.compositeOwnerID, context.parentID)
            if context.parentID != nil {
                let parentTarget = try XCTUnwrap(renderer.renderTarget(publication.target))
                let parentSize = context == .parentComposite ? [384, 256] : [384, 192]
                XCTAssertEqual([parentTarget.width, parentTarget.height], parentSize)
            }
            if context == .fullscreenParent || context == .nestedFullscreenParent {
                let parentID = try XCTUnwrap(context.parentID)
                let copy = try XCTUnwrap(frame.operations.first { $0.pass.rawValue == "\(parentID)/fullscreen" })
                guard case let .copy(source, destination) = copy.kind else {
                    return XCTFail("the real fullscreen parent must take its native CopyResource branch")
                }
                XCTAssertEqual(source, WPEParitySceneResource.backbuffer)
                XCTAssertEqual(destination, publication.target)
            }
            if case .nestedFullscreenParent = context {
                let outer = try XCTUnwrap(frame.draws.first { _, value in
                    guard case let .scene(draw) = value else { return false }
                    return draw.pass.rawValue == "100/albedo"
                })
                guard case let .scene(outerDescription) = outer.value else { return XCTFail("outer albedo missing") }
                let outerTarget = try XCTUnwrap(renderer.renderTarget(outerDescription.target))
                XCTAssertEqual([outerTarget.width, outerTarget.height], [256, 192])
                _ = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == outer.key })
            }
            let published = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == publicationIndex }?.draw)
            XCTAssertGreaterThan(published.indexCount + published.vertexCount, 0)
            guard case let .matrix(publicationMVP)? = published.values(for: .vertex)["g_ModelViewProjectionMatrix"] else {
                return XCTFail("original tint publication must consume a real MVP")
            }
            publicationMVPs.append(publicationMVP.columns.flatMap(\.self))
            let shownTexture = try XCTUnwrap(layer.lastTexture)
            XCTAssertEqual([shownTexture.width, shownTexture.height], [384, 192])
            let shown = try readBack(shownTexture, device: device)
            // 1401e8aa0.c:1004-1050: a fullscreen parent's tint covers the whole backbuffer; white at alpha 1 maps
            // blue to max(rgb) · white.
            let beyond = context == .fullscreenParent ? [255, 255, 255] : [0, 0, 255]
            try textClearAssertPixel(shown, width: 384, x: 380, y: 16, rgb: beyond, alpha: 255,
                                     label: "actual displayed background beyond the text/ordinary parent")
            if case .topLevel = context {
                let hasDisplayedInk = stride(from: 0, to: shown.count, by: 4).contains {
                    shown[$0] > 200 && shown[$0 + 1] > 200 && shown[$0 + 2] > 200
                }
                // Native FOV90 gives D96; z64 makes visible worldY96...160. With topRight
                // anchor and NotoSans ascender36, Hi's highest ink is at about85, outside that crop.
                XCTAssertEqual(hasDisplayedInk, !perspective,
                               "top-level glyph publication must follow the native perspective crop")
            }
        }
        XCTAssertEqual(publicationMVPs.count, 3)
        XCTAssertNotEqual(publicationMVPs[0], publicationMVPs[1], "perspective must still affect final publication")
        XCTAssertEqual(publicationMVPs[0], publicationMVPs[2])
    }

    private func textClearRequiredInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        do {
            let (_, assets) = try sceneInputs()
            let root = try XCTUnwrap(assets.roots.last)
            let sources = WPEParityProgramAssets(sources: assets.sources + [.directory(root.appending(path: "effects/tint"))])
            for (path, expected) in [
                ("fonts/NotoSans-Regular.ttf", "6b04c8dd65af6b73eb4279472ed1580b29102d6496a377340e80a40cdb3b22c9"),
                ("shaders/composelayer.vert", "882e6a03e8a522ae3141f177a9e0dcf0344c02b48e7e4c784a3b3eeea1c44b4a"),
                ("shaders/composelayer.frag", "bcf261ed44fd6fb36eac07c5899c5f15bb376d8ab105643687fa5fb376cfeb5c"),
                ("materials/util/composelayer_clearalpha.json", "90e81a384e0705088a0b05a34dd970891f777de7418c144c4fcf1dddb330f088"),
                ("shaders/font.vert", "8b337706d01a9a7ee5919c3cd3e489190d753e26e191e68b4014cb732c26f944"),
                ("shaders/font.frag", "d9f4e7198e2cc417c50a62d65e7dd2a654a13657b4d61df358bb1c016d4d7b26"),
                ("materials/fonts/basefont.json", "885e2055a3d3986954fad77c3fbc2fe2b57a087aaf52615f56b435205914d9c8"),
                ("models/util/fullscreenlayer.json", "4be60e2bbbe476a841cd3fddd9b0b1227e8604da6ba5fc99138f575c45730354"),
                ("materials/util/fullscreenlayer.json", "9116ecbfd25ef54992a9cdbf8a91dd7e0a09fe7ef095655734b46a49b1e88be2"),
                ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
                ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
                ("effects/tint/effect.json", "9bda1c7c508c71b90d7d51fbef45f06eb284691f8447000a3c98ef95dfdadbcc"),
                ("materials/effects/tint.json", "d5a190abf6ebc13981b7e26ca623577d2cfe0783a343e05fc1a46dcce7cb5016"),
                ("shaders/effects/tint.vert", "62b2f5853fc565d706c1b6c789981385254f8195e0e1579c3d737796b41ddf2a"),
                ("shaders/effects/tint.frag", "02b9397cec32de6f0d8caa2e1af7c07510752d474bd64048c9d78f55926973f1"),
            ] {
                let data = try XCTUnwrap(sources.data(path), "required original \(path)")
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else {
                    throw NSError(domain: "WPEParityTextClearProductTests.AssetIdentity", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "\(path): expected \(expected), actual \(actual)"])
                }
            }
            let contents = Bundle.main.bundleURL.appending(path: "Contents")
            for path in ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"] {
                _ = try XCTUnwrap(FileManager.default.fileExists(atPath: contents.appending(path: path).path) ? path : nil,
                                  "required app bundled compiler \(path)")
            }
            for key in ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER"] {
                guard ProcessInfo.processInfo.environment[key] == nil else {
                    throw NSError(domain: "WPEParityTextClearProductTests.ToolOverride", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Required bundled compiler cannot use \(key)"])
                }
            }
            switch WPEParityShaderToolchain.makeCompiler() {
            case let .success(compiler): return (sources, compiler)
            case let .failure(reason): throw reason
            }
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityTextClearProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets/bundled helper unavailable: \(error)"]
            ))
        }
    }

    private func textClearDocument(_ context: TextClearContext, original: WPEParityProgramAssets) throws
        -> (WPESceneDocument, WPEParityProgramAssets) {
        func effect(_ id: Int) -> [[String: Any]] {
            [["id": id, "file": "effects/tint/effect.json", "visible": true,
              "passes": [["constantshadervalues": ["color": "1 1 1", "alpha": 1]]]]]
        }
        func panel(_ id: Int, width: Int, x: Int, color: String) -> [String: Any] {
            ["id": id, "image": "models/util/solidlayer.json", "size": "\(width) 256", "origin": "\(x) 128 0",
             "color": color, "solid": true]
        }
        var objects = [panel(1, width: 192, x: 96, color: "0 1 0"),
                       panel(2, width: 24, x: 204, color: "1 0 0"),
                       panel(3, width: 168, x: 300, color: "0 0 1")]
        var origin = "208 128 64"
        switch context {
        case .topLevel: break
        case .parentComposite:
            objects.append(["id": 100, "image": "models/util/solidlayer.json", "size": "384 256",
                            "config": ["passthrough": true],
                            "origin": "64 32 0", "color": "0 0 0", "solid": true, "effects": effect(10)])
            origin = "-48 64 32"
        case .fullscreenParent:
            objects.append(["id": 100, "image": "models/util/fullscreenlayer.json", "origin": "64 32 0",
                            "effects": effect(10)])
            origin = "144 96 64"
        case .nestedFullscreenParent:
            objects.append(["id": 100, "image": "models/util/solidlayer.json", "size": "256 192",
                            "config": ["passthrough": true],
                            "origin": "64 32 0", "color": "0 0 0", "solid": true, "effects": effect(10)])
            objects.append(["id": 101, "parent": 100, "image": "models/util/fullscreenlayer.json", "origin": "0 0 0",
                            "effects": effect(11)])
            origin = "-46 16 32"
        }
        var text: [String: Any] = [
            "id": 5, "text": "Hi", "font": "fonts/NotoSans-Regular.ttf", "pointsize": 8,
            "padding": "16 16", "origin": origin, "color": "1 1 1", "opaquebackground": false,
            "anchor": "topright", "horizontalalign": "left", "verticalalign": "top", "effects": effect(9),
        ]
        if let parentID = context.parentID {
            text["parent"] = parentID
        }
        objects.append(text)
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 384, "height": 256], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "perspectiveoverridefov": 90,
                        "camerashake": false, "cameraparallax": false],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        return (document, original)
    }

    private func textClearAssertMatrix(_ matrix: simd_float4x4, columns: [[Float]], exact: Bool = false,
                                       label: String, file: StaticString = #filePath, line: UInt = #line) {
        for column in 0 ..< 4 {
            for row in 0 ..< 4 {
                if exact {
                    XCTAssertEqual(matrix[column][row], columns[column][row], label, file: file, line: line)
                } else {
                    XCTAssertEqual(matrix[column][row], columns[column][row], accuracy: 0.000001, label,
                                   file: file, line: line)
                }
            }
        }
    }

    private func textClearAssertColumns(_ actual: [[Float]], expected: [[Float]], label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, 4, label, file: file, line: line)
        guard actual.count == 4 else { return }
        for column in 0 ..< 4 {
            XCTAssertEqual(actual[column].count, 4, label, file: file, line: line)
            guard actual[column].count == 4 else { continue }
            for row in 0 ..< 4 {
                XCTAssertEqual(actual[column][row], expected[column][row], accuracy: 0.000001, label,
                               file: file, line: line)
            }
        }
    }

    private func textClearAssertPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int, rgb: [Int], alpha: Int,
                                      label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let offset = (y * width + x) * 4
        _ = try XCTUnwrap(offset >= 0 && offset + 3 < bytes.count ? true : nil, label, file: file, line: line)
        for channel in 0 ..< 3 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - rgb[channel]), 1, label, file: file, line: line)
        }
        XCTAssertEqual(Int(bytes[offset + 3]), alpha, label, file: file, line: line)
    }
}
#endif
