#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// Two renderers of one scene on one device, as on two screens, sample one imported TEX upload.
final class WPEParityImportedTextureSharingTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-texture-sharing-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// Without one device object per process, renderers on different screens would never share.
    func testSystemDefaultDeviceIsOneObject() {
        XCTAssertTrue(MTLCreateSystemDefaultDevice() === MTLCreateSystemDefaultDevice())
    }

    func testRenderersOfOneSceneShareTheImportedTextureUntilBothAreReleased() async throws {
        let name = "share-\(UUID().uuidString)"
        let files = try Self.files(texture: name)
        let subject = { (draw: WPEParitySceneDraw) in draw.objectID == "1" && draw.geometry == .layerMesh }
        var first: Fixture? = try await makeRenderer(files: files, subject: subject)
        var second: Fixture? = try await makeRenderer(files: files, subject: subject)
        weak var shared: MTLTexture?
        try autoreleasepool {
            let a = try render(XCTUnwrap(first))
            let b = try render(XCTUnwrap(second))
            XCTAssertTrue(a === b)
            shared = a
        }
        XCTAssertNotNil(shared)
        first = nil
        second = nil
        XCTAssertNil(shared)
    }

    private struct Fixture {
        let renderer: WPEParityFrameRenderer
        let subject: Int
    }

    private static func files(texture: String) throws -> [String: Data] {
        var files = ["materials/\(texture).tex": Self.texture(seed: Data(texture.utf8))]
        func json(_ name: String, _ value: Any) throws {
            files[name] = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }
        try json("models/share.json", ["material": "materials/share.json"])
        try json("materials/share.json", ["passes": [["shader": "genericimage2", "textures": [texture],
                                                      "blending": "normal", "depthtest": "disabled",
                                                      "depthwrite": "disabled", "cullmode": "nocull"]]])
        return files
    }

    private func makeRenderer(files sourceFiles: [String: Data],
                              subject isSubject: (WPEParitySceneDraw) -> Bool) async throws -> Fixture {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let root = scratch.appending(path: UUID().uuidString)
        let assets = WPEParityProgramAssets(sources: [.lookup(root) { sourceFiles[$0] }, .directory(engine)])
        let layer: [String: Any] = ["id": 1, "image": "models/share.json", "size": "32 32", "origin": "16 16 0"]
        let scene: [String: Any] = ["camera": ["eye": "0 0 1", "center": "0 0 0", "up": "0 1 0"],
                                    "general": ["orthogonalprojection": ["width": 32, "height": 32],
                                                "clearcolor": "0 0 0", "cameraparallax": false, "camerashake": false],
                                    "objects": [layer]]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in SharingNoScripts() })
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false), width: 32, height: 32)
        let subject = try XCTUnwrap(plan.frames[0].draws.first { _, value in
            guard case let .scene(draw) = value else { return false }
            return isSubject(draw)
        }?.key)
        let compiler = try bundledCompiler(workDirectory: root.appending(path: "shaderc"))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "cache")))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await WPEParityFrameRenderer(plan: plan, device: device, queue: queue,
                                                        shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity,
                                                                       bindingABIVersion: 1))
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        return Fixture(renderer: renderer, subject: subject)
    }

    /// Synchronous so the caller's autorelease pool drains every frame object before the weak check.
    private func render(_ fixture: Fixture) throws -> MTLTexture {
        guard case let .committed(buffer) = try fixture.renderer.encodeFrame(elapsed: 1.0 / 60) else {
            throw NSError(domain: "TextureSharing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Frame was skipped"])
        }
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        let draw = try XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == fixture.subject }?.draw)
        return try XCTUnwrap(draw.textures["g_Texture0"])
    }

    /// A 4×4 RGBA8 TEX whose texels derive from `seed`, so no other test uploads the same bytes.
    private static func texture(seed: Data) -> Data {
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for value: UInt32 in [UInt32(WPETexFormat.rgba8888.rawValue), 0, 4, 4, 4, 4, 0] {
            word(value)
        }
        data.append(contentsOf: "TEXB0003\0".utf8)
        for value: UInt32 in [1, .max, 1, 4, 4, 0, 64, 64] {
            word(value)
        }
        data.append(contentsOf: (0 ..< 64).map { seed[seed.startIndex + $0 % seed.count] })
        return data
    }

    private func bundledCompiler(workDirectory: URL) throws -> WPEParityHelperShaderCompiler {
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath().standardizedFileURL
        let tools = ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map {
            contents.appending(path: $0).resolvingSymlinksInPath().standardizedFileURL
        }
        return try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1],
                                                 metalIRConverter: tools[2], workDirectory: workDirectory)
    }
}

private struct SharingNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
