#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// An image config with effects clones a loaded template only when its effects equal the template's own.
extension WPEParitySceneDriverTests {
    @objc func testCreatedLayerWithEffectsDifferentFromTemplateIsNotCloned() async throws {
        let source = """
        let frame = 0;
        export function update(value) {
          frame += 1;
          if (frame === 2) {
            const config = thisScene.getInitialLayerConfig(thisScene.getLayer('template'));
            config.effects[0].visible = false;
            if (thisScene.createLayer(config)) throw Error('changed effects cloned the template');
          } else if (frame === 3) {
            if (!thisScene.createLayer(thisScene.getInitialLayerConfig(thisScene.getLayer('template'))))
              throw Error('effect clone admission');
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
        let tint: [String: Any] = ["id": 21, "file": "effects/tint/effect.json", "visible": true]
        let objects: [[String: Any]] = [
            ["id": 101, "name": "controller", "image": "models/util/solidlayer.json", "origin": "24 48 0",
             "size": "12 12", "color": "0 0 1", "alpha": ["value": 1, "script": source]],
            ["id": 20, "name": "template", "image": "models/clone-template.json", "origin": "80 48 0",
             "size": "12 12", "effects": [tint]],
        ]
        let (driver, layer) = try await effectsMatchDriver(objects: objects, files: files)
        defer { driver.cleanup() }
        func created() throws -> [String] {
            try XCTUnwrap(driver.renderer).instance.state.commonOrder.filter { !["101", "20"].contains($0) }
        }

        try await effectsMatchFrame(driver, layer: layer, label: "before create")
        try await effectsMatchFrame(driver, layer: layer, label: "changed effects frame")
        XCTAssertEqual(try created(), [], "A config whose effects differ from the template's must not clone it")
        try await effectsMatchFrame(driver, layer: layer, label: "matching effects frame")
        XCTAssertEqual(try created().count, 1, "A config with the template's own effects must clone it")
    }

    private func effectsMatchDriver(objects: [[String: Any]],
                                    files: [String: Data]) async throws -> (WPEParitySceneDriver, RecordingLayer) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        var assets: WPEParityProgramAssets
        do {
            (_, assets) = try sceneInputs()
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityCreatedLayerEffectsMatchProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets unavailable: \(error)"]
            ))
        }
        assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }] + assets.sources)
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(reason):
            throw NSError(domain: "WPEParityCreatedLayerEffectsMatchProductTests.RequiredInputs", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Required product toolchain unavailable: \(reason)"])
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
        let script = try XCTUnwrap(XCTUnwrap(driver.renderer).instance.script, "actual Driver load must attach SceneScript")
        XCTAssertEqual(script.engine.bindings.filter(\.compiled).count, 1)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 160, height: 96)
        handedOff = true
        return (driver, layer)
    }

    private func effectsMatchFrame(_ driver: WPEParitySceneDriver, layer: RecordingLayer, label: String) async throws {
        try await present(driver, layer: layer, label: label)
        let script = try XCTUnwrap(XCTUnwrap(driver.renderer).instance.script)
        XCTAssertEqual(script.engine.exceptionCount, 0, "\(label): " + script.engine.exceptions.joined(separator: "\n"))
    }
}
#endif
