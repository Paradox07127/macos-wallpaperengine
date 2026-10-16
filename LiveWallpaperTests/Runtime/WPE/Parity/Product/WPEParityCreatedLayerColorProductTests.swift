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
            try XCTUnwrap(driver.renderer).state.commonOrder.first { !["101", "20"].contains($0) }
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
        XCTAssertEqual(try XCTUnwrap(driver.renderer).state.object("20")?.alpha, 1)
    }

    private func createdColorDriver(objects: [[String: Any]]) async throws -> (WPEParitySceneDriver, RecordingLayer) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let assets: WPEParityProgramAssets
        do {
            (_, assets) = try sceneInputs()
        } catch {
            throw NSError(domain: "WPEParityCreatedLayerColorProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets unavailable: \(error)"])
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
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
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
        let script = try XCTUnwrap(renderer.script, "actual Driver load must attach SceneScript")
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
        let script = try XCTUnwrap(renderer.script)
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
