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
    /// The shipped genericimage3 fragment consumes both native tube endpoints through PointSegmentDelta.
    @objc func testTubeControlPointChangesOriginalLightingAndSurvivesResize() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (assets, compiler) = try tubeLightInputs()
        let scene: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32], "lightconfig": ["tube": 1],
                        "ambientcolor": "0 0 0", "skylightcolor": "0 0 0", "clearenabled": true,
                        "clearcolor": "0 0 0", "camerashake": false, "cameraparallax": false],
            "objects": [
                ["id": 1, "image": "models/tube-test.json", "size": "32 32", "origin": "16 16 0"],
                ["id": 2, "name": "light parent", "origin": "0 0 0"],
                ["id": 3, "light": "ltube", "parent": 2, "origin": "-64 16 16", "color": "1 0 0",
                 "intensity": 1, "radius": 16, "controlpoint": ["value": "0 0 0", "script": """
                 let frame = 0;
                 export function update(value) {
                   frame += 1;
                   if (frame === 2) return new Vec3(80, 0, 0);
                   if (frame === 3) thisScene.getLayer('light parent').visible = false;
                   if (frame === 4) thisScene.getLayer('light parent').visible = true;
                   return value;
                 }
                 """]],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let defaults = UserDefaults.appScoped()
        _ = try XCTUnwrap(defaults !== UserDefaults.standard ? true : nil, "required isolated product defaults")
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let saved = defaults.object(forKey: key)
        defaults.set(1.0, forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
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
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.colorspace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 32, height: 32)
        var red: [Int] = []
        weak var retiredRenderer: WPEParityFrameRenderer?
        for frame in 1 ... 4 {
            if frame == 4 {
                retiredRenderer = driver.renderer
                driver.updateSurfaceGeometry(drawableSize: CGSize(width: 64, height: 64))
                let replanned = await driver.replan()
                XCTAssertTrue(replanned)
                layer.drawableSize = CGSize(width: 64, height: 64)
                XCTAssertNil(retiredRenderer, "resize must release the old renderer rather than keeping its light owner")
            }
            try await present(driver, layer: layer, label: "tube original lighting frame \(frame)")
            let renderer = try XCTUnwrap(driver.renderer)
            let script = try XCTUnwrap(renderer.script)
            XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            XCTAssertTrue(renderer.fallbackTextures.isEmpty, "\(renderer.fallbackTextures)")
            XCTAssertTrue(driver.hasPresentedFrame)
            XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
            let sceneFrame = try XCTUnwrap(renderer.frames.first)
            let operation = try XCTUnwrap(sceneFrame.draws.first { entry in
                guard case let .scene(draw) = entry.value else { return false }
                return draw.objectID == "1" && draw.shader == "genericimage3"
            })
            let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation.key }?.draw)
            XCTAssertGreaterThan(draw.indexCount + draw.vertexCount, 0)
            _ = try XCTUnwrap(draw.textures["g_Texture0"], "actual original white TEX must bind")
            let constants = try XCTUnwrap(draw.constants[.fragment])
            if frame == 3 {
                XCTAssertNil(constants["g_LTube_Color"])
                XCTAssertNil(constants["g_LTube_OriginA"])
                XCTAssertNil(constants["g_LTube_OriginB"])
            } else {
                XCTAssertEqual(constants["g_LTube_Color"], .array([.vector([1, 0, 0, 16])]))
                XCTAssertEqual(constants["g_LTube_OriginA"], .array([.vector([-64, 16, 16, 2])]))
                XCTAssertEqual(constants["g_LTube_OriginB"],
                               .array([.vector([frame == 1 ? -64 : 16, 16, 16, 0])]))
            }
            let texture = try XCTUnwrap(layer.lastTexture)
            let size = frame == 4 ? 64 : 32
            XCTAssertEqual([texture.width, texture.height], [size, size])
            let pixels = try readBack(texture, device: device)
            let offset = ((size / 2) * size + size / 2) * 4
            red.append(Int(pixels[offset]))
            XCTAssertLessThanOrEqual(pixels[offset + 1], 1)
            XCTAssertLessThanOrEqual(pixels[offset + 2], 1)
            XCTAssertEqual(pixels[offset + 3], 255)
            if frame == 3 {
                XCTAssertLessThanOrEqual(pixels[offset], 1, "hidden light must not leave stale packed values")
            }
            if frame == 4 {
                XCTAssertGreaterThan(pixels[offset], 16, "restored CP must reach the resized original draw")
            }
        }
        XCTAssertGreaterThan(red[1] - red[0], 16, "moving only B near the surface must brighten the actual original fragment")
    }

    private func tubeLightInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath().standardizedFileURL
        for key in ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER",
                    "TEST_RUNNER_WPE_SHADERC", "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"] {
            _ = try XCTUnwrap(ProcessInfo.processInfo.environment[key] == nil ? true : nil,
                              "required bundled compiler disallows \(key)")
        }
        let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil, "required bundle component \(url)")
            return url
        }
        let hashes = try tools.map { try SHA256.hash(data: Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined() }
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1],
                                                         metalIRConverter: tools[2], workDirectory: scratch.appending(path: "tube-shaderc"))
        XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + hashes.joined(separator: " "))
        let files: [String: Any] = [
            "models/tube-test.json": ["material": "materials/tube-test.json"],
            "materials/tube-test.json": ["passes": [["shader": "genericimage3", "blending": "normal",
                                                     "textures": ["util/white"], "combos": ["LIGHTING": 1, "REFLECTION": 0, "NORMALMAP": 0,
                                                                                            "PBRMASKS": 0, "SHADERVERSION": 62],
                                                     "constants": ["roughness": 1, "metallic": 0]]]],
        ]
        let json = try files.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { json[$0] }, .directory(root)])
        for (path, expected) in tubeLightOriginalHashes {
            let data = try XCTUnwrap(assets.data(path), "required original shader input \(path)")
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected, path)
        }
        print("tube product toolchain origin=app-bundle compilerIdentity=\(compiler.compilerIdentity)")
        return (assets, compiler)
    }

    private var tubeLightOriginalHashes: [(String, String)] {
        [
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
            ("scripts/jsclasses/baseclasses.js", "708e6636167f0456eebf3ba05274d7b7763d17dfbd44c2711dc3d6d98f0cb294"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("shaders/common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
            ("shaders/common_pbr.h", "7a542df2279b6637d4f67434087df485b68ad24e06f85490d6ce424118c68d8d"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("shaders/genericimage3.frag", "552f2547b122dc04a3f9b5daeff3d1f2acdd15fa0e94502eed762503c11318f6"),
            ("shaders/genericimage3.vert", "b33f8506d1193d8ff0bda8de95a5d4777f75f71694557a70c3535a661b9e73c3"),
        ]
    }
}
#endif
