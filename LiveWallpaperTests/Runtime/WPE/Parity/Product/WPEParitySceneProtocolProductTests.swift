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

/// Dedicated scene callbacks use their own phase/resolver protocol, not the native method overload mask.
/// Every result reaches an original solidlayer draw through the actual Driver and bundled compiler route.
extension WPEParitySceneDriverTests {
    @objc func testSceneProtocolRejectsEightGlobalCallsButAllowsInitAndUpdateQueries() async throws {
        let source = """
        const calls = [
          () => thisScene.getLayer('controller'),
          () => thisScene.getLayerCount(),
          () => thisScene.enumerateLayers(),
          () => thisScene.destroyLayer(),
          () => thisScene.createLayer('not-a-native-resource'),
          () => thisScene.sortLayer(),
          () => thisScene.getLayerIndex('controller'),
          () => thisScene.getInitialLayerConfig()
        ];
        const rejected = calls.map(call => {
          try { call(); return false; }
          catch (error) { console.log('scene global rejection: ' + String(error.message)); return true; }
        });
        export function init(value) {
          for (let i = 0; i < rejected.length; i++)
            thisScene.getLayer('phase ' + i).color = rejected[i] ? new Vec3(0, 1, 0) : new Vec3(1, 0, 0);
          const config = thisScene.getInitialLayerConfig(thisLayer);
          const ready = thisScene.getLayerCount() === 9 && thisScene.enumerateLayers().length === 9
            && thisScene.getLayer(0) === thisLayer && thisScene.getLayerIndex(thisLayer) === 0
            && config.name === 'controller';
          thisLayer.color = ready ? new Vec3(1, 1, 0) : new Vec3(1, 0, 0);
          return value;
        }
        export function update(value) {
          const layers = thisScene.enumerateLayers();
          const ready = thisScene.getLayerCount() === 9 && layers.length === 9 && layers[0] === thisLayer
            && thisScene.getLayer('controller') === thisLayer && thisScene.getLayerIndex(thisLayer) === 0;
          thisLayer.color = ready ? new Vec3(0, 0, 1) : new Vec3(1, 0, 0);
          return value;
        }
        """
        var objects = [sceneProtocolPanel(id: 101, name: "controller", x: 80, y: 24, script: source)]
        for index in 0 ..< 8 {
            objects.append(sceneProtocolPanel(id: 201 + index, name: "phase \(index)", x: 10 + 20 * index, y: 64))
        }
        let (driver, layer) = try await sceneProtocolDriver(objects: objects)
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(try XCTUnwrap(renderer.state.object("101")).color, SIMD3<Float>(1, 1, 0),
                       "init must query the loaded scene, after all eight global calls were attempted")
        for index in 0 ..< 8 {
            XCTAssertEqual(try XCTUnwrap(renderer.state.object(String(201 + index))).color, SIMD3<Float>(0, 1, 0),
                           "global scene callback \(index) must reject before inspecting its arguments")
        }
        let pixels = try await sceneProtocolFrame(driver, layer: layer, label: "phase update")
        // Authored Y is up; fixed client-pixel Y is down in this 96-pixel fixture.
        sceneProtocolPixel(pixels, x: 80, y: 72, rgb: [0, 0, 255])
        for index in 0 ..< 8 {
            sceneProtocolPixel(pixels, x: 10 + 20 * index, y: 32, rgb: [0, 255, 0])
        }
    }

    @objc func testSceneProtocolUsesOneResolverAndStableDenseWrapperIdentity() async throws {
        let source = """
        function check() {
          const numeric = thisScene.getLayer(1);
          const survivor = thisScene.getLayer(2);
          const byNumber = thisScene.getLayer(0.9) === thisLayer
            && thisScene.getLayer(1.9) === numeric && thisScene.getLayer(4294967297.75) === numeric
            && thisScene.getLayerIndex(4294967297.75) === 1;
          const byString = thisScene.getLayer('23') === thisLayer && thisScene.getLayer('303') === survivor
            && thisScene.getLayerIndex('23') === 0 && thisScene.getLayerIndex('303') === 2;
          const layers = thisScene.enumerateLayers();
          const identity = thisScene.getLayer(thisLayer) === thisLayer && thisScene.getLayer(numeric) === numeric
            && thisScene.getLayerIndex(numeric) === 1 && thisScene.getLayerCount() === 3 && layers.length === 3
            && layers.every((layer, index) => layer === thisScene.getLayer(index))
            && thisScene.getLayer({ id: 23 }) == null;
          const numberConfig = thisScene.getInitialLayerConfig(4294967297.75);
          const stringConfig = thisScene.getInitialLayerConfig('303');
          const wrapperConfig = thisScene.getInitialLayerConfig(numeric);
          const configs = numberConfig && stringConfig && wrapperConfig
            && numberConfig.name === 'decimal target' && stringConfig.name === 'survivor'
            && wrapperConfig.name === 'decimal target' && !('id' in numberConfig);
          thisLayer.color = byNumber && identity ? new Vec3(0, 1, 0) : new Vec3(1, 0, 0);
          numeric.color = byString ? new Vec3(0, 1, 0) : new Vec3(1, 0, 0);
          survivor.color = configs ? new Vec3(0, 1, 0) : new Vec3(1, 0, 0);
        }
        export function init(value) { check(); return value; }
        export function update(value) { check(); return value; }
        """
        let objects = [sceneProtocolPanel(id: 101, name: "23", x: 24, script: source),
                       sceneProtocolPanel(id: 23, name: "decimal target", x: 80),
                       sceneProtocolPanel(id: 303, name: "survivor", x: 136)]
        let (driver, layer) = try await sceneProtocolDriver(objects: objects)
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        for id in ["101", "23", "303"] {
            XCTAssertEqual(try XCTUnwrap(renderer.state.object(id)).color, SIMD3<Float>(0, 1, 0), "init \(id)")
        }
        for frame in 1 ... 2 {
            let pixels = try await sceneProtocolFrame(driver, layer: layer, label: "resolver frame \(frame)")
            for x in [24, 80, 136] {
                sceneProtocolPixel(pixels, x: x, y: 48, rgb: [0, 255, 0])
            }
        }
    }

