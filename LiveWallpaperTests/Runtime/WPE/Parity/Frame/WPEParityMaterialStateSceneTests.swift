#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// Authored state through the original image shaders, the scene planner and the real DrawEncoder.
final class WPEParityMaterialStateSceneTests: XCTestCase {
    private enum Layer: CaseIterable {
        case image, effect, shape
    }

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-material-state-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testImageAndFinalEffectUseTheAlbedoDepthOverride() async throws {
        for layer in [Layer.image, .effect] {
            for testsDepth in [true, false] {
                let fixture = try await makeRenderer(layer, depthTest: testsDepth)
                let executed = try await render(fixture)
                XCTAssertEqual(executed.depthStencil.depthEnable, testsDepth)
                XCTAssertEqual(executed.depthStencil.depthWriteMask, testsDepth ? .all : .zero)
                // Red at z=100 was drawn first. Blue at z=0 is behind it in WPE's reversed-Z ortho projection.
                XCTAssertEqual(try pixel(fixture), testsDepth ? [255, 0, 0] : [0, 0, 255], "\(layer)")
            }
        }
    }

    func testImageAndFinalEffectHonorDepthWriteAndBlendRestrictions() async throws {
        for layer in [Layer.image, .effect] {
            for (writesDepth, blending) in [(true, "normal"), (false, "normal"), (true, "translucent"), (true, "additive")] {
                let fixture = try await makeRenderer(layer, depthTest: true, depthWrite: writesDepth,
                                                     blending: blending, subjectFirst: true)
                let executed = try await render(fixture)
                let writes = writesDepth && blending == "normal"
                XCTAssertEqual(executed.depthStencil.depthWriteMask, writes ? .all : .zero)
                // The blue subject at z=100 only occludes the later red image when its effective state writes Z.
                XCTAssertEqual(try pixel(fixture), writes ? [0, 0, 255] : [255, 0, 0], "\(layer) \(blending)")
            }
        }
    }

    func testShapeKeepsItsEffectDepthAndAdditiveDoesNotWriteIt() async throws {
        for testsDepth in [true, false] {
            let fixture = try await makeRenderer(.shape, depthTest: testsDepth)
            let executed = try await render(fixture)
            XCTAssertEqual(executed.depthStencil.depthEnable, testsDepth)
            XCTAssertEqual(executed.depthStencil.depthWriteMask, .zero)
            XCTAssertEqual(try pixel(fixture), testsDepth ? [255, 0, 0] : [255, 0, 255])
        }
        let fixture = try await makeRenderer(.shape, depthTest: true, subjectFirst: true)
        let executed = try await render(fixture)
        XCTAssertEqual(executed.depthStencil.depthWriteMask, .zero)
        XCTAssertEqual(try pixel(fixture), [255, 0, 0])
    }

    func testReflectedImageEffectAndShapeUseTheirOwnMaterialCullState() async throws {
        for layer in Layer.allCases {
            for culls in [true, false] {
                let fixture = try await makeRenderer(layer, depthTest: false, culls: culls, reflected: true)
                let executed = try await render(fixture)
                XCTAssertEqual(executed.rasterizer.cullMode, culls ? .back : .none)
                // A final image effect keeps its own cull value even though the albedo's is the opposite.
                let expected = culls ? [255, 0, 0] : layer == .shape ? [255, 0, 255] : [0, 0, 255]
                XCTAssertEqual(try pixel(fixture), expected, "\(layer) cull=\(culls)")
            }
        }
    }

    private struct Fixture {
        let plan: WPEParityFramePlan
        let renderer: WPEParityFrameRenderer
        let queue: MTLCommandQueue
        let subject: Int
    }

