#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

/// Native 140189e10 reads solid and propagation flags at each cursor pass, before this frame's update.
/// Event handlers change separate visible witnesses so an occluding target cannot hide a missing callback.
extension WPEParitySceneDriverTests {
    @objc func testCursorSolidScriptWritesReachTheNextNativeCursorPass() async throws {
        let (driver, layer) = try await cursorFlagsDriver(topSolid: false, parent: false, lifecycle: """
        export function init(value) { thisLayer.solid = true; return value; }
        let frames = 0;
        export function update(value) {
          frames += 1;
          if (frames === 1) thisLayer.solid = false;
          if (frames === 2) thisLayer.solid = true;
          return value;
        }
        """)
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(renderer.state.scriptField("solid", of: "20"), .vector(SIMD4(1, 0, 0, 0)),
                       "init must write through the real script engine before the first cursor pass")
        for (frame, top, below, nextSolid) in [(1, 1, 1, false), (2, 1, 2, true), (3, 2, 3, true)] {
            try await cursorFlagsFrame(driver, layer: layer, frame: frame, topMoves: top, belowMoves: below)
            XCTAssertEqual(renderer.state.scriptField("solid", of: "20"),
                           .vector(SIMD4(nextSolid ? 1 : 0, 0, 0, 0)), "frame \(frame)")
        }
    }

    @objc func testCursorPropagationScriptWritesUseLiveSelfAndAncestorVisibility() async throws {
        let (driver, layer) = try await cursorFlagsDriver(topSolid: true, parent: true, lifecycle: """
        export function init(value) { thisLayer.disablepropagation = true; return value; }
        let frames = 0;
        export function update(value) {
          frames += 1;
          if (frames === 1) thisLayer.disablepropagation = false;
          if (frames === 2) thisLayer.disablepropagation = true;
          if (frames === 3) thisLayer.visible = false;
          if (frames === 4) {
            thisLayer.visible = true;
            thisScene.getLayer('blocker parent').visible = false;
          }
          if (frames === 5) thisScene.getLayer('blocker parent').visible = true;
          return value;
        }
        """)
        defer { driver.cleanup() }
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(renderer.state.scriptField("disablepropagation", of: "20"), .vector(SIMD4(1, 0, 0, 0)))
        // Native visibility qualifies only the propagation break. An invisible hit still gets its cursor event.
        for (frame, below) in [(1, 0), (2, 1), (3, 1), (4, 2), (5, 3), (6, 3)] {
            try await cursorFlagsFrame(driver, layer: layer, frame: frame, topMoves: frame, belowMoves: below)
            XCTAssertEqual(renderer.state.scriptField("disablepropagation", of: "20"),
                           .vector(SIMD4(frame == 1 ? 0 : 1, 0, 0, 0)), "frame \(frame)")
            XCTAssertEqual(renderer.state.isVisible("20"), frame != 3 && frame != 4,
                           "update changes this frame's drawing and the next cursor pass; frame \(frame)")
        }
    }

    private func cursorFlagsDriver(topSolid: Bool, parent: Bool, lifecycle: String)
        async throws -> (WPEParitySceneDriver, RecordingLayer) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let assets: WPEParityProgramAssets
        do {
            (_, assets) = try sceneInputs()
        } catch {
            throw NSError(domain: "WPEParityCursorFlagsProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets unavailable: \(error)"])
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(reason):
            throw NSError(domain: "WPEParityCursorFlagsProductTests.RequiredInputs", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Required product toolchain unavailable: \(reason)"])
        }
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityCursorFlagsProductTests.Isolation", code: 1,
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
        func handler(witness: String) -> String {
            """
            let moves = 0;
            export function cursorMove(event) {
              moves += 1;
              thisLayer.alpha = moves / 8;
              thisScene.getLayer('\(witness)').color = moves % 3 === 1 ? new Vec3(1, 0, 0)
                : moves % 3 === 2 ? new Vec3(0, 1, 0) : new Vec3(0, 0, 1);
            }
            """
        }
        func panel(id: Int, name: String, origin: String, size: String, solid: Bool,
                   alpha: Any = 1) -> [String: Any] {
            ["id": id, "name": name, "image": "models/util/solidlayer.json", "origin": origin,
             "size": size, "solid": solid, "color": "0 0 0", "alpha": alpha]
        }
        var objects = [panel(id: 10, name: "below target", origin: "80 48 0", size: "32 32", solid: true,
                             alpha: ["value": 0, "script": handler(witness: "below witness")])]
        if parent {
            objects.append(["id": 50, "name": "blocker parent", "origin": "80 48 0", "solid": false,
                            "visible": true])
        }
        var top = panel(id: 20, name: "top target", origin: parent ? "0 0 0" : "80 48 0",
                        size: "32 32", solid: topSolid,
                        alpha: ["value": 0, "script": lifecycle + "\n" + handler(witness: "top witness")])
        top["disablepropagation"] = false
        if parent {
            top["parent"] = 50
        }
        objects += [top,
                    panel(id: 30, name: "top witness", origin: "24 48 0", size: "16 16", solid: false),
                    panel(id: 40, name: "below witness", origin: "136 48 0", size: "16 16", solid: false)]
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
        let script = try XCTUnwrap(renderer.script, "actual product load must attach SceneScript")
        XCTAssertTrue(script.handlesCursor)
        XCTAssertEqual(script.engine.bindings.filter(\.compiled).count, 2)
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

    private func cursorFlagsFrame(_ driver: WPEParitySceneDriver, layer: RecordingLayer, frame: Int,
                                  topMoves: Int, belowMoves: Int) async throws {
        // Independent fixed interior points: x=80...85,y=48; both authored 32x32 targets cover them.
        let pointer = SIMD2<Double>(0.5 + Double(frame - 1) / 160, 0.5)
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                                 pointer: pointer, buttonDown: false),
                                    "frame \(frame) must execute and present")
        try await settle(driver, label: "cursor flags frame \(frame)")
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        XCTAssertTrue(driver.hasPresentedFrame)
        let renderer = try XCTUnwrap(driver.renderer)
        let script = try XCTUnwrap(renderer.script)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(try XCTUnwrap(renderer.state.object("20")).alpha, Float(topMoves) / 8, "top frame \(frame)")
        XCTAssertEqual(try XCTUnwrap(renderer.state.object("10")).alpha, Float(belowMoves) / 8, "below frame \(frame)")
        let texture = try XCTUnwrap(layer.lastTexture, "required actual presented drawable")
        XCTAssertEqual([texture.width, texture.height], [160, 96])
        let pixels = try readBack(texture, device: texture.device)
        for (x, moves) in [(24, topMoves), (136, belowMoves)] {
            let rgb: [Int] = moves == 0 ? [0, 0, 0] : moves % 3 == 1 ? [255, 0, 0]
                : moves % 3 == 2 ? [0, 255, 0] : [0, 0, 255]
            let offset = (48 * 160 + x) * 4
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(pixels[offset + channel]) - rgb[channel]), 1,
                                         "witness x=\(x), frame \(frame), channel \(channel)")
            }
            XCTAssertEqual(pixels[offset + 3], 255)
        }
    }
}
#endif
