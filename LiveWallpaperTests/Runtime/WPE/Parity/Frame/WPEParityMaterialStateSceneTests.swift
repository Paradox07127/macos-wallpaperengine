#if !LITE_BUILD && DEBUG
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
        // Missing original shader files fail this product gate; a synthetic shader cannot establish this contract.
        for name in ["genericimage2", "genericimage3"] {
            for suffix in ["vert", "frag"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: engine.appending(path: "shaders/\(name).\(suffix)").path))
            }
        }
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
        func json(_ name: String, _ value: Any) throws {
            files[name] = try JSONSerialization.data(withJSONObject: value)
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
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in MaterialStateNoScripts() })
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false), width: 32, height: 32)
        let subject = try XCTUnwrap(plan.frames[0].draws.first { _, value in
            guard case let .scene(draw) = value, draw.objectID == "2" else { return false }
            return layer == .image ? draw.geometry == .layerMesh : draw.effectID == "3"
        }?.key)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: root.appending(path: "shaderc"))
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
        for value: UInt32 in [UInt32(WPETexFormat.rgba8888.rawValue), 0, 2, 2, 2, 2, 0] { word(value) }
        data.append(contentsOf: "TEXB0003\0".utf8)
        for value: UInt32 in [1, .max, 1, 2, 2, 0, 16, 16] { word(value) }
        for _ in 0 ..< 4 { data.append(contentsOf: pixel) }
        return data
    }
}

private struct MaterialStateNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? { nil }
}
#endif
