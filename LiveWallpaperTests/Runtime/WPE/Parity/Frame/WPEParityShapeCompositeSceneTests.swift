#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// Local Workshop scenes with cross-layer composite reads (3509243656) and a shape quad (3437487219), rendered end to
/// end through the helper shader compiler.
final class WPEParityShapeCompositeSceneTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-shape-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// Models 436 and 331 sample `_rt_imageLayerComposite_433_a` / `_589_a`; their `dependencies` give 433 and 589
    /// the composite, and 589, hidden, keeps filling it.
    func testModelDrawsSampleTheLayerCompositesTheyDependOn() async throws {
        let (plan, renderer) = try await makeRenderer("3509243656")
        let frame = plan.frames[0]
        func drawIndex(_ pass: WPEPassIdentity) throws -> Int {
            try XCTUnwrap(frame.draws.keys.first { frame.operations[$0].pass == pass }, "\(pass) has no draw")
        }
        for (pass, composite) in [("436/mesh0", "_rt_imageLayerComposite_433_a"),
                                  ("331/mesh0", "_rt_imageLayerComposite_589_a")] {
            let index = try drawIndex(WPEPassIdentity(pass))
            guard case let .scene(draw)? = frame.draws[index] else { return XCTFail("\(pass) has no scene draw") }
            XCTAssertEqual(draw.reads, [WPEResourceID(composite)], pass)
            XCTAssertNil(renderer.skipped[index], "\(pass): \(String(describing: renderer.skipped[index]))")
        }
        let fill = try drawIndex("589/albedo")
        XCTAssertNil(frame.owners[fill], "589's composite fill would stop while 589 is hidden")
        // The plan holds every object; the renderer drops the scene draw while 589 stays hidden.
        XCTAssertEqual(try frame.owners[drawIndex("589/passthrough4")], "589")

        for _ in 0 ..< 2 {
            try await renderFrame(renderer)
        }
        let executed = Set(renderer.lastFrameDraws.map(\.operation))
        let model = try drawIndex("436/mesh0")
        XCTAssertTrue(executed.contains(model), "436/mesh0 did not draw")
        XCTAssertTrue(executed.contains(fill), "hidden 589 stopped filling its composite")
    }

    /// Shape 116's lightshafts pass draws its four-point quad additive with DIRECTDRAW=1.
    func testShapeQuadDrawsItsPointQuad() async throws {
        let (plan, renderer) = try await makeRenderer("3437487219")
        let frame = plan.frames[0]
        let index = try XCTUnwrap(frame.draws.first { _, draw in
            if case let .scene(scene) = draw {
                scene.objectID == "116" && scene.geometry == .shapeQuad
            } else {
                false
            }
        }?.key)
        guard case let .scene(draw)? = frame.draws[index] else { return XCTFail("no shape draw") }
        XCTAssertEqual(draw.blend, .additive)
        XCTAssertEqual(draw.source?.combos["DIRECTDRAW"], 1)
        guard case let .shape(shape)? = plan.scene.scene.objects.first(where: { $0.id == "116" })?.kind else {
            return XCTFail("116 is not a shape")
        }
        XCTAssertEqual(shape.points?.first, SIMD2(6.83764, -3.17560))
        XCTAssertNil(renderer.skipped[index], String(describing: renderer.skipped[index]))
        try await renderFrame(renderer)
        let executed = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == index }?.draw)
        XCTAssertEqual(executed.indexCount, 6)
    }

    private func renderFrame(_ renderer: WPEParityFrameRenderer) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("frame skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error)
    }

    private func makeRenderer(_ sceneID: String) async throws -> (WPEParityFramePlan, WPEParityFrameRenderer) {
        let environment = ProcessInfo.processInfo.environment
        func path(_ key: String, _ fallback: String) -> URL {
            URL(fileURLWithPath: environment[key] ?? fallback)
        }
        let helper = path("WPE_SHADERC", "/Users/example/Developer/wpe-shaderc-build/wpe-shaderc")
        let dxcompiler = path("WPE_DXCOMPILER",
                              "/Users/example/Developer/DirectXShaderCompiler/build-14.6/lib/libdxcompiler.dylib")
        let converter = path("WPE_METALIRCONVERTER", "/usr/local/lib/libmetalirconverter.dylib")
        for url in [helper, dxcompiler, converter] where !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("Missing \(url.path); set WPE_SHADERC, WPE_DXCOMPILER and WPE_METALIRCONVERTER")
        }
        let compiler = try WPEParityHelperShaderCompiler(helper: helper, dxcompiler: dxcompiler,
                                                         metalIRConverter: converter,
                                                         workDirectory: scratch.appending(path: "shaderc"))
        // The sandboxed test host's home is its container; Steam lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let folder = steam.appending(path: "workshop/content/431960/\(sceneID)", directoryHint: .isDirectory)
        let package = folder.appending(path: "scene.pkg")
        let engineRoot = environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop \(sceneID) and WPE's assets (or WPE_ASSETS_DIR)")
        }
        let assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engineRoot)
        let document = try WPESceneDocumentParser.parse(
            data: XCTUnwrap(assets.data("scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoShapeSceneScripts() }
        )
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                          width: 1920, height: 1080)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appending(path: "shader-cache", directoryHint: .isDirectory)
        ))
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                bindingABIVersion: 1)
        )
        return (plan, renderer)
    }
}

private struct NoShapeSceneScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
