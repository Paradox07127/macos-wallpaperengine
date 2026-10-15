#if !LITE_BUILD && DEBUG
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Renders the two capture scenes whose programs match WPE byte for byte, through the real shader store.
final class WPEParityRealSceneTests: XCTestCase {
    private static let width = 1920
    private static let height = 1080
    /// The capture machine's settings, so programs carry the combos the captured shaders were compiled with.
    private static let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true)

    func testScene3815666789RendersThreeFrames() async throws {
        try await render("3815666789")
    }

    func testScene3660962877RendersThreeFrames() async throws {
        // Its camerashake is bound to a user property; object 935's captured MVP has V = I, so the capture ran without it.
        try await render("3660962877") { $0["camerashake"] = false }
    }

    /// Object 560's rope (genericropeparticle) and 747's spritetrail draw live particles, and the frame moves.
    func testScene3660962877DrawsParticles() async throws {
        let (plan, renderer, device, queue) = try await makeRenderer("3660962877") { $0["camerashake"] = false }
        let particleDraws = plan.frames[0].draws.keys.filter { renderer.particleRenderer($0) != nil }
        XCTAssertEqual(particleDraws.compactMap { renderer.particleRenderer($0)?.kind }.sorted { "\($0)" < "\($1)" },
                       [.rope, .spriteTrail])
        try await renderFrame(renderer, label: "scene 3660962877 frame 1")
        let first = try readBack(renderer.backbuffer, device: device, queue: queue)
        var vertices: [Int: Int] = [:]
        for frame in 2 ... 30 {
            try await renderFrame(renderer, label: "scene 3660962877 frame \(frame)")
            for (operation, draw) in renderer.lastFrameDraws where renderer.particleRenderer(operation) != nil {
                vertices[operation] = max(vertices[operation] ?? 0, draw.vertexCount)
            }
        }
        print("scene 3660962877: most particle vertices per draw over 30 frames \(vertices.sorted { $0.key < $1.key })")
        for operation in particleDraws {
            XCTAssertGreaterThan(vertices[operation] ?? 0, 0, "operation \(operation)")
        }
        let last = try readBack(renderer.backbuffer, device: device, queue: queue)
        XCTAssertNotEqual(first, last, "the frame did not change over 30 frames")
    }

    /// R17 C: with camerashake on, the shake moves every layer's view, so object 935's MVP changes with scene time.
    /// Parallax is off so only the shake can move the view.
    func testCameraShakeMovesLayerMatrices() async throws {
        func mvpChange(shake: Bool) async throws -> Float {
            let (plan, renderer, _, _) = try await makeRenderer("3660962877") { general in
                general["camerashake"] = shake
                general["cameraparallax"] = false
            }
            let index = try XCTUnwrap(plan.frames[0].draws.first { _, draw in
                if case let .scene(scene) = draw {
                    scene.objectID == "935" && scene.geometry == .layerMesh
                } else {
                    false
                }
            }?.key)
            let before = try XCTUnwrap(renderer.uniforms(index)).matrices.modelViewProjection
            guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 0.5) else {
                throw XCTSkip("frame skipped")
            }
            await commandBuffer.completed()
            let after = try XCTUnwrap(renderer.uniforms(index)).matrices.modelViewProjection
            return simd_length(after.columns.3 - before.columns.3)
        }
        let shaken = try await mvpChange(shake: true)
        let still = try await mvpChange(shake: false)
        print("object 935 MVP translation change over 0.5 s: shake \(shaken), no shake \(still)")
        XCTAssertGreaterThan(shaken, 1e-4)
        XCTAssertEqual(still, 0, accuracy: 1e-7)
    }

    private func render(_ sceneID: String, editGeneral: (inout [String: Any]) -> Void = { _ in }) async throws {
        let (plan, renderer, device, queue) = try await makeRenderer(sceneID, editGeneral: editGeneral)

        let reasons = Dictionary(grouping: renderer.skipped.values, by: \.category).mapValues(\.count)
        // Models are out of scope; every other draw must reach a pipeline. Objects hidden at load are planned too, and
        // the capture holds no shaders for their programs.
        var hiddenSkips = 0
        for (index, skip) in renderer.skipped.sorted(by: { $0.key < $1.key }) {
            if case let .scene(draw)? = plan.frames[0].draws[index], !plan.state.isVisible(draw.objectID) {
                hiddenSkips += 1
                continue
            }
            switch skip {
            case .modelMesh:
                print("scene \(sceneID) operation \(index) skipped: \(skip)")
            default:
                XCTFail("\(sceneID) operation \(index): \(skip)")
            }
        }
        print("scene \(sceneID): \(hiddenSkips) draws of objects hidden at load skipped")
        print("scene \(sceneID): draws \(renderer.drawCount) total, \(renderer.executedDrawCount) executed, "
            + "\(renderer.skipped.count) skipped \(reasons)")
        print("scene \(sceneID): transparent fallback textures \(renderer.fallbackTextures.sorted { $0.key < $1.key })")
        XCTAssertEqual(renderer.executedDrawCount + renderer.skipped.count, renderer.drawCount)
        if sceneID == "3660962877" {
            let visible = renderer.constants.keys.count { index in
                guard case let .scene(draw)? = plan.frames[0].draws[index] else { return true }
                return plan.state.isVisible(draw.objectID)
            }
            // 7 image and particle draws and 24 text draws, as the package matches 31/31.
            XCTAssertEqual(visible, 31)
        }

        // Declared constants outside the binding description and the engine uniform set stay zero.
        var zero: [String: [String]] = [:]
        for (index, stages) in renderer.zeroConstants.sorted(by: { $0.key < $1.key }) {
            let shader = plan.programs[index]?.shader ?? "?"
            for (stage, names) in stages {
                XCTAssertEqual(names.filter { !$0.hasPrefix("g_") }, [], "\(sceneID) operation \(index) \(shader) \(stage)")
                if shader == "effects/foliagesway" {
                    XCTAssertEqual(names, [], "\(sceneID) operation \(index) foliagesway \(stage)")
                }
                for name in names where !(zero["\(shader) \(stage)"]?.contains(name) ?? false) {
                    zero["\(shader) \(stage)", default: []].append(name)
                }
            }
        }
        print("scene \(sceneID): constants falling back to zero by shader and stage \(zero.sorted { $0.key < $1.key })")
        if sceneID == "3815666789" {
            // foliagesway's vertex stage reads `speed` (default 1), its fragment stage `speeduv` (scene 5).
            let foliage = renderer.constants.filter { plan.programs[$0.key]?.shader == "effects/foliagesway" }
            XCTAssertFalse(foliage.isEmpty)
            func float(_ value: WPECBufferValue?) -> Float? {
                if case let .float(number)? = value {
                    number
                } else {
                    nil
                }
            }
            for (index, stages) in foliage {
                XCTAssertEqual(float(stages[.vertex]?["g_Speed"]), 1, "operation \(index) vertex")
                XCTAssertEqual(float(stages[.fragment]?["g_Speed"]), 5, "operation \(index) fragment")
            }
        }

        if sceneID == "3660962877" {
            try assertObject935(plan: plan, renderer: renderer)
        }

        for frame in 1 ... 3 {
            try await renderFrame(renderer, label: "scene \(sceneID) frame \(frame)")
        }
        print("scene \(sceneID): heap \(renderer.heapBytes) bytes, dedicated textures "
            + "\(renderer.dedicatedTextureBytes) bytes")
        if sceneID == "3660962877" {
            try await assertVideoPlays(renderer: renderer, device: device, queue: queue)
        } else {
            XCTAssertEqual(renderer.videoTextures.count, 0)
        }

        let backbuffer = renderer.backbuffer
        XCTAssertEqual(backbuffer.pixelFormat, .rgba8Unorm)
        let pixels = try readBack(backbuffer, device: device, queue: queue)
        let first = Array(pixels.prefix(3))
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { Array(pixels[$0 ..< $0 + 3]) != first },
                      "\(sceneID) backbuffer is one flat colour \(first)")
        let translucent = stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] != 255 }
        XCTAssertEqual(translucent, 0, "\(sceneID) pixels with alpha below 1")

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "wpe-parity-\(sceneID).png")
        try writePNG(pixels, width: backbuffer.width, height: backbuffer.height, to: url)
        print("scene \(sceneID): frame 3 written to \(url.path)")
    }

    private func makeRenderer(
        _ sceneID: String, editGeneral: (inout [String: Any]) -> Void = { _ in }
    ) async throws -> (WPEParityFramePlan, WPEParityFrameRenderer, MTLDevice, MTLCommandQueue) {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        // The sandboxed test host's home is its container; the WPE install lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let sceneDirectory = root.appending(path: "scene-sources/\(sceneID)")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sceneDirectory.appending(path: "scene.json"))
        ) as? [String: Any])
        var general = json["general"] as? [String: Any] ?? [:]
        editGeneral(&general)
        json["general"] = general
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
        // The capture's wpeassets/ holds only shaders; util materials come from the WPE install.
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: Self.settings,
                                          width: Self.width, height: Self.height)

        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let geometryCompiler = try WPEParityHelperShaderCompiler.local(workDirectory: cache.appending(path: "shaderc"))
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms,
                                                     geometryCompiler: geometryCompiler),
            diskCache: WPEParityShaderDiskCache(cachesURL: cache)
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: "hlsl-capture-2026-10-12",
                                                bindingABIVersion: 1),
            particleSeed: 1
        )
        return (plan, renderer, device, queue)
    }

    private func renderFrame(_ renderer: WPEParityFrameRenderer, label: String) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("\(label) was skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error, label)
        let milliseconds = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        print("\(label): GPU \(String(format: "%.3f", milliseconds)) ms")
    }

    /// Object 1003 samples a 4000x2300 video .tex. Playback follows AVPlayer's wall clock, so once the first decoded
    /// frame lands, frames rendered 0.5 s apart hold different video pixels.
    private func assertVideoPlays(renderer: WPEParityFrameRenderer, device: MTLDevice,
                                  queue: MTLCommandQueue) async throws {
        XCTAssertEqual(renderer.videoTextures.count, 1)
        let video = try XCTUnwrap(renderer.videoTextures.first)
        XCTAssertEqual([video.width, video.height], [4000, 2300])
        XCTAssertEqual(video.pixelFormat, .bgra8Unorm)
        var before = try readBack(video, device: device, queue: queue)
        let deadline = Date().addingTimeInterval(10)
        var waits = 0
        while !before.contains(where: { $0 != 0 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            waits += 1
            try await renderFrame(renderer, label: "scene 3660962877 waiting for video frame \(waits)")
            before = try readBack(video, device: device, queue: queue)
        }
        XCTAssertTrue(before.contains { $0 != 0 }, "no decoded video frame reached the texture within 10 s")
        try await Task.sleep(for: .milliseconds(500))
        try await renderFrame(renderer, label: "scene 3660962877 video frame 0.5 s later")
        let after = try readBack(video, device: device, queue: queue)
        let changed = stride(from: 0, to: after.count, by: 4).count { after[$0 ..< $0 + 4] != before[$0 ..< $0 + 4] }
        print("scene 3660962877: \(changed) of \(after.count / 4) video texels changed over 0.5 s")
        XCTAssertGreaterThan(changed, 0)
    }

    /// R8 Q4: object 935's layer-mesh draw packs MVP rows as cbuffer registers. The spec values assume V = I, which
    /// this scene's camera gives; the package's camera and layer rules give the same matrix.
    private func assertObject935(plan: WPEParityFramePlan, renderer: WPEParityFrameRenderer) throws {
        let index = try XCTUnwrap(plan.frames[0].draws.first { _, draw in
            if case let .scene(scene) = draw {
                scene.objectID == "935" && scene.geometry == .layerMesh
            } else {
                false
            }
        }?.key)
        let draw = try XCTUnwrap(renderer.uniforms(index), "operation \(index) was skipped")
        guard case let .matrix(packed)? = draw.matrices.values["g_ModelViewProjectionMatrix"] else {
            return XCTFail("no g_ModelViewProjectionMatrix")
        }
        let layers = WPEParityLayerTransformSet(document: plan.document,
                                                renderTargetSize: SIMD2(Float(Self.width), Float(Self.height)))
        let expected = layers.draw("935", kind: .layer, parallax: .zero).matrices.modelViewProjection
        let spec: [[Float]] = [
            [-1.15e-8, 1.02761e-3, 0, -0.805596], [-5.55231e-3, -6.7e-9, 0, -0.199726],
            [0, 0, 2.5e-4, 0.5], [0, 0, 0, 1],
        ]
        for register in 0 ..< 4 {
            for component in 0 ..< 4 {
                let value = packed.columns[register][component]
                XCTAssertEqual(value, spec[register][component], accuracy: 1e-5, "spec c\(register).\(component)")
                XCTAssertEqual(value, expected[component][register], accuracy: 1e-5, "package c\(register).\(component)")
            }
        }
        XCTAssertEqual((draw.matrices.projection * SIMD4<Float>(0, 0, -2000, 1)).z, 0, accuracy: 1e-6)
        XCTAssertEqual((draw.matrices.projection * SIMD4<Float>(0, 0, 2000, 1)).z, 1, accuracy: 1e-6)
    }

    private func readBack(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
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

    private func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private struct NoScriptResolver: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
