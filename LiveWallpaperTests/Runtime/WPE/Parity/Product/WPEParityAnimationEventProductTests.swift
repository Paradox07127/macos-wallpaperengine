#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// Actual authored timeline -> frame renderer -> event 6 -> JSC -> original shader -> presented RGB.
    func testAuthoredAnimationEventKeepsFullPayloadAndWritesSameFrame() async throws {
        let forbidden = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "WPE_SHADERC_TIMEOUT",
                         "WPE_SHADERC_XCODEBUILD", "WPE_SHADERC_XCRUN"]
        XCTAssertTrue(forbidden.allSatisfy { ProcessInfo.processInfo.environment[$0] == nil })
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let tools = ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
            .map { contents.appending(path: $0).resolvingSymlinksInPath() }
        for tool in tools {
            XCTAssertTrue(tool.path.hasPrefix(contents.path + "/"), tool.path)
            let bytes = try Data(contentsOf: tool)
            XCTAssertFalse(bytes.isEmpty)
            print("S06 app-bundle \(tool.path) SHA256=\(SHA256.hash(data: bytes))")
        }
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1],
                                                         metalIRConverter: tools[2],
                                                         workDirectory: scratch.appending(path: "event-shaderc"))
        print("S06 compilerIdentity=\(compiler.compilerIdentity)")
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        for file in ["shaders/genericimage4.vert", "shaders/genericimage4.frag", "shaders/common.h",
                     "scripts/jsclasses/baseclasses.js"] {
            print("S06 original asset \(file) SHA256=\(SHA256.hash(data: try Data(contentsOf: engine.appending(path: file))))")
        }
        let script = """
        let events = 0;
        export function animationEvent(event, value) {
          events += 1;
          if (event.name !== 'A"雪' || event.nested.values[0] !== 7 || event.nested.values[1] !== null
              || event.nested.ok !== true || event.label !== 'payload\\\\tail') throw Error('event payload lost');
          thisLayer.origin = new Vec3(8, 8, events);
          return value * event.factor;
        }
        export function update(value) {
          thisLayer.brightness = events;
          return value;
        }
        """
        let event: (Double, Double) -> [String: Any] = { frame, factor in
            ["name": "A\"雪", "frame": frame, "factor": factor,
             "nested": ["values": [7, NSNull()], "ok": true], "label": "payload\\tail"]
        }
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "models/event.json", "size": "16 16", "origin": "8 8 0",
                         "alpha": ["value": 1, "script": script,
                                   "animation": ["c0": [["frame": 0, "value": 1], ["frame": 8, "value": 1]],
                                                 "options": ["fps": 2, "length": 8,
                                                             "events": [event(0, 0.5), event(0.5, 0.25)]]]]]],
        ]
        let resources: [String: Any] = [
            "models/event.json": ["material": "materials/event.json"],
            "materials/event.json": ["passes": [["shader": "genericimage4", "textures": ["white"],
                                                  "blending": "normal"]]],
        ]
        var files = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        var white = Data("TEXV0004\0".utf8)
        for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
            withUnsafeBytes(of: value.littleEndian) { white.append(contentsOf: $0) }
        }
        white.append(contentsOf: [255, 255, 255, 255])
        files["materials/white.tex"] = white
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }, .directory(engine)])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false, hdrPostProcessing: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .rgba8Unorm, compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "event-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.framebufferOnly = false
        for (frame, expectedAlpha, expectedEvents): (Int, Float, Float) in [(0, 0.5, 1), (1, 0.25, 2), (2, 1, 2)] {
            let submission = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 200 + Double(frame) * 0.25,
                                                                         pointer: SIMD2(0.5, 0.5)))
            await submission.completed()
            try await settle(driver, label: "animation event frame \(frame)")
            let renderer = try XCTUnwrap(driver.renderer)
            let host = try XCTUnwrap(renderer.script)
            XCTAssertEqual(host.engine.exceptionCount, 0, host.engine.exceptions.joined(separator: "\n"))
            XCTAssertEqual(renderer.state.object("1")?.alpha, expectedAlpha)
            XCTAssertEqual(renderer.state.object("1")?.brightness, expectedEvents, "update sees event of this frame")
            XCTAssertEqual(renderer.state.object("1")?.origin.z, expectedEvents)
            let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.draw.constants[.fragment]?["g_Color4"] != nil }?.draw)
            guard case let .vector(color)? = draw.constants[.fragment]?["g_Color4"] else {
                XCTFail("the original genericimage4 fragment must receive g_Color4")
                return
            }
            XCTAssertEqual(color, [1, 1, 1, expectedAlpha])
            let pixels = try readBack(XCTUnwrap(layer.lastTexture), device: device)
            let center = (8 * 16 + 8) * 4
            let expected = Int((expectedAlpha * 255).rounded())
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(pixels[center + channel]) - expected), 1,
                                          "frame \(frame), RGB channel \(channel)")
            }
        }
    }
}
#endif