    private func makeRenderer(_ layer: Layer, depthTest: Bool, depthWrite: Bool = true,
                              blending: String = "normal", subjectFirst: Bool = false,
                              culls: Bool = false, reflected: Bool = false) async throws -> Fixture {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        func material(shader: String, texture: String, depthTest: Bool, depthWrite: Bool,
                      blending: String, culls: Bool) -> [String: Any] {
            ["passes": [["shader": shader, "textures": [texture], "blending": blending,
                         "depthtest": depthTest ? "enabled" : "disabled",
                         "depthwrite": depthWrite ? "enabled" : "disabled",
                         "cullmode": culls ? "normal" : "nocull"]]]
        }
        let root = scratch.appending(path: UUID().uuidString)
        var files: [String: Data] = ["materials/red.tex": Self.texture([255, 0, 0, 255]),
                                     "materials/blue.tex": Self.texture([0, 0, 255, 255])]
        XCTAssertEqual(try Self.sha256(XCTUnwrap(files["materials/red.tex"])),
                       "9e441ee114603c6004c2f599e900ab89f93c3821dcbb227a58018cf38b9a4aea")
        XCTAssertEqual(try Self.sha256(XCTUnwrap(files["materials/blue.tex"])),
                       "7415de08c5065e8087d0ec98616f92bd19ec494370a2ae810af4885897d014db")
        func json(_ name: String, _ value: Any) throws {
            files[name] = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }
        try json("models/red.json", ["material": "materials/red.json"])
        try json("models/blue.json", ["material": "materials/blue.json"])
        try json("materials/red.json", material(shader: "genericimage2", texture: "red", depthTest: true,
                                                depthWrite: true, blending: "normal", culls: false))
        // Shape's synthetic albedo has the opposite state, proving that its final pass is not an image override.
        try json("materials/blue.json", material(shader: "genericimage2", texture: "blue",
                                                 depthTest: layer == .shape ? !depthTest : depthTest,
                                                 depthWrite: depthWrite, blending: blending,
                                                 culls: layer == .effect ? !culls : culls))
        let subjectZ = subjectFirst ? 100 : 0
        let redZ = subjectFirst ? 0 : 100
        let red: [String: Any] = ["id": 1, "image": "models/red.json", "size": "32 32", "origin": "16 16 \(redZ)"]
        var blue: [String: Any] = ["id": 2, "size": "32 32", "origin": "16 16 \(subjectZ)",
                                   "scale": reflected ? "-1 1 1" : "1 1 1"]
        if layer == .shape {
            blue["shape"] = "quad"
            try json("models/util/solidlayer.json", ["material": "materials/blue.json"])
        } else {
            blue["image"] = "models/blue.json"
        }
        if layer != .image {
            // The effect's own depth is deliberately opposite on an image; +0x108 must overwrite it.
            try json("materials/state-effect.json", material(shader: "genericimage3", texture: layer == .shape ? "blue" : "previous",
                                                             depthTest: layer == .shape ? depthTest : !depthTest,
                                                             depthWrite: !depthWrite, blending: "normal", culls: culls))
            try json("effects/state.json", ["passes": [["material": "materials/state-effect.json"]]])
            blue["effects"] = [["id": 3, "file": "effects/state.json", "visible": true]]
        }
        let scene: [String: Any] = ["camera": ["eye": "0 0 1", "center": "0 0 0", "up": "0 1 0"],
                                    "general": ["orthogonalprojection": ["width": 32, "height": 32],
                                                "clearcolor": "0 0 0", "cameraparallax": false, "camerashake": false],
                                    "objects": subjectFirst ? [blue, red] : [red, blue]]
        let sourceFiles = files
        let assets = WPEParityProgramAssets(sources: [.lookup(root) { sourceFiles[$0] }, .directory(engine)])
        for (path, expected) in Self.originalHashes {
            let data = try XCTUnwrap(assets.data(path), "Required original shader input \(path)")
            XCTAssertEqual(Self.sha256(data), expected, path)
        }
        for (path, data) in sourceFiles {
            XCTAssertEqual(assets.data(path), data, "Authored resource changed before planning: \(path)")
        }
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in MaterialStateNoScripts() })
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false), width: 32, height: 32)
        let subject = try XCTUnwrap(plan.frames[0].draws.first { _, value in
            guard case let .scene(draw) = value, draw.objectID == "2" else { return false }
            return layer == .image ? draw.geometry == .layerMesh : draw.effectID == "3"
        }?.key)
        let compiler = try bundledCompiler(workDirectory: root.appending(path: "shaderc"))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "cache")))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await WPEParityFrameRenderer(plan: plan, device: device, queue: queue,
                                                        shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity,
                                                                       bindingABIVersion: 1))
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        return Fixture(plan: plan, renderer: renderer, queue: queue, subject: subject)
    }

    private func render(_ fixture: Fixture) async throws -> WPEParityDraw {
        guard case let .committed(buffer) = try fixture.renderer.encodeFrame(elapsed: 1.0 / 60) else {
            throw NSError(domain: "MaterialState", code: 1, userInfo: [NSLocalizedDescriptionKey: "Frame was skipped"])
        }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        return try XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == fixture.subject }?.draw)
    }

    private func pixel(_ fixture: Fixture) throws -> [Int] {
        let output = try XCTUnwrap(fixture.queue.device.makeBuffer(length: 256, options: .storageModeShared))
        let command = try XCTUnwrap(fixture.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: fixture.renderer.backbuffer, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 16, y: 16, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: output, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        return (0 ..< 3).map { Int(output.contents().load(fromByteOffset: $0, as: UInt8.self)) }
    }

    private static func texture(_ pixel: [UInt8]) -> Data {
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for value: UInt32 in [UInt32(WPETexFormat.rgba8888.rawValue), 0, 2, 2, 2, 2, 0] {
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

    private func bundledCompiler(workDirectory: URL) throws -> WPEParityHelperShaderCompiler {
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath().standardizedFileURL
        for key in ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER",
                    "TEST_RUNNER_WPE_SHADERC", "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"] {
            XCTAssertNil(ProcessInfo.processInfo.environment[key], "Required bundled compiler disallows \(key)")
        }
        let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil, "Compiler escaped current bundle: \(url)")
            return url
        }
        let hashes = try tools.map { try Self.sha256(Data(contentsOf: $0)) }
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1],
                                                         metalIRConverter: tools[2], workDirectory: workDirectory)
        XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + hashes.joined(separator: " "))
        print("material state toolchain origin=current-app-bundle URLs=\(tools.map(\.path)) compilerIdentity=\(compiler.compilerIdentity)")
        return compiler
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let originalHashes = [
        "shaders/common.h": "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1",
        "shaders/common_blending.h": "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b",
        "shaders/common_pbr.h": "7a542df2279b6637d4f67434087df485b68ad24e06f85490d6ce424118c68d8d",
        "shaders/common_vertex.h": "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9",
        "shaders/genericimage2.frag": "1e252e2271cae57fcfdecf3bd79d1685bb726e1e8afe09ba863dca2e1b12d68e",
        "shaders/genericimage2.vert": "97370dbb18746d61629edf77ee2c30afe07605f5270f8a29a406b414932368bb",
        "shaders/genericimage3.frag": "552f2547b122dc04a3f9b5daeff3d1f2acdd15fa0e94502eed762503c11318f6",
        "shaders/genericimage3.vert": "b33f8506d1193d8ff0bda8de95a5d4777f75f71694557a70c3535a661b9e73c3",
    ]
}

private struct MaterialStateNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
