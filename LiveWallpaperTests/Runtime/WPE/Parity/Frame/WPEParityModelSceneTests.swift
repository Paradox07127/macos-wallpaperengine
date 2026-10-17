#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Workshop 3437487219 (perspective model objects 112 Earth and 114 clouds in an orthographic scene) rendered end to
/// end: every model sub-mesh executes and lands inside its projected bounds.
final class WPEParityModelSceneTests: XCTestCase {
    private static let sceneID = "3437487219"
    private static let width = 1920
    private static let height = 1080

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-model-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testModelSubMeshesExecuteAndDrawInsideTheirBounds() async throws {
        let compiler = try makeCompiler()
        let plan = try makePlan()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appending(path: "shader-cache", directoryHint: .isDirectory)
        ))
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                bindingABIVersion: 1)
        )
        let models = plan.frames[0].draws.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
            guard case let .scene(scene) = draw, scene.geometry == .modelMesh else { return nil }
            return (index, scene)
        }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(models.map(\.1.pass.rawValue), ["112/mesh0", "114/mesh0"])
        for (index, draw) in models {
            XCTAssertNil(renderer.skipped[index], "\(draw.pass.rawValue): \(String(describing: renderer.skipped[index]))")
        }
        for (index, skip) in renderer.skipped.sorted(by: { $0.key < $1.key }) {
            print("scene \(Self.sceneID) operation \(index) skipped: \(skip)")
        }

        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 0) else {
            return XCTFail("frame 0 was skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error)
        let pixels = try readBack(renderer.backbuffer, device: device, queue: queue)

        let (index, earth) = models[0]
        let bounds = try XCTUnwrap(plan.scene.models[earth.objectID]?.meshes[0].bounds)
        let mvp = try XCTUnwrap(renderer.uniforms(index)).matrices.modelViewProjection
        var low = SIMD2<Float>(repeating: .infinity)
        var high = -low
        for corner in 0 ..< 8 {
            let point = SIMD3(corner & 1 == 0 ? bounds.minimum.x : bounds.maximum.x,
                              corner & 2 == 0 ? bounds.minimum.y : bounds.maximum.y,
                              corner & 4 == 0 ? bounds.minimum.z : bounds.maximum.z)
            let clip = mvp * SIMD4(point, 1)
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            let pixel = SIMD2((ndc.x + 1) / 2 * Float(Self.width), (1 - ndc.y) / 2 * Float(Self.height))
            low = simd_min(low, pixel)
            high = simd_max(high, pixel)
        }
        let size = SIMD2(Float(Self.width), Float(Self.height))
        let lower = SIMD2<Int>(simd_clamp(low, .zero, size), rounding: .down)
        let upper = SIMD2<Int>(simd_clamp(high, .zero, size), rounding: .up)
        print("scene \(Self.sceneID): Earth projects to \(low) – \(high)")
        XCTAssertTrue(lower.x < upper.x && lower.y < upper.y, "Earth bounds \(low) \(high) are off screen")
        let lit = (lower.y ..< max(lower.y, upper.y)).reduce(0) { count, row in
            count + (lower.x ..< max(lower.x, upper.x)).count { column in
                let offset = (row * Self.width + column) * 4
                return pixels[offset ..< offset + 3].contains { $0 > 0 }
            }
        }
        XCTAssertGreaterThan(lit, 0, "nothing drawn inside the Earth's projected bounds")
    }

    /// The local scenes with `"orthogonalprojection": null` draw through the perspective scene camera.
    func testPerspectiveScenesEncodeThreeFrames() async throws {
        let compiler = try makeCompiler()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for sceneID in ["3509243656", "3470948192", "3589454154"] {
            let plan = try makePlan(sceneID: sceneID)
            XCTAssertNotNil(plan.layout.frames.first, sceneID)
            let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
                cachesURL: scratch.appending(path: "shader-cache", directoryHint: .isDirectory)
            ))
            let renderer = try await WPEParityFrameRenderer(
                plan: plan, device: device, queue: queue,
                shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                    bindingABIVersion: 1)
            )
            for frame in 0 ..< 3 {
                guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: Double(frame) / 30)
                else { XCTFail("scene \(sceneID) frame \(frame) was skipped"); continue }
                await commandBuffer.completed()
                XCTAssertNil(commandBuffer.error, "scene \(sceneID) frame \(frame)")
            }
        }
    }

    private func makeCompiler() throws -> WPEParityHelperShaderCompiler {
        try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
    }

    private func makePlan(sceneID: String = WPEParityModelSceneTests.sceneID) throws -> WPEParityFramePlan {
        // The sandboxed test host's home is its container; Steam lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let folder = steam.appending(path: "workshop/content/431960/\(sceneID)", directoryHint: .isDirectory)
        let package = folder.appending(path: "scene.pkg")
        let engineRoot = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop \(sceneID) and WPE's assets (or WPE_ASSETS_DIR)")
        }
        let assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engineRoot)
        let document = try WPESceneDocumentParser.parse(
            data: XCTUnwrap(assets.data("scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoModelScripts() }
        )
        return try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                      width: Self.width, height: Self.height)
    }

    private func readBack(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        XCTAssertEqual([texture.width, texture.height], [Self.width, Self.height])
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }
}

private struct NoModelScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
