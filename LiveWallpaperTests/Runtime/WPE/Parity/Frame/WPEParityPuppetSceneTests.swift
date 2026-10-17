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
            XCTFail("operation \(index): \(skip)")
        }
        print("scene \(Self.sceneID): draws \(renderer.drawCount) total, \(renderer.executedDrawCount) executed, "
            + "\(renderer.skipped.count) skipped")
        XCTAssertEqual(renderer.executedDrawCount + renderer.skipped.count, renderer.drawCount)
        XCTAssertEqual(renderer.executedDrawCount, 55)
        XCTAssertEqual(plan.frames[0].draws.keys.count { renderer.particleRenderer($0) != nil }, 13)
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

    /// Workshop 3808922316: its bit4 puppets have clip groups, so they draw segments, masks and clipped parts.
    func testClipGroupSceneDrawsMasksAndClippedSegments() async throws {
        let compiler = try makeCompiler()
        let plan = try makePlan("3808922316")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(plan, compiler: compiler,
                                              cache: scratch.appending(path: "shader-cache", directoryHint: .isDirectory),
                                              device: device, queue: queue)
        let clipDraws = renderer.frames[0].draws.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
            guard case let .scene(scene) = draw, case .puppetSegment = scene.geometry else { return nil }
            return (index, scene)
        }
        XCTAssertTrue(clipDraws.contains { $0.1.target == WPEParitySceneResource.fullAlphaMask })
        XCTAssertTrue(clipDraws.contains { $0.1.source?.combos["CLIPPINGTARGET"] == 1 })
        for (index, draw) in clipDraws {
            XCTAssertNil(renderer.skipped[index], draw.pass.rawValue)
        }
        try await renderFrame(renderer, elapsed: 0, label: "frame 0")
        let encoded = Set(renderer.lastFrameDraws.map(\.operation))
        let visible = Set(plan.scene.scene.objects.filter(\.visible).map(\.id))
        let shown = clipDraws.filter { visible.contains($0.1.objectID) }
        print("scene 3808922316: \(clipDraws.count) clip draws, \(shown.count) of visible layers, "
            + "\(clipDraws.count { encoded.contains($0.0) }) encoded")
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(shown.allSatisfy { encoded.contains($0.0) })
    }

    /// Workshop 3808922316's wing-layer script, here on object 47's only animation layer at 50 %.
    func testAnimationLayerScriptSeeksThePuppetLayer() async throws {
        let script = """
        'use strict';
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'percentage', label: 'Initial progress', value: 1, min: 0, max: 1, integer: false })
            .finish();
        export function init(value) {
            const ani = 'addEndedCallback' in thisObject ? thisObject : thisObject.getAnimation()
            ani.play()
            ani.setFrame(ani.frameCount * scriptProperties.percentage)
            return value;
        }
        """
        let compiler = try makeCompiler()
        let plan = try makePlan { json in
            Self.edit(&json, object: 47) { object in
                var layers = object["animationlayers"] as? [[String: Any]] ?? []
                layers[0]["visible"] = ["value": true, "script": script, "scriptproperties": ["percentage": 0.5]]
                object["animationlayers"] = layers
            }
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(plan, compiler: compiler,
                                              cache: scratch.appending(path: "shader-cache", directoryHint: .isDirectory),
                                              device: device, queue: queue)
        let sceneScript = try WPEParitySceneScript(
            document: plan.document, state: renderer.state, assets: plan.scene.assets,
            canvasSize: renderer.pathCamera.size,
            screenResolution: SIMD2(Float(renderer.backbuffer.width), Float(renderer.backbuffer.height)),
            materialConstants: plan.materialConstants, resolvedEffectRecords: plan.scene.resolvedEffectRecords,
            host: .init()
        )
        try renderer.attachScript(sceneScript)
        XCTAssertEqual(sceneScript.engine.exceptionCount, 0, sceneScript.engine.exceptions.joined(separator: "\n"))
        let seeked = try XCTUnwrap(renderer.puppets["47"]?.layers[0])
        XCTAssertEqual(seeked.frame, 0.5 * Float(seeked.animation.frameCount), accuracy: 1e-3)
        try await renderFrame(renderer, elapsed: 1.0 / 60, label: "frame 1")
        let advanced = try XCTUnwrap(renderer.puppets["47"]?.layers[0])
        XCTAssertEqual(advanced.frame, seeked.frame + seeked.fps / 60, accuracy: 1e-3)
    }

    /// Workshop 3647999330: the rope's click flag makes object 545's update stop "sss" and play "LogoShake" by name.
    func testClickOnTheRopeStopsSssAndKeepsLogoShakePlaying() async throws {
        let compiler = try makeCompiler()
        let plan = try makePlan("3647999330")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(plan, compiler: compiler,
                                              cache: scratch.appending(path: "shader-cache", directoryHint: .isDirectory),
                                              device: device, queue: queue)
        let sceneScript = try WPEParitySceneScript(
            document: plan.document, state: renderer.state, assets: plan.scene.assets,
            canvasSize: renderer.pathCamera.size,
            screenResolution: SIMD2(Float(renderer.backbuffer.width), Float(renderer.backbuffer.height)),
            materialConstants: plan.materialConstants, resolvedEffectRecords: plan.scene.resolvedEffectRecords,
            host: .init()
        )
        try renderer.attachScript(sceneScript)
        try await renderFrame(renderer, elapsed: 1.0 / 60, label: "frame 1")
        let exceptions = sceneScript.engine.exceptionCount
        sceneScript.engine.dispatch(.cursorClick, payloadJSON: #"{"world":[0,0,0],"local":[0,0,0],"hitBox":null}"#,
                                    target: "64", state: &renderer.state)
        try await renderFrame(renderer, elapsed: 1.0 / 60, label: "frame 2")
        try await renderFrame(renderer, elapsed: 1.0 / 60, label: "frame 3")
        XCTAssertEqual(sceneScript.engine.exceptionCount, exceptions, sceneScript.engine.exceptions.joined(separator: "\n"))
        let puppet = try XCTUnwrap(renderer.puppets["545"])
        let sss = try XCTUnwrap(puppet.layers.first { $0.sceneIndex == 1 })
        XCTAssertFalse(sss.isPlaying)
        XCTAssertEqual(sss.frame, 0)
        XCTAssertTrue(try XCTUnwrap(puppet.layers.first { $0.sceneIndex == 7 }).isPlaying)
    }

    private static func edit(_ json: inout [String: Any], object id: Int, _ body: (inout [String: Any]) -> Void) {
        var objects = json["objects"] as? [[String: Any]] ?? []
        for index in objects.indices where objects[index]["id"] as? Int == id {
            body(&objects[index])
        }
        json["objects"] = objects
    }

    private func makeCompiler() throws -> WPEParityHelperShaderCompiler {
        try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
    }

    private func makePlan(_ sceneID: String = sceneID,
                          edit: ((inout [String: Any]) -> Void)? = nil) throws -> WPEParityFramePlan {
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
        // Read in place from scene.pkg; the folder is named after the workshop id the video textures use.
        let assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engineRoot)
        var data = try XCTUnwrap(assets.data("scene.json"))
        if let edit {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            edit(&json)
            data = try JSONSerialization.data(withJSONObject: json)
        }
        let document = try WPESceneDocumentParser.parse(
            data: data, userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        return try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                      width: Self.width, height: Self.height)
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
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
