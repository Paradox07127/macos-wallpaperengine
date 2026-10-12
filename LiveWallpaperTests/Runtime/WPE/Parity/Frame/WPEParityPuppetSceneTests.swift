#if !LITE_BUILD && DEBUG
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Workshop 2370640409 (puppet layers 43 direct, 47 and 51 bit4) compiled by wpe-shaderc and rendered end to end.
final class WPEParityPuppetSceneTests: XCTestCase {
    private static let sceneID = "2370640409"
    private static let width = 1920
    private static let height = 1080

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-puppet-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testPuppetSceneCompilesRendersAndAnimates() async throws {
        let compiler = try makeCompiler()
        let plan = try makePlan()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = scratch.appending(path: "shader-cache", directoryHint: .isDirectory)

        let requests = plan.programs.values.map {
            WPEParityShaderCompileRequest(program: $0.hlsl, compilerIdentity: compiler.compilerIdentity,
                                          bindingABIVersion: 1)
        }
        let unique = Dictionary(requests.map { ($0.key, $0.stages.count) }) { first, _ in first }
        var start = ContinuousClock.now
        let renderer = try await makeRenderer(plan, compiler: compiler, cache: cache, device: device, queue: queue)
        print("scene \(Self.sceneID) cold build: \(plan.programs.count) programs, \(unique.count) unique, "
            + "\(unique.values.reduce(0, +)) stages, \(ContinuousClock.now - start)")
        start = ContinuousClock.now
        let warm = try await makeRenderer(plan, compiler: compiler, cache: cache, device: device, queue: queue)
        print("scene \(Self.sceneID) warm build (disk cache): \(ContinuousClock.now - start)")
        XCTAssertEqual(warm.skipped, renderer.skipped)

        for (index, skip) in renderer.skipped.sorted(by: { $0.key < $1.key }) {
            switch skip {
            case .modelMesh:
                print("scene \(Self.sceneID) operation \(index) skipped: \(skip)")
            default:
                XCTFail("operation \(index): \(skip)")
            }
        }
        print("scene \(Self.sceneID): draws \(renderer.drawCount) total, \(renderer.executedDrawCount) executed, "
            + "\(renderer.skipped.count) skipped")
        XCTAssertEqual(renderer.executedDrawCount + renderer.skipped.count, renderer.drawCount)
        XCTAssertEqual(renderer.puppets.keys.sorted(), ["43", "47", "51"])

        try await renderFrame(renderer, elapsed: 0, label: "frame 0")
        let first = try readBack(renderer.backbuffer, device: device, queue: queue)
        for frame in 1 ... 60 {
            try await renderFrame(renderer, elapsed: 1.0 / 60, label: "frame \(frame)")
        }
        let later = try readBack(renderer.backbuffer, device: device, queue: queue)

        let bounds = try puppetBounds(plan: plan, renderer: renderer)
        print("scene \(Self.sceneID): puppet layers' screen bounds \(bounds)")
        let changed = changedPixels(first, later, in: bounds)
        let wholeFrame = changedPixels(first, later, in: (0 ..< Self.width, 0 ..< Self.height))
        print("scene \(Self.sceneID): \(changed) of \(bounds.0.count * bounds.1.count) pixels in the puppet bounds "
            + "and \(wholeFrame) of \(Self.width * Self.height) in the frame changed over 1 s of scene time")
        XCTAssertGreaterThan(changed, 0, "the puppet layers did not move")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        for (pixels, suffix) in [(first, "f0"), (later, "f1s")] {
            let url = directory.appending(path: "wpe-parity-puppet-\(Self.sceneID)-\(suffix).png")
            try writePNG(pixels, to: url)
            print("scene \(Self.sceneID): wrote \(url.path)")
        }
    }

    private func makeCompiler() throws -> WPEParityHelperShaderCompiler {
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
        return try WPEParityHelperShaderCompiler(helper: helper, dxcompiler: dxcompiler, metalIRConverter: converter,
                                                 workDirectory: scratch.appending(path: "shaderc"))
    }