    @objc func testSceneProtocolPendingEnumerationIsDenseAndFlushRemovesTheActualDraw() async throws {
        let source = """
        let frame = 0;
        let survivor;
        let removed;
        export function init(value) {
          survivor = thisScene.getLayer('survivor');
          return value;
        }
        export function update(value) {
          frame += 1;
          if (frame === 1) {
            thisLayer.color = new Vec3(0, 1, 0);
            return value;
          }
          if (frame === 2) {
            removed = thisScene.getLayer('remove target');
            const sameSweep = thisScene.getLayer('same-sweep target');
            const accepted = thisScene.destroyLayer(removed);
            const repeated = thisScene.destroyLayer(removed);
            const secondAccepted = thisScene.destroyLayer(sameSweep);
            const layers = thisScene.enumerateLayers();
            const pending = accepted === true && repeated === true && secondAccepted === true
              && thisScene.getLayerCount() === 2
              && layers.length === 2 && layers[0] === thisLayer && layers[1] === survivor
              && layers.every(layer => layer !== removed)
              && thisScene.getLayerIndex(survivor) === 3 && thisScene.getLayer(3) === survivor
              && thisScene.getLayer('remove target') === null
              && thisScene.getInitialLayerConfig('remove target') === null
              && removed.alpha === 1 && removed.getEffectCount() === 0;
            thisLayer.color = pending ? new Vec3(0, 1, 0) : new Vec3(1, 0, 0);
          } else {
            // A script-owned property cannot resurrect the native receiver or its cached slot.
            removed.__alive = true;
            const layers = thisScene.enumerateLayers();
            const assigned = (removed.alpha = 0.375);
            const flushed = thisScene.getLayerCount() === 1 && layers.length === 1
              && layers[0] === thisLayer && thisLayer.brightness === 2
              && removed.name === undefined && removed.alpha === undefined
              && removed.getEffectCount() === undefined && assigned === 0.375;
            thisLayer.color = flushed ? new Vec3(0, 0, 1) : new Vec3(1, 0, 0);
          }
          return value;
        }
        """
        let destroySource = """
        export function destroy() {
          const layers = thisScene.enumerateLayers();
          const absent = thisScene.getLayer('remove target') === null && thisScene.getLayerCount() === 3
            && layers.length === 3 && layers.every(layer => layer !== thisLayer);
          // Do not assert the unmeasured pending-name branch's return. If it queues a member already in
          // this flush's snapshot, successful removal must still erase that member from live pending.
          thisScene.destroyLayer('same-sweep target');
          const accepted = thisScene.destroyLayer('survivor');
          thisScene.getLayer('controller').brightness = absent && accepted === true ? 2 : 99;
        }
        """
        let objects = [sceneProtocolPanel(id: 101, name: "controller", x: 24, script: source),
                       sceneProtocolPanel(id: 20, name: "remove target", x: 80, color: "0 1 1", script: destroySource),
                       sceneProtocolPanel(id: 40, name: "same-sweep target", x: 108, color: "1 0 1"),
                       sceneProtocolPanel(id: 303, name: "survivor", x: 136, color: "0 1 0")]
        let (driver, layer) = try await sceneProtocolDriver(objects: objects, expectedScripts: 2)
        defer { driver.cleanup() }
        for frame in 1 ... 3 {
            if frame > 1 {
                let previousID = try ObjectIdentifier(XCTUnwrap(driver.renderer))
                weak var previousRenderer = driver.renderer
                // Rebuild before each flush: the first keeps all members, the second must retain deletion.
                // The actual drawable stays160×96, so the fixed client-pixel oracle is unchanged.
                driver.updateSurfaceGeometry(drawableSize: frame == 2 ? CGSize(width: 80, height: 48)
                    : CGSize(width: 160, height: 96))
                XCTAssertTrue(driver.needsReplan)
                let replanned = await driver.replan()
                XCTAssertTrue(replanned)
                XCTAssertNotEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer)), previousID)
                XCTAssertNil(previousRenderer, "The continuing script must not keep or require its old renderer")
            }
            let pixels = try await sceneProtocolFrame(driver, layer: layer, label: "pending frame \(frame)")
            sceneProtocolPixel(pixels, x: 24, y: 48, rgb: frame < 3 ? [0, 255, 0] : [0, 0, 255])
            sceneProtocolPixel(pixels, x: 80, y: 48, rgb: frame == 1 ? [0, 255, 255] : [0, 0, 0])
            sceneProtocolPixel(pixels, x: 108, y: 48, rgb: frame == 1 ? [255, 0, 255] : [0, 0, 0])
            sceneProtocolPixel(pixels, x: 136, y: 48, rgb: frame < 3 ? [0, 255, 0] : [0, 0, 0])
            let renderer = try XCTUnwrap(driver.renderer)
            if frame > 1 {
                XCTAssertNil(renderer.state.object("20"), "Removal must leave live membership, not just hide a draw")
                XCTAssertNil(renderer.state.object("40"))
                XCTAssertFalse(renderer.frames.contains { $0.owners.values.contains("20") },
                               "The actual composed graph must no longer contain the removed owner")
                XCTAssertEqual(renderer.state.object("101")?.brightness, 2,
                               "Destroy must query the actual common scene after removal, then enqueue the next sweep")
                if frame == 2 {
                    XCTAssertNotNil(renderer.state.object("303"), "Callback requests wait for the next flush")
                } else {
                    XCTAssertNil(renderer.state.object("303"))
                    XCTAssertFalse(renderer.frames.contains { $0.owners.values.contains("303") })
                }
            } else {
                XCTAssertNotNil(renderer.state.object("20"))
            }
        }
    }

    @objc func testSceneSortReordersActualDrawCursorAndSurvivesResize() async throws {
        // The ordinary helper below must use these actual bundled inputs; no environment fallback is admitted.
        for key in ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER",
                    "TEST_RUNNER_WPE_SHADERC", "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"] {
            XCTAssertNil(ProcessInfo.processInfo.environment[key], key)
            _ = try XCTUnwrap(ProcessInfo.processInfo.environment[key] == nil ? true : nil, key)
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let components = ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
        let hashes = try components.map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath()
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil, "bundled \(path)")
            return try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let compiler = try WPEParityShaderToolchain.makeCompiler().get()
        XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + hashes.joined(separator: " "))
        let (_, assets) = try sceneInputs()
        for (path, expected) in [
            ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
            ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
            ("shaders/flat.vert", "3659d0455c48d9c57b329675c42ce0e7f76628865bc2ce7c8452e1b63fdb9805"),
            ("shaders/flat.frag", "7e0503a1821089475b884e4e8b0fb1987108f7d00c5cb353da7695eac7796477"),
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
        ] {
            let data = try XCTUnwrap(assets.data(path), path)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected, path)
        }
        func hit(_ witness: String) -> String {
            """
            let hits = 0;
            export function cursorMove(event) {
              hits += 1;
              thisScene.getLayer('\(witness)').color = hits % 3 === 1 ? new Vec3(1, 0, 0)
                : hits % 3 === 2 ? new Vec3(0, 1, 0) : new Vec3(0, 0, 1);
            }
            """
        }
        let control = """
        let frames = 0;
        export function update(value) {
          frames += 1;
          if (frames === 2 || frames === 4) {
            const red = thisScene.getLayer('red');
            const moved = thisScene.sortLayer(red, frames === 2 ? -1 : 0);
            const index = frames === 2 ? 4 : 0;
            const ready = moved === true && thisScene.getLayerIndex(red) === index
              && thisScene.getLayer(index) === red && thisScene.enumerateLayers()[index] === red;
            thisLayer.brightness = ready ? frames : 99;
          }
          return value;
        }
        """
        var controller = sceneProtocolPanel(id: 101, name: "controller", x: 80, y: 80, script: control)
        controller["solid"] = false
        var red = sceneProtocolPanel(id: 10, name: "red", x: 80, color: "1 0 0", script: hit("red witness"))
        var green = sceneProtocolPanel(id: 20, name: "green", x: 80, color: "0 1 0", script: hit("green witness"))
        red["disablepropagation"] = true
        green["disablepropagation"] = true
        red["solid"] = true
        green["solid"] = true
        var redWitness = sceneProtocolPanel(id: 30, name: "red witness", x: 24, color: "0 0 0")
        var greenWitness = sceneProtocolPanel(id: 40, name: "green witness", x: 136, color: "0 0 0")
        redWitness["solid"] = false
        greenWitness["solid"] = false
        let (driver, layer) = try await sceneProtocolDriver(objects: [controller, red, green, redWitness, greenWitness],
                                                            expectedScripts: 3)
        defer { driver.cleanup() }
        let reds = [[0, 0, 0], [0, 0, 0], [255, 0, 0], [0, 255, 0], [0, 255, 0]]
        let greens = [[255, 0, 0], [0, 255, 0], [0, 255, 0], [0, 255, 0], [0, 0, 255]]
        for frame in 1 ... 5 {
            if frame == 3 || frame == 4 {
                weak var previous = driver.renderer
                driver.updateSurfaceGeometry(drawableSize: frame == 3 ? CGSize(width: 80, height: 48)
                    : CGSize(width: 160, height: 96))
                XCTAssertTrue(driver.needsReplan)
                let replanned = await driver.replan()
                XCTAssertTrue(replanned)
                XCTAssertNil(previous, "continued script cannot retain the old renderer")
            }
            // Move within both authored quads on every cursor pass. Sorting happens later in update, so the
            // current drawing changes immediately and the cursor's occlusion order changes on the next frame.
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                                     pointer: SIMD2(0.5 + Double(frame - 1) / 160, 0.5), buttonDown: false))
            try await settle(driver, label: "common sort \(frame)")
            XCTAssertEqual(command.status, .completed)
            XCTAssertNil(command.error)
            let renderer = try XCTUnwrap(driver.renderer)
            let script = try XCTUnwrap(renderer.script)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
            let pixels = try readBack(XCTUnwrap(layer.lastTexture), device: renderer.backbuffer.device)
            sceneProtocolPixel(pixels, x: 80, y: 48, rgb: frame == 2 || frame == 3 ? [255, 0, 0] : [0, 255, 0])
            sceneProtocolPixel(pixels, x: 24, y: 48, rgb: reds[frame - 1])
            sceneProtocolPixel(pixels, x: 136, y: 48, rgb: greens[frame - 1])
            if frame >= 2 {
                XCTAssertEqual(renderer.state.object("101")?.brightness, frame < 4 ? 2 : 4)
            }
        }
    }

    private func sceneProtocolPanel(id: Int, name: String, x: Int, y: Int = 48, color: String = "1 0 0",
                                    script: String? = nil) -> [String: Any] {
        var object: [String: Any] = ["id": id, "name": name, "image": "models/util/solidlayer.json",
                                     "origin": "\(x) \(y) 0", "size": "12 12", "color": color, "alpha": 1]
        if let script {
            object["alpha"] = ["value": 1, "script": script]
        }
        return object
    }

    private func sceneProtocolDriver(objects: [[String: Any]], expectedScripts: Int = 1) async throws
        -> (WPEParitySceneDriver, RecordingLayer) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let assets: WPEParityProgramAssets
        do {
            (_, assets) = try sceneInputs()
        } catch {
            throw NSError(domain: "WPEParitySceneProtocolProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets unavailable: \(error)"])
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(reason):
            throw NSError(domain: "WPEParitySceneProtocolProductTests.RequiredInputs", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Required product toolchain unavailable: \(reason)"])
        }
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParitySceneProtocolProductTests.Isolation", code: 1,
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
        XCTAssertEqual(script.engine.bindings.filter(\.compiled).count, expectedScripts)
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

    private func sceneProtocolFrame(_ driver: WPEParitySceneDriver, layer: RecordingLayer,
                                    label: String) async throws -> [UInt8] {
        try await present(driver, layer: layer, label: label)
        let renderer = try XCTUnwrap(driver.renderer)
        let script = try XCTUnwrap(renderer.script)
        XCTAssertTrue(driver.hasPresentedFrame)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        let texture = try XCTUnwrap(layer.lastTexture, "required actual presented drawable")
        XCTAssertEqual([texture.width, texture.height], [160, 96])
        return try readBack(texture, device: texture.device)
    }

    private func sceneProtocolPixel(_ pixels: [UInt8], x: Int, y: Int, rgb: [Int],
                                    file: StaticString = #filePath, line: UInt = #line) {
        let offset = (y * 160 + x) * 4
        guard pixels.count == 160 * 96 * 4 else {
            XCTFail("Required full drawable pixels", file: file, line: line)
            return
        }
        for channel in 0 ..< 3 {
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset + channel]) - rgb[channel]), 1,
                                     "x=\(x), y=\(y), channel=\(channel)", file: file, line: line)
        }
        XCTAssertEqual(pixels[offset + 3], 255, file: file, line: line)
    }
}
#endif
