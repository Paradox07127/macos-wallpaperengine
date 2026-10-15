#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// Complete native1401ee3a0 ASM uses the number of matched names, then clears declaration ordinals.
    /// A function containing only second must clear first with first's declared RGBA, not second.
    @objc func testMaterialFunctionSecondNameClearsFirstDeclaredFramebuffer() async throws {
        try await materialFunctionProduct(function: "onlySecond",
                                          cleared: [[0, 0, 255, 255], [0, 255, 0, 255], [0, 0, 255, 255]],
                                          presented: [0, 255, 255, 255])
    }

    /// The stored order third,first is not the execution order: native clears the first two declarations.
    @objc func testMaterialFunctionReversedNamesClearFirstTwoDeclaredFramebuffers() async throws {
        try await materialFunctionProduct(function: "reverseTwo",
                                          cleared: [[0, 0, 255, 255], [255, 0, 0, 255], [0, 0, 255, 255]],
                                          presented: [255, 0, 255, 255])
    }

    /// A missing name is a returning no-op in both init and update, rather than an absent host method.
    @objc func testMaterialFunctionMissingNamePreservesThreeRenderedFramebuffers() async throws {
        try await materialFunctionProduct(function: "missing",
                                          cleared: [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]],
                                          presented: [255, 255, 255, 255])
    }

    private nonisolated(nonsending) func materialFunctionProduct(function: String, cleared: [[Int]],
                                                                 presented: [Int]) async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (original, compiler) = try materialFunctionRequiredInputs()
        let (document, assets) = try materialFunctionDocument(original: original, function: function)
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityMaterialFunctionProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required isolated product defaults are absent"])
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
                              drawableSize: CGSize(width: 32, height: 32), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        let renderer = try XCTUnwrap(driver.renderer)
        let script = try XCTUnwrap(renderer.script, "the actual Driver must attach SceneScript")
        XCTAssertEqual(script.engine.bindings.filter(\.compiled).count, 1)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(renderer.state.scriptField("solid", of: "1"), .vector(SIMD4(0, 0, 0, 0)),
                       "init must return from the real missing-function host call before writing its witness")
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.colorspace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 32, height: 32)

        let prefilled = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]
        // Frame1 really writes RGB through three original opacity draws. Frames2 and3 use alpha0;
        // their transparent writes cannot overwrite either a function clear or the unchanged third FBO.
        let stages = [("prefill", prefilled, [255, 255, 255, 255], Float(1), Float(0)),
                      ("invoke", cleared, presented, Float(0), Float(1)),
                      ("hold", cleared, presented, Float(0), Float(1))]
        var persistent: [MTLTexture] = []
        for (label, expectedFBOs, expectedPresent, writerAlpha, completionZ) in stages {
            try await present(driver, layer: layer, label: "material function \(function) \(label)")
            XCTAssertTrue(driver.hasPresentedFrame)
            XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
            XCTAssertEqual(renderer.skipped, [:], "\(label): \(renderer.skipped)")
            XCTAssertTrue(renderer.fallbackTextures.isEmpty, "\(label): \(renderer.fallbackTextures)")
            XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
            XCTAssertEqual(try XCTUnwrap(renderer.state.object("1")).origin.z, completionZ,
                           "\(label): the update must return from executeMaterialFunction")
            let frame = try XCTUnwrap(renderer.frames.first)
            let encodedEffect = renderer.lastFrameDraws.filter { entry in
                guard case let .scene(draw)? = frame.draws[entry.operation] else { return false }
                return draw.objectID == "1" && draw.effectID == "7"
            }
            XCTAssertEqual(encodedEffect.count, 6, "\(label): all three real writers and all three real readers must encode")
            let ids: [WPEResourceID] = ["first_7", "second_7", "third_7"]
            var actual: [MTLTexture] = []
            for (index, id) in ids.enumerated() {
                let texture = try XCTUnwrap(renderer.renderTarget(id), "\(label): actual \(id)")
                XCTAssertEqual([texture.width, texture.height, texture.sampleCount, texture.mipmapLevelCount], [32, 32, 1, 1])
                XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
                XCTAssertEqual(try XCTUnwrap(frame.resources.first { $0.id == id }).lifetime, .persistent)
                if !persistent.isEmpty {
                    XCTAssertTrue(texture === persistent[index], "\(label): persistent identity for \(id)")
                }
                try materialFunctionAssertColor(readBack(texture, device: device), width: 32, rgba: expectedFBOs[index],
                                                label: "\(function) \(label) \(id)")
                actual.append(texture)
            }
            if persistent.isEmpty {
                persistent = actual
            }
            XCTAssertFalse(actual[0] === actual[1])
            XCTAssertFalse(actual[1] === actual[2])
            XCTAssertFalse(actual[0] === actual[2])

            for (index, target) in ids.enumerated() {
                let pass = WPEPassIdentity("1/7/\(4 + index)")
                let operation = try XCTUnwrap(frame.draws.first { entry in
                    guard case let .scene(draw) = entry.value else { return false }
                    return draw.pass == pass
                })
                guard case let .scene(description) = operation.value else {
                    return XCTFail("required original opacity writer description")
                }
                XCTAssertEqual(description.shader, "effects/opacity")
                XCTAssertEqual(description.target, target)
                XCTAssertEqual(description.blend, .translucent)
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation.key }?.draw)
                XCTAssertGreaterThan(draw.indexCount + draw.vertexCount, 0, "actual original writer must encode")
                _ = try XCTUnwrap(draw.textures["g_Texture0"], "actual controlled RGB TEX must bind")
                guard case let .float(alpha)? = draw.constants[.fragment]?["g_UserAlpha"] else {
                    return XCTFail("the original opacity shader must consume its live material alpha")
                }
                XCTAssertEqual(alpha, writerAlpha, "\(label): writers must stop before the function clear")
            }
            for (index, source) in ids.enumerated() {
                let pass = WPEPassIdentity("1/7/\(7 + index)")
                let operation = try XCTUnwrap(frame.draws.first { entry in
                    guard case let .scene(draw) = entry.value else { return false }
                    return draw.pass == pass
                })
                guard case let .scene(description) = operation.value else {
                    return XCTFail("required original passthrough reader description")
                }
                XCTAssertEqual(description.shader, "passthrough")
                XCTAssertTrue(description.reads.contains(source))
                XCTAssertEqual(description.target, WPEParitySceneResource.backbuffer)
                XCTAssertEqual(description.blend, .additive)
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation.key }?.draw)
                XCTAssertGreaterThan(draw.indexCount + draw.vertexCount, 0, "actual original reader must encode")
                XCTAssertTrue(try XCTUnwrap(draw.textures["g_Texture0"]) === actual[index],
                              "\(label): the actual original shader must read \(source)")
            }
            try materialFunctionAssertColor(readBack(renderer.backbuffer, device: device), width: 32, rgba: expectedPresent,
                                            label: "\(function) \(label) raw original readers")
            let shown = try XCTUnwrap(layer.lastTexture, "required actual presented drawable")
            XCTAssertEqual([shown.width, shown.height], [32, 32])
            try materialFunctionAssertColor(readBack(shown, device: device), width: 32, rgba: expectedPresent,
                                            label: "\(function) \(label) displayed original readers")
        }
    }

    private func materialFunctionRequiredInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        let base: WPEParityProgramAssets
        do {
            (_, base) = try sceneInputs()
        } catch {
            throw NSError(domain: "WPEParityMaterialFunctionProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets unavailable: \(error)"])
        }
        // Construct the existing compiler with the actual shipping components in this host bundle.
        // Resolve symlinks before admission; existence alone cannot establish a component's bundle origin.
        for key in ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER",
                    "TEST_RUNNER_WPE_SHADERC", "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"] {
            guard ProcessInfo.processInfo.environment[key] == nil else {
                throw NSError(domain: "WPEParityMaterialFunctionProductTests.ToolOverride", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Required bundled compiler cannot use \(key)"])
            }
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
            .resolvingSymlinksInPath().standardizedFileURL
        let toolURLs = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? url : nil,
                              "required shipping component must resolve inside current Contents: \(url.path)")
            _ = try XCTUnwrap(FileManager.default.fileExists(atPath: url.path) ? url : nil,
                              "required app-bundle toolchain input \(url.path)")
            return url
        }
        let toolHashes = try toolURLs.map { url in
            try SHA256.hash(data: Data(contentsOf: url, options: .alwaysMapped)).map { String(format: "%02x", $0) }.joined()
        }
        let compiler = try WPEParityHelperShaderCompiler(helper: toolURLs[0], dxcompiler: toolURLs[1],
                                                         metalIRConverter: toolURLs[2],
                                                         workDirectory: scratch.appending(path: "material-function-shaderc"))
        _ = try XCTUnwrap(compiler.compilerIdentity == "wpe-shaderc " + toolHashes.joined(separator: " ") ? true : nil,
                          "actual compiler identity must match the three admitted bundle component bytes")
        print("material function product toolchain origin=app-bundle helper=\(toolURLs[0].path) "
            + "dxcompiler=\(toolURLs[1].path) msc=\(toolURLs[2].path) compilerIdentity=\(compiler.compilerIdentity)")
        let root = try XCTUnwrap(base.roots.last, "required original WPE asset root")
        let assets = WPEParityProgramAssets(sources: base.sources + [.directory(root.appending(path: "effects/opacity"))])
        for (path, expected) in [
            ("materials/effects/opacity.json", "f32a0ee2080b2c79ee395e950ea072e28778d279c5d62e1cc76adbcd2d733747"),
            ("shaders/effects/opacity.vert", "45803f340c80659ca4726cdea107eb017e7638a64a1b9ff7d30093d1938a738e"),
            ("shaders/effects/opacity.frag", "418d565af5509983802c17d1ed901b24b02a6aa8183396cc511ff5f5eefbeb47"),
            ("materials/util/passthrough.json", "40fe00ef9751174e1e2a509968c8d05e92843a23d4d68b3779f9e35a26a3e667"),
            ("shaders/passthrough.vert", "ff6cd2bb166ce427c73058f3f77f338442d83fab9883f302e31bbffd81fa5317"),
            ("shaders/passthrough.frag", "db8586701eeda50c731af880411451be673180049ede8def28932d7180052109"),
            ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
            ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
            ("shaders/flat.vert", "3659d0455c48d9c57b329675c42ce0e7f76628865bc2ce7c8452e1b63fdb9805"),
            ("shaders/flat.frag", "7e0503a1821089475b884e4e8b0fb1987108f7d00c5cb353da7695eac7796477"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
        ] {
            let data = try XCTUnwrap(assets.data(path), "required original consumer input \(path)")
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            _ = try XCTUnwrap(actual == expected ? true : nil, "required pinned original input \(path): \(actual)")
        }
        return (assets, compiler)
    }

    private func materialFunctionDocument(original: WPEParityProgramAssets, function: String)
        throws -> (WPESceneDocument, WPEParityProgramAssets) {
        let names = ["first", "second", "third"]
        let clears = ["0 0 1 1", "1 0 0 1", "0 1 0 1"]
        var passes: [[String: Any]] = []
        // Each pair executes twice, leaving I. Every FBO has a real swap partner and persistent lifetime.
        for pair in [("first", "second"), ("second", "third")] {
            for _ in 0 ..< 2 {
                passes.append(["command": "swap", "source": pair.0, "target": pair.1])
            }
        }
        for name in names {
            passes.append(["material": "materials/effects/opacity.json", "target": name, "compose": true,
                           "blending": "translucent", "bind": [["index": 0, "name": "material-function-\(name)"],
                                                               ["index": 1, "name": "material-function-mask"]]])
        }
        for name in names {
            passes.append(["material": "materials/util/passthrough.json", "blending": "additive",
                           "bind": [["index": 0, "name": name]]])
        }
        let effect: [String: Any] = [
            "fbos": names.indices.map { ["name": names[$0], "width": 32, "height": 32, "unique": true,
                                         "format": "rgba8888", "clear": clears[$0]] as [String: Any] },
            "functions": ["onlySecond": ["action": "clear", "fbos": ["second"]],
                          "reverseTwo": ["action": "clear", "fbos": ["third", "first"]]],
            "passes": passes,
        ]
        var files = try ["effects/material-function-product.json": JSONSerialization.data(withJSONObject: effect)]
        for (index, name) in (names + ["mask"]).enumerated() {
            var tex = Data("TEXV0004\0".utf8)
            for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
                withUnsafeBytes(of: value.littleEndian) { tex.append(contentsOf: $0) }
            }
            var rgb = [UInt8](repeating: 255, count: 4)
            if index < 3 {
                rgb = [0, 0, 0, 255]
                rgb[index] = 255
            }
            tex.append(contentsOf: rgb)
            files["materials/material-function-\(name).tex"] = tex
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        var overrides = [[String: Any]](repeating: [:], count: 10)
        for index in 4 ... 6 {
            overrides[index] = ["constantshadervalues": ["alpha": 1], "combos": ["MASK": 1]]
        }
        // passthrough uses #ifdef TRANSFORM, so the first two full-screen readers must omit the key entirely.
        // The final reader is a layer mesh and therefore explicitly transforms that pixel-sized geometry.
        overrides[9] = ["combos": ["TRANSFORM": 1]]
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "hdr": false,
                        "camerashake": false, "cameraparallax": false],
            "objects": [["id": 1, "name": "same-owner material function", "image": "models/util/solidlayer.json",
                         "origin": "16 16 0", "size": "32 32", "solid": true, "colorBlendMode": 31,
                         "alpha": ["value": 1, "script": """
                         let frames = 0;
                         export function init(value) {
                           thisLayer.getEffect(0).executeMaterialFunction('missing');
                           thisLayer.solid = false;
                           return value;
                         }
                         export function update(value) {
                           frames += 1;
                           if (frames === 2) {
                             const effect = thisLayer.getEffect(0);
                             effect.setMaterialProperty('alpha', 0);
                             effect.executeMaterialFunction('\(function)');
                             thisLayer.origin = new Vec3(16, 16, 1);
                           }
                           return value;
                         }
                         """],
                         "effects": [["id": 7, "file": "effects/material-function-product.json", "visible": true,
                                      "passes": overrides]]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        return (document, assets)
    }

    private func materialFunctionAssertColor(_ bytes: [UInt8], width: Int, rgba: [Int], label: String) throws {
        XCTAssertEqual(bytes.count, width * 32 * 4, label)
        // Fixed interior samples, including every quadrant; no matrix/output-derived ROI or tolerance.
        for (x, y) in [(4, 4), (27, 4), (16, 16), (4, 27), (27, 27)] {
            let offset = (y * width + x) * 4
            _ = try XCTUnwrap(offset + 3 < bytes.count ? true : nil, "\(label): required pixel \(x),\(y)")
            for channel in 0 ..< 4 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - rgba[channel]), 1,
                                         "\(label) pixel(\(x),\(y)) RGBA[\(channel)]")
            }
        }
    }
}
#endif
