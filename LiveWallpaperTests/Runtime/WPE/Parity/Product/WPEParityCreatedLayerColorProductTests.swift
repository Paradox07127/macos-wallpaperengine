#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

/// A script-created image layer draws its own config and later colour/alpha writes (140207b50.c:84-93),
/// and its template's draw keeps the template's values.
extension WPEParitySceneDriverTests {
    @objc func testCreatedLayerColourAndAlphaReachOnlyItsOwnDraw() async throws {
        let source = """
        let frame = 0, clone;
        export function update(value) {
          frame += 1;
          if (frame === 2) {
            const config = thisScene.getInitialLayerConfig(thisScene.getLayer('template'));
            config.alpha = 0.25;
            clone = thisScene.createLayer(config);
            if (!clone) throw Error('clone admission');
            clone.origin = new Vec3(136, 48, 0);
          } else if (frame === 3) {
            clone.alpha = 0.5;
            clone.color = new Vec3(1, 0, 0);
          }
          return value;
        }
        """
        let objects: [[String: Any]] = [
            ["id": 101, "name": "controller", "image": "models/util/solidlayer.json", "origin": "24 48 0",
             "size": "12 12", "color": "0 0 1", "alpha": ["value": 1, "script": source]],
            ["id": 20, "name": "template", "image": "models/util/solidlayer.json", "origin": "80 48 0",
             "size": "12 12", "color": "0 1 0", "alpha": 1],
        ]
        let (driver, layer) = try await createdColorDriver(objects: objects)
        defer { driver.cleanup() }
        func owned(_ id: String) throws -> [WPEParityDraw] {
            let renderer = try XCTUnwrap(driver.renderer)
            return renderer.lastFrameDraws.filter { item in
                renderer.frames.contains { $0.owners[item.operation] == id }
            }.map(\.draw)
        }
        func createdID() throws -> String? {
            try XCTUnwrap(driver.renderer).instance.state.commonOrder.first { !["101", "20"].contains($0) }
        }
        func alpha(_ id: String) throws -> Float? {
            guard case let .float(value)? = try owned(id).first?.constants[.fragment]?["g_Alpha"] else { return nil }
            return value
        }
        func color(_ id: String) throws -> [Float]? {
            guard case let .vector(value)? = try owned(id).first?.constants[.fragment]?["g_Color"] else { return nil }
            return value
        }

        _ = try await createdColorFrame(driver, layer: layer, label: "before create")

        var pixels = try await createdColorFrame(driver, layer: layer, label: "create frame")
        let id = try XCTUnwrap(createdID(), "createLayer must admit the template's config")
        XCTAssertEqual(try alpha(id), 0.25)
        XCTAssertEqual(try color(id), [0, 1, 0])
        createdColorPixel(pixels, x: 136, rgb: [0, 64, 0], tolerance: 2)
        XCTAssertEqual(try alpha("20"), 1)
        createdColorPixel(pixels, x: 80, rgb: [0, 255, 0], tolerance: 1)

        pixels = try await createdColorFrame(driver, layer: layer, label: "write frame")
        XCTAssertEqual(try alpha(id), 0.5)
        XCTAssertEqual(try color(id), [1, 0, 0])
        createdColorPixel(pixels, x: 136, rgb: [128, 0, 0], tolerance: 2)
        XCTAssertEqual(try alpha("20"), 1)
        XCTAssertEqual(try color("20"), [0, 1, 0])
        createdColorPixel(pixels, x: 80, rgb: [0, 255, 0], tolerance: 1)
        XCTAssertEqual(try XCTUnwrap(driver.renderer).instance.state.object("20")?.alpha, 1)
    }

