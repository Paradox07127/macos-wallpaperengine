#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// Original genericimage4 samples MDLA bone alpha through the real loader, frame owner, packer and present.
    /// Three blend expectations exercise one float4 and a second float4 through a vertex bound to bone four.
    @objc func testNativePuppetAlphaTracksReachOriginalShaderAndPresent() async throws {
        let original: WPEParityProgramAssets
        do {
            let (_, sources) = try sceneInputs()
            original = sources
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityPuppetAlphaProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original inputs unavailable: \(error)"]
            ))
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        for (path, expected) in [
            ("shaders/genericimage4.vert", "7cc66038ea106b213ae2b9103d0b3c6646e3b4d08f9821afbb24aa32f6186672"),
            ("shaders/genericimage4.frag", "6b5344953054ae853ff8a7942f716dd9eb67f61cc1526bd8b6bc67df92c76e1f"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("shaders/common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
            ("shaders/common_fog.h", "a10116adc59b2232e24e06f9c01079393901c45cf47d45ecd17baa2583146201"),
            ("shaders/common_pbr_2.h", "c6c7cc0a57e8621c00b940aaacdcfffa7eaf7d2b84af6a8feb4a9ed597772634"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
        ] {
            let bytes = try XCTUnwrap(original.data(path), "required original \(path)")
            _ = try XCTUnwrap(digest(bytes) == expected ? true : nil, "required original SHA256 \(path)")
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").standardizedFileURL.resolvingSymlinksInPath()
        let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? url : nil, "compiler escaped current bundle: \(path)")
            return url
        }
        let expectedIdentity = try "wpe-shaderc " + tools.map { try digest(Data(contentsOf: $0)) }.joined(separator: " ")
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1], metalIRConverter: tools[2],
                                                         workDirectory: scratch.appending(path: "shaderc"))
        _ = try XCTUnwrap(compiler.compilerIdentity == expectedIdentity ? compiler : nil, "actual bundle compiler byte identity")
        print("puppet-alpha compilerOrigin=current-app-bundle compilerIdentity=\(compiler.compilerIdentity)")
        let defaults = UserDefaults.appScoped()
        _ = try XCTUnwrap(defaults !== UserDefaults.standard ? defaults : nil, "required isolated defaults")
        let scaleKey = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let savedScale = defaults.object(forKey: scaleKey)
        defer {
            if let savedScale {
                defaults.set(savedScale, forKey: scaleKey)
            } else {
                defaults.removeObject(forKey: scaleKey)
            }
        }
        defaults.set(1.0, forKey: scaleKey)
        for boneCount in [1, 5] {
            try await checkPuppetAlpha(boneCount: boneCount, original: original, compiler: compiler)
        }
    }

    private func checkPuppetAlpha(
        boneCount: Int, original: WPEParityProgramAssets, compiler: WPEParityHelperShaderCompiler
    ) async throws {
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
            let name = "alpha\(boneCount)_\(index)"
            let url = scratch.appending(path: "models/\(name).mdl")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.puppetAlphaMDL(secondTrackFlags: flags, boneCount: boneCount).write(to: url)
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
                              drawableSize: CGSize(width: 192, height: 64), pixelFormat: .bgra8Unorm_srgb,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cache")))
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(renderer.skipped, [:])
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 192, height: 64)
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        try await present(driver, layer: layer, label: "native bone alpha BONECOUNT=\(boneCount)")
        XCTAssertEqual(renderer.skipped, [:])
        let backbuffer = try readBack(renderer.backbuffer, device: device)
        let shownTexture = try XCTUnwrap(layer.lastTexture)
        let pass = try XCTUnwrap(driver.executor.lastPresentPass)
        XCTAssertEqual(renderer.backbuffer.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(shownTexture.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(pass.targetPixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(pass.source.pixelFormat, .rgba8Unorm)
        XCTAssertTrue(pass.source === renderer.backbuffer)
        XCTAssertEqual(pass.colorTransfer, .authored)
        XCTAssertFalse(pass.usedMetalFX)
        // Original authored gray is terminal-decoded once; the sRGB display attachment encodes it back.
        // Readback therefore compares the original gray bytes, using the unchanged one-byte RGB budget.
        let shown = try readBack(shownTexture, device: device)
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
            let reflected = try XCTUnwrap(draw.pipeline.vertex.reflection.cbuffers.flatMap(\.variables)
                .first { $0.name == "g_BonesAlpha" })
            let groupCount = (boneCount + 3) / 4
            XCTAssertEqual(reflected.baseType, .float)
            XCTAssertEqual(reflected.class, .vector)
            XCTAssertEqual(reflected.rows, 1)
            XCTAssertEqual(reflected.columns, 4)
            XCTAssertEqual(reflected.elements, groupCount)
            XCTAssertEqual(reflected.size, groupCount * 16)
            XCTAssertTrue(reflected.used)
            print("puppet-alpha BONECOUNT=\(boneCount) object=\(index) reflection=\(reflected)")
            guard case let .array(values)? = draw.constants[.vertex]?["g_BonesAlpha"] else {
                XCTFail("the encoded original shader must consume bone alpha for \(index)")
                continue
            }
            let expected: [Float] = if boneCount == 1 {
                [alpha]
            } else if index == 1 {
                [0.1, 0.2, 0.3, 0.4, 0.5]
            } else {
                [0.5, 0.5, 0.5, 0.5, alpha]
            }
            XCTAssertEqual(values.count, groupCount)
            for (group, value) in values.enumerated() {
                guard case let .vector(lanes) = value else {
                    XCTFail("g_BonesAlpha group \(group) must match the actual float4 reflection")
                    continue
                }
                XCTAssertEqual(lanes.count, 4)
                for (lane, actual) in lanes.enumerated() {
                    let bone = group * 4 + lane
                    XCTAssertEqual(actual, bone < expected.count ? expected[bone] : 0, accuracy: 0.000001)
                }
            }
            let offset = (32 * 192 + 32 + index * 64) * 4
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(backbuffer[offset + channel]) - Int(byte)), 1)
                XCTAssertLessThanOrEqual(abs(Int(shown[offset + channel]) - Int(byte)), 1)
            }
        }
    }

    /// Native MDLV20 rectangle bound to the last MDLS1 bone; two MDLA3 animations supply every bone's curve.
    private static func puppetAlphaMDL(secondTrackFlags: UInt32, boneCount: Int) -> Data {
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
            writer.words([UInt32(boneCount - 1), 0, 0, 0])
            writer.floats([1, 0, 0, 0, u, v])
        }
        writer.words([12])
        for index: UInt16 in [0, 2, 1, 1, 2, 3] {
            writer.uint16(index)
        }
        writer.string("MDLS0001")
        let skeletonEnd = writer.data.count
        writer.words([0, UInt32(boneCount)])
        for bone in 0 ..< boneCount {
            writer.string("root\(bone)")
            writer.words([0, .max, 64])
            writer.floats([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
            writer.string("")
        }
        writer.end(at: skeletonEnd)
        writer.string("MDLA0003")
        let animationEnd = writer.data.count
        writer.words([0, 2])
        for id: UInt32 in [7, 8] {
            writer.words([id, 0])
            writer.string("a\(id)")
            writer.string("loop")
            writer.floats([2])
            writer.words([1, 0, UInt32(boneCount)])
            for bone in 0 ..< boneCount {
                writer.words([id == 8 && bone == boneCount - 1 ? secondTrackFlags : 0, 72])
                for _ in 0 ..< 2 {
                    writer.floats([0, 0, 0, 0, 0, 0, 1, 1, 1])
                }
            }
            writer.words([0]) // no additional scalar tracks before per-bone alpha curves
            writer.data.append(1)
            let alphas: [Float] = if boneCount == 1 {
                [id == 7 ? 0.8 : 0.4]
            } else {
                id == 7 ? [0.1, 0.2, 0.3, 0.4, 0.8] : [0.9, 0.8, 0.7, 0.6, 0.4]
            }
            for alpha in alphas {
                writer.words([0, 8])
                writer.floats([alpha, alpha])
            }
            writer.words([0]) // no animation events
        }
        writer.end(at: animationEnd)
        return writer.data
    }
}

private struct PuppetAlphaMDLWriter {
    var data = Data()
    mutating func string(_ value: String) {
        data.append(contentsOf: value.utf8); data.append(0)
    }

    mutating func words(_ values: [UInt32]) {
        for value in values {
            Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    mutating func floats(_ values: [Float]) {
        words(values.map(\.bitPattern))
    }

    mutating func uint16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func end(at offset: Int) {
        Swift.withUnsafeBytes(of: UInt32(data.count).littleEndian) { data.replaceSubrange(offset ..< offset + 4, with: $0) }
    }
}
#endif