    private func makePlan() throws -> WPEParityFramePlan {
        // The sandboxed test host's home is its container; Steam lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let package = steam.appending(path: "workshop/content/431960/\(Self.sceneID)/scene.pkg")
        let install = steam.appending(path: "common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Needs Workshop \(Self.sceneID) and WPE's assets (or WPE_ASSETS_DIR)")
        }
        // Named after the workshop id, which the video textures read from the scene directory.
        let sceneDirectory = scratch.appending(path: Self.sceneID, directoryHint: .isDirectory)
        try Self.unpack(package, into: sceneDirectory)
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: sceneDirectory.appending(path: "scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        return try WPEParityFramePlan(document: document, sceneDirectory: sceneDirectory, assetRoots: [wpeAssets],
                                      settings: WPEParityProgramSettings(), width: Self.width, height: Self.height)
    }

    private func makeRenderer(_ plan: WPEParityFramePlan, compiler: WPEParityHelperShaderCompiler, cache: URL,
                              device: MTLDevice, queue: MTLCommandQueue) async throws -> WPEParityFrameRenderer {
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
        return try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                bindingABIVersion: 1)
        )
    }

    /// Bind-pose puppet vertices through each puppet draw's MVP, padded by half the size for the bones' motion.
    private func puppetBounds(plan: WPEParityFramePlan,
                              renderer: WPEParityFrameRenderer) throws -> (Range<Int>, Range<Int>) {
        var low = SIMD2<Float>(repeating: .infinity)
        var high = -low
        for (index, draw) in plan.frames[0].draws {
            guard case let .scene(scene) = draw, scene.geometry == .puppetMesh else { continue }
            let puppet = try XCTUnwrap(plan.scene.scene.objects.first { $0.id == scene.objectID }?.puppet)
            let mvp = try XCTUnwrap(renderer.uniforms(index), "operation \(index)").matrices.modelViewProjection
            for vertex in puppet.vertices {
                let clip = mvp * SIMD4(vertex.position, 1)
                let ndc = SIMD2(clip.x, clip.y) / clip.w
                let pixel = SIMD2((ndc.x + 1) / 2 * Float(Self.width), (1 - ndc.y) / 2 * Float(Self.height))
                low = simd_min(low, pixel)
                high = simd_max(high, pixel)
            }
        }
        let pad = (high - low) / 2
        let size = SIMD2(Float(Self.width), Float(Self.height))
        let lower = SIMD2<Int>(simd_clamp(low - pad, .zero, size), rounding: .down)
        let upper = SIMD2<Int>(simd_clamp(high + pad, .zero, size), rounding: .up)
        XCTAssertTrue(lower.x < upper.x && lower.y < upper.y, "puppet bounds \(low) \(high) are off screen")
        return (lower.x ..< max(lower.x, upper.x), lower.y ..< max(lower.y, upper.y))
    }

    private func changedPixels(_ before: [UInt8], _ after: [UInt8], in bounds: (Range<Int>, Range<Int>)) -> Int {
        bounds.1.reduce(0) { count, row in
            count + bounds.0.count { column in
                let offset = (row * Self.width + column) * 4
                return before[offset ..< offset + 4] != after[offset ..< offset + 4]
            }
        }
    }

    private func renderFrame(_ renderer: WPEParityFrameRenderer, elapsed: Double, label: String) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: elapsed) else {
            return XCTFail("\(label) was skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error, label)
    }

    private func readBack(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        XCTAssertEqual([texture.width, texture.height], [Self.width, Self.height])
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

    private func writePNG(_ pixels: [UInt8], to url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// PKGV: a length-prefixed version, the entry table (name, offset, size), then the entry bytes.
    private static func unpack(_ package: URL, into root: URL) throws {
        let bytes = try [UInt8](Data(contentsOf: package))
        var offset = 0
        func uint32() -> Int {
            defer { offset += 4 }
            return (0 ..< 4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        func string() -> String {
            let count = uint32()
            defer { offset += count }
            return String(bytes: bytes[offset ..< offset + count], encoding: .utf8) ?? ""
        }
        _ = string()
        let entries = (0 ..< uint32()).map { _ in (name: string(), offset: uint32(), size: uint32()) }
        for entry in entries {
            let url = root.appending(path: entry.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let start = offset + entry.offset
            try Data(bytes[start ..< start + entry.size]).write(to: url)
        }
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