    /// Script writes to a clone's effect constants reach only the clone's effect pass (1401e7170.c:441-464).
    @objc func testCreatedEffectCloneConstantWriteReachesOnlyItsEffectPass() async throws {
        let source = """
        let frame = 0, clone;
        export function update(value) {
          frame += 1;
          if (frame === 2) {
            clone = thisScene.createLayer(thisScene.getInitialLayerConfig(thisScene.getLayer('template')));
            if (!clone) throw Error('effect clone admission');
            clone.origin = new Vec3(136, 48, 0);
          } else if (frame === 3) {
            clone.getEffect(0).setMaterialProperty('color', new Vec3(0, 0, 1));
          }
          return value;
        }
        """
        let (_, original) = try sceneInputs()
        let material: [String: Any] = ["passes": [["shader": "genericimage2", "combos": ["VERSION": 2],
                                                   "textures": ["clone-template"],
                                                   "blending": "normal", "cullmode": "nocull",
                                                   "depthtest": "disabled", "depthwrite": "disabled"]]]
        var files = try [
            "models/clone-template.json": JSONSerialization.data(withJSONObject: ["material": "materials/clone-template.json"]),
            "materials/clone-template.json": JSONSerialization.data(withJSONObject: material),
            "materials/clone-template.tex": XCTUnwrap(original.data("materials/util/white.tex")),
        ]
        let tintAssets = try WPEParityProgramAssets(sources: [.directory(XCTUnwrap(original.roots.last).appending(path: "effects/tint"))])
        for path in ["materials/effects/tint.json", "shaders/effects/tint.frag", "shaders/effects/tint.vert"] {
            files[path] = try XCTUnwrap(tintAssets.data(path), path)
        }
        // BLENDMODE 30 with alpha 1 gives max(c) · tint colour.
        let tint: [String: Any] = ["id": 21, "file": "effects/tint/effect.json", "visible": true,
                                   "passes": [["constantshadervalues": ["color": "1 0 0", "alpha": 1]]]]
        let objects: [[String: Any]] = [
            ["id": 101, "name": "controller", "image": "models/util/solidlayer.json", "origin": "24 48 0",
             "size": "12 12", "color": "0 0 1", "alpha": ["value": 1, "script": source]],
            ["id": 20, "name": "template", "image": "models/clone-template.json", "origin": "80 48 0",
             "size": "12 12", "color": "0 1 0", "alpha": 1, "effects": [tint]],
        ]
        let (driver, layer) = try await createdColorDriver(objects: objects, files: files)
        defer { driver.cleanup() }
        func rgb(_ pixels: [UInt8], x: Int) -> [Int] {
            (0 ..< 3).map { Int(pixels[(48 * 160 + x) * 4 + $0]) }
        }

        _ = try await createdColorFrame(driver, layer: layer, label: "before create")
        _ = try await createdColorFrame(driver, layer: layer, label: "create frame")
        let pixels = try await createdColorFrame(driver, layer: layer, label: "write frame")
        let clone = rgb(pixels, x: 136)
        XCTAssertTrue(clone[2] >= 200 && clone[0] <= 8 && clone[1] <= 8, "clone pixel \(clone) is not blue")
        let template = rgb(pixels, x: 80)
        XCTAssertTrue(template[0] >= 200 && template[1] <= 8, "template pixel \(template) is not red")
    }

    private func createdColorDriver(objects: [[String: Any]],
                                    files: [String: Data] = [:]) async throws -> (WPEParitySceneDriver, RecordingLayer) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        var assets: WPEParityProgramAssets
        do {
            (_, assets) = try sceneInputs()
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityCreatedLayerColorProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets unavailable: \(error)"]
            ))
        }
        if !files.isEmpty {
            assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }] + assets.sources)
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(reason):
            throw NSError(domain: "WPEParityCreatedLayerColorProductTests.RequiredInputs", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Required product toolchain unavailable: \(reason)"])
        }
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityCreatedLayerColorProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required isolated product defaults"])
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
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 160, "height": 96], "clearenabled": true,
                        "clearcolor": "0 0 0", "camerashake": false, "cameraparallax": false],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        let driver = try WPEParitySceneDriver(device: device)
        var handedOff = false
        defer {
            if !handedOff {
                driver.cleanup()
            }
        }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        let renderer = try XCTUnwrap(driver.renderer)
        let script = try XCTUnwrap(renderer.instance.script, "actual Driver load must attach SceneScript")
        XCTAssertEqual(script.engine.bindings.filter(\.compiled).count, 1)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 160, height: 96)
        handedOff = true
        return (driver, layer)
    }

    private func createdColorFrame(_ driver: WPEParitySceneDriver, layer: RecordingLayer,
                                   label: String) async throws -> [UInt8] {
        try await present(driver, layer: layer, label: label)
        let renderer = try XCTUnwrap(driver.renderer)
        let script = try XCTUnwrap(renderer.instance.script)
        XCTAssertTrue(driver.hasPresentedFrame)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        let texture = try XCTUnwrap(layer.lastTexture, "required actual presented drawable")
        XCTAssertEqual([texture.width, texture.height], [160, 96])
        // The present into this sRGB-tagged drawable re-encodes partial values; the backbuffer holds the blend result.
        return try readBack(renderer.backbuffer, device: texture.device)
    }

    private func createdColorPixel(_ pixels: [UInt8], x: Int, rgb: [Int], tolerance: Int,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard pixels.count == 160 * 96 * 4 else {
            XCTFail("Required full drawable pixels", file: file, line: line)
            return
        }
        let offset = (48 * 160 + x) * 4
        for channel in 0 ..< 3 {
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset + channel]) - rgb[channel]), tolerance,
                                     "x=\(x), channel=\(channel)", file: file, line: line)
        }
    }
}
#endif
