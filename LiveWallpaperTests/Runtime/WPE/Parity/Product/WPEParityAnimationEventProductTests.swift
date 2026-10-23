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
        let forbidden = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "TEST_RUNNER_WPE_SHADERC",
                         "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        guard forbidden.allSatisfy({ ProcessInfo.processInfo.environment[$0] == nil }) else {
            throw NSError(domain: "WPEParityAnimationEventProductTests.ToolOverride", code: 1)
        }
        let original: WPEParityProgramAssets
        do {
            (_, original) = try sceneInputs()
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityAnimationEventProductTests.RequiredOriginalInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
            ))
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let tools = ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
            .map { contents.appending(path: $0).resolvingSymlinksInPath() }
        var toolHashes: [String] = []
        for tool in tools {
            _ = try XCTUnwrap(tool.path.hasPrefix(contents.path + "/") ? tool : nil, tool.path)
            let bytes = try Data(contentsOf: tool)
            _ = try XCTUnwrap(bytes.isEmpty ? nil : true)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            toolHashes.append(hash)
            print("app-bundle \(tool.path) SHA256=\(hash)")
        }
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1],
                                                         metalIRConverter: tools[2],
                                                         workDirectory: scratch.appending(path: "event-shaderc"))
        _ = try XCTUnwrap(compiler.compilerIdentity == "wpe-shaderc " + toolHashes.joined(separator: " ") ? true : nil)
        print("compilerIdentity=\(compiler.compilerIdentity)")
        for (path, expected) in [
            ("shaders/genericimage4.vert", "7cc66038ea106b213ae2b9103d0b3c6646e3b4d08f9821afbb24aa32f6186672"),
            ("shaders/genericimage4.frag", "6b5344953054ae853ff8a7942f716dd9eb67f61cc1526bd8b6bc67df92c76e1f"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("shaders/common_pbr_2.h", "c6c7cc0a57e8621c00b940aaacdcfffa7eaf7d2b84af6a8feb4a9ed597772634"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("shaders/common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
            ("shaders/common_fog.h", "a10116adc59b2232e24e06f9c01079393901c45cf47d45ecd17baa2583146201"),
            ("scripts/jsclasses/baseclasses.js", "708e6636167f0456eebf3ba05274d7b7763d17dfbd44c2711dc3d6d98f0cb294"),
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
        ] {
            let bytes = try XCTUnwrap(original.data(path), "required original input \(path)")
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            _ = try XCTUnwrap(actual == expected ? true : nil, "required pinned input \(path): \(actual)")
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
            "materials/event.json": ["passes": [["shader": "genericimage4", "textures": ["event-witness"],
                                                 "blending": "translucent"]]],
        ]
        func solidTexture(_ pixel: [UInt8]) -> Data {
            var data = Data("TEXV0005\0TEXI0001\0".utf8)
            func word(_ value: UInt32) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            for value: UInt32 in [0, 0, 2, 2, 2, 2, 0] {
                word(value)
            }
            data.append(contentsOf: "TEXB0003\0".utf8)
            for value: UInt32 in [1, .max, 1, 2, 2, 0, 16, 16] {
                word(value)
            }
            for _ in 0 ..< 4 {
                data.append(contentsOf: pixel)
            }
            return data
        }
        var files = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let white = solidTexture([255, 255, 255, 255])
        XCTAssertEqual(SHA256.hash(data: white).map { String(format: "%02x", $0) }.joined(), "69a03565ff1e6ec0c468d27e1faff5cff7d00f0fb6a97cd34c053cb5d49f8f3c")
        files["materials/event-witness.tex"] = white
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false, hdrPostProcessing: false),
                              drawableSize: CGSize(width: 16, height: 16), pixelFormat: .bgra8Unorm_srgb, compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "event-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.framebufferOnly = false
        for (frame, expectedAlpha, expectedEvents): (Int, Float, Float) in [(0, 0.5, 1), (1, 0.25, 2), (2, 1, 2)] {
            let submission = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 200 + Double(frame) * 0.25,
                                                                        pointer: SIMD2(0.5, 0.5)))
            await submission.completed()
            try await settle(driver, label: "animation event frame \(frame)")
            let renderer = try XCTUnwrap(driver.renderer)
            let host = try XCTUnwrap(renderer.instance.script)
            XCTAssertEqual(host.engine.exceptionCount, 0, host.engine.exceptions.joined(separator: "\n"))
            XCTAssertEqual(renderer.instance.state.object("1")?.alpha, expectedAlpha)
            XCTAssertEqual(renderer.instance.state.object("1")?.brightness, expectedEvents, "update sees event of this frame")
            XCTAssertEqual(renderer.instance.state.object("1")?.origin.z, expectedEvents)
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
