#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// Original genericimage4 samples MDLA bone alpha through the real loader, frame owner, packer and present.
    /// The three independent expectations distinguish replacement blend, bounded additive and skipped tracks.
    @objc func testNativePuppetAlphaTracksReachOriginalShaderAndPresent() async throws {
        let original: WPEParityProgramAssets
        do {
            let (_, sources) = try sceneInputs()
            original = sources
        } catch {
            throw NSError(domain: "WPEParityPuppetAlphaProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original inputs unavailable: \(error)"])
        }
        for path in ["shaders/genericimage4.vert", "shaders/genericimage4.frag", "materials/util/white.tex"] {
            _ = try XCTUnwrap(original.data(path), "required original \(path)")
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        for path in ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"] {
            _ = try XCTUnwrap(FileManager.default.fileExists(atPath: contents.appending(path: path).path) ? path : nil,
                              "required app-bundle compiler \(path)")
        }
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(reason): throw reason
        }
        let defaults = UserDefaults.appScoped()
        _ = try XCTUnwrap(defaults !== UserDefaults.standard ? defaults : nil, "required isolated defaults")
        let scaleKey = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let savedScale = defaults.object(forKey: scaleKey)
        defer {
            if let savedScale { defaults.set(savedScale, forKey: scaleKey) }
            else { defaults.removeObject(forKey: scaleKey) }
        }
        defaults.set(1.0, forKey: scaleKey)
        func write(_ json: Any, _ path: String) throws {
            let url = scratch.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        try write(["passes": [["shader": "genericimage4", "textures": ["util/white"],
                                "combos": ["LIGHTING": 0, "FOG": 0, "REFLECTION": 0],
                                "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
                                "blending": "translucent"]]], "materials/alpha.json")
        var objects: [[String: Any]] = []
        for (index, flags): (Int, UInt32) in [(0, 0), (1, 0), (2, 1)] {
            let name = "alpha\(index)"
            let url = scratch.appending(path: "models/\(name).mdl")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.puppetAlphaMDL(secondTrackFlags: flags).write(to: url)
            try write(["material": "materials/alpha.json", "puppet": "models/\(name).mdl"], "models/\(name).json")
            objects.append(["id": index + 1, "image": "models/\(name).json", "size": "64 64",
                            "origin": "\(32 + index * 64) 32 0", "scale": "1 1 1", "angles": "0 0 0",
                            "perspective": false, "color": "1 1 1", "alpha": 1, "copybackground": false,
                            "animationlayers": [
                                ["id": 10, "animation": 7, "rate": 0, "blend": 1],
                                ["id": 11, "animation": 8, "rate": 0, "blend": 0.5, "additive": index == 1],
                            ]])
        }
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 192, "height": 64], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "camerashake": false, "cameraparallax": false],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        let assets = WPEParityProgramAssets(sources: [.directory(scratch)] + original.sources)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 192, height: 64), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cache")))
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(renderer.skipped, [:])
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.drawableSize = CGSize(width: 192, height: 64)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        try await present(driver, layer: layer, label: "native bone alpha")
        XCTAssertEqual(renderer.skipped, [:])
        let backbuffer = try readBack(renderer.backbuffer, device: device)
        let shown = try readBack(XCTUnwrap(layer.lastTexture), device: device)
        XCTAssertEqual(backbuffer.count, 192 * 64 * 4)
        XCTAssertEqual(shown.count, 192 * 64 * 4)
        for (index, alpha, byte): (Int, Float, UInt8) in [(0, 0.6, 153), (1, 0.5, 128), (2, 0.8, 204)] {
            let frame = try XCTUnwrap(renderer.frames.first)
            let drawIndex = try XCTUnwrap(frame.draws.first { _, value in
                guard case let .scene(draw) = value else { return false }
                return draw.objectID == String(index + 1) && draw.geometry == .puppetMesh
            }?.key)
            let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == drawIndex }?.draw)
            XCTAssertGreaterThan(draw.indexCount, 0)
            if case let .array(values)? = draw.constants[.vertex]?["g_BonesAlpha"],
               case let .float(actual)? = values.first {
                XCTAssertEqual(actual, alpha, accuracy: 0.000001)
            } else {
                XCTFail("the encoded original shader must consume bone alpha for \(index)")
            }
            let offset = (32 * 192 + 32 + index * 64) * 4
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(backbuffer[offset + channel]) - Int(byte)), 1)
                XCTAssertLessThanOrEqual(abs(Int(shown[offset + channel]) - Int(byte)), 2)
            }
        }
    }

    /// Native MDLV20 skinned rectangle, one MDLS1 identity bone, two MDLA3 animations with alpha curves.
    private static func puppetAlphaMDL(secondTrackFlags: UInt32) -> Data {
        var writer = PuppetAlphaMDLWriter()
        writer.string("MDLV0020")
        writer.words([0x0180_000B, 1, 1])
        writer.string("materials/alpha.json")
        writer.words([4]) // mesh0 bit2: SKINNING_ALPHA
        writer.floats([-32, -32, 0, 32, 32, 0])
        writer.words([0x0180_000B, 4 * 64])
        for (x, y, u, v): (Float, Float, Float, Float) in [(-32, 32, 0, 0), (32, 32, 1, 0),
                                                          (-32, -32, 0, 1), (32, -32, 1, 1)] {
            writer.floats([x, y, 0, 0, 0, 1])
            writer.words([0, 0, 0, 0])
            writer.floats([1, 0, 0, 0, u, v])
        }
        writer.words([12])
        for index: UInt16 in [0, 2, 1, 1, 2, 3] { writer.uint16(index) }
        writer.string("MDLS0001")
        let skeletonEnd = writer.data.count
        writer.words([0, 1])
        writer.string("root")
        writer.words([0, .max, 64])
        writer.floats([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        writer.string("")
        writer.end(at: skeletonEnd)
        writer.string("MDLA0003")
        let animationEnd = writer.data.count
        writer.words([0, 2])
        for (id, flags, alpha): (UInt32, UInt32, Float) in [(7, 0, 0.8), (8, secondTrackFlags, 0.4)] {
            writer.words([id, 0])
            writer.string("a\(id)")
            writer.string("loop")
            writer.floats([2])
            writer.words([1, 0, 1, flags, 72])
            for _ in 0 ..< 2 { writer.floats([0, 0, 0, 0, 0, 0, 1, 1, 1]) }
            writer.words([0]) // no additional scalar tracks before per-bone alpha curves
            writer.data.append(1)
            writer.words([0, 8])
            writer.floats([alpha, alpha])
            writer.words([0]) // no animation events
        }
        writer.end(at: animationEnd)
        return writer.data
    }
}

private struct PuppetAlphaMDLWriter {
    var data = Data()
    mutating func string(_ value: String) { data.append(contentsOf: value.utf8); data.append(0) }
    mutating func words(_ values: [UInt32]) {
        for value in values { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }
    mutating func floats(_ values: [Float]) { words(values.map(\.bitPattern)) }
    mutating func uint16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func end(at offset: Int) {
        Swift.withUnsafeBytes(of: UInt32(data.count).littleEndian) { data.replaceSubrange(offset ..< offset + 4, with: $0) }
    }
}
#endif
