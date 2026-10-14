#if !LITE_BUILD && DEBUG
import Darwin
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Original WPE util shaders compiled by the selected helper, then production frame and present encoders.
final class WPEParityPostProcessProductTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("parity-post-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testOriginalHDRTerminalDecodesGrayOnceBeforeSRGBPresent() async throws {
        let engine = try engineAssets()
        let assets = WPEParityProgramAssets(sceneDirectory: scratch, assetRoots: [engine])
        let plan = try clearPlan(assets: assets, color: "0.5 0.5 0.5", hdr: true)
        XCTAssertTrue(plan.post.hdrEnabled)
        XCTAssertFalse(plan.post.bloomEnabled)
        XCTAssertEqual(plan.colorTransfer, .linear)
        let terminal = try postIndex("combine_srgb", in: plan)
        XCTAssertEqual(plan.programs[terminal]?.shader, "passthroughsrgb")
        XCTAssertEqual(plan.frames[0].draws.count, 1)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(plan, device: device, queue: queue)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        try await render(renderer)
        XCTAssertEqual(renderer.lastFrameDraws.map(\.operation), [terminal])
        XCTAssertEqual(renderer.backbuffer.pixelFormat, .rgba16Float)
        let linearBytes = try read(renderer.backbuffer, bytesPerPixel: 8, device: device, queue: queue)
        let center = (renderer.backbuffer.height / 2 * renderer.backbuffer.width + renderer.backbuffer.width / 2) * 8
        for lane in 0 ..< 3 {
            let offset = center + lane * 2
            let bits = UInt16(linearBytes[offset]) | UInt16(linearBytes[offset + 1]) << 8
            XCTAssertEqual(Float(Float16(bitPattern: bits)), 0.21404114, accuracy: 0.001)
        }
        let pixels = try await present(renderer, device: device, queue: queue)
        let pixel = centerRGBA(pixels, width: renderer.backbuffer.width, height: renderer.backbuffer.height)
        for value in pixel.prefix(3) {
            XCTAssertEqual(Double(value), 128, accuracy: 3, "HDR terminal plus present must decode only once")
            XCTAssertGreaterThan(abs(Int(value) - 55), 50, "a second sRGB decode produces approximately 55")
        }
        XCTAssertEqual(pixel[3], 255)
    }

    func testMissingOrUnsupportedRequiredHDRTerminalRejectsRendererBeforePresent() async throws {
        let engine = try engineAssets()
        let path = "materials/util/combine_srgb.json"
        var material = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: engine.appendingPathComponent(path)))
            as? [String: Any])
        var passes = try XCTUnwrap(material["passes"] as? [[String: Any]])
        passes[0]["combos"] = ["LINEAR": 1]
        material["passes"] = passes
        let unsupported = try JSONSerialization.data(withJSONObject: material)
        for unsupportedVariant in [false, true] {
            let replacement = unsupportedVariant ? unsupported : nil
            let assets = WPEParityProgramAssets(sources: [.lookup(engine) { name in
                if name == path {
                    return replacement
                }
                if !unsupportedVariant, name == "shaders/combine_srgb.vert" {
                    return nil
                }
                return try? Data(contentsOf: engine.appendingPathComponent(name))
            }])
            let plan = try clearPlan(assets: assets, color: "0.5 0.5 0.5", hdr: true)
            let terminal = try postIndex("combine_srgb", in: plan)
            if unsupportedVariant {
                XCTAssertTrue(plan.programs[terminal]?.combos.contains { $0.name == "LINEAR" && $0.value == "1" } == true)
            } else {
                XCTAssertNil(plan.programs[terminal])
                XCTAssertEqual(plan.skipped[terminal], .program("combine_srgb: missingShader(\"shaders/combine_srgb.vert\")"))
            }
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let queue = try XCTUnwrap(device.makeCommandQueue())
            do {
                _ = try await makeRenderer(plan, device: device, queue: queue)
                XCTFail("an absent or unsupported HDR terminal must never publish a frame as linear")
            } catch let error as WPEParityFrameRenderError {
                guard case let .requiredPostProcessUnavailable(pass, reason) = error else {
                    return XCTFail("unexpected renderer failure: \(error)")
                }
                XCTAssertEqual(pass, "combine_srgb")
                if unsupportedVariant {
                    guard case let .program(message) = reason else { return XCTFail("unexpected reason: \(reason)") }
                    XCTAssertTrue(message.contains("Unsupported HDR presentation shader or transfer combo"))
                } else {
                    XCTAssertEqual(reason, .program("combine_srgb: missingShader(\"shaders/combine_srgb.vert\")"))
                }
            }
        }
    }

    /// COL maps the clear RGB (0, .5, 1) to (.25, .5, .75); the raw LUT maps (x,y,z) to (z,x,y).
    func testOriginalColorCorrectionUsesConstantsAndSlotOneRawVolumeAxes() async throws {
        let engine = try engineAssets()
        let lut = rawAxisLUT()
        let assets = WPEParityProgramAssets(sources: [
            .lookup(scratch) { $0 == "materials/lut/axis-swap.tex" ? lut : nil }, .directory(engine),
        ])
        let correction = WPEParityColorCorrection(wecE: true, wecCon: 12.5, wccV: "axis-swap", wccAmt: 100)
        let plan = try clearPlan(assets: assets, color: "0 0.5 1", correction: correction)
        let index = try postIndex("ccsimple", in: plan)
        XCTAssertEqual(plan.programs[index]?.shader, "ccsimple")
        XCTAssertEqual(plan.bindings[0][index]?.textures[1], .asset("lut/axis-swap"))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(plan, device: device, queue: queue)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertTrue(renderer.fallbackTextures.isEmpty)
        try await render(renderer)
        let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == index }?.draw)
        XCTAssertEqual(components(draw.constants[.fragment]?["g_Params"]), [1, 0.5, 1, 0])
        XCTAssertEqual(components(draw.constants[.fragment]?["g_LutParams"]), [1])
        let volume = try XCTUnwrap(draw.textures["g_Texture1"])
        XCTAssertEqual(volume.textureType, .type3D)
        XCTAssertEqual([volume.width, volume.height, volume.depth], [2, 2, 2])
        let pixels = try await present(renderer, device: device, queue: queue)
        let pixel = centerRGBA(pixels, width: renderer.backbuffer.width, height: renderer.backbuffer.height)
        for (actual, expected) in zip(pixel, [255, 0, 128, 255]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 3, "LUT x is row-major, then y, then z; shader uses RGB as xyz")
        }
    }

    func testRealModelMSAATargetsPipelinesResolveAndPostExecute() async throws {
        let engine = try engineAssets()
        let home = try realHome()
        let folder = home.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/workshop/content/431960/3437487219"
        )
        let package = folder.appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw XCTSkip("Needs actual MDL models in Workshop 3437487219")
        }
        let assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engine.deletingLastPathComponent())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(assets.data("scene.json"))) as? [String: Any])
        var general = json["general"] as? [String: Any] ?? [:]
        general["clearcolor"] = "0 0 0"
        general["clearenabled"] = true
        general["camerafade"] = false
        json["general"] = general
        let document = try parse(json)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let supported = [2, 4, 8].filter { device.supportsTextureSampleCount($0) }
        guard !supported.isEmpty else { throw XCTSkip("Metal device supports none of 2/4/8 MSAA") }
        let base = try WPEParityFramePlan(document: document, assets: assets,
                                          settings: .init(bloom: false), width: 320, height: 180)
        let materialPaths = Set(base.scene.models.values.flatMap(\.meshes).map(\.materialPath))
        XCTAssertFalse(materialPaths.isEmpty)
        var replacements: [String: Data] = [:]
        for path in materialPaths {
            var material = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(assets.data(path))) as? [String: Any])
            var passes = try XCTUnwrap(material["passes"] as? [[String: Any]])
            _ = try XCTUnwrap(passes.first)
            passes[0]["blending"] = "alphatocoverage"
            passes[0]["depthtest"] = "enabled"
            passes[0]["depthwrite"] = "enabled"
            material["passes"] = passes
            replacements[path] = try JSONSerialization.data(withJSONObject: material)
        }
        let materialOverrides = replacements
        let coverageAssets = WPEParityProgramAssets(sources: [.lookup(scratch) { materialOverrides[$0] }] + assets.sources)
        let variants = supported.map { (samples: $0, coverage: false) }
            + [(samples: supported.contains(4) ? 4 : supported[0], coverage: true)]
        for (samples, coverage) in variants {
            let plan = try WPEParityFramePlan(
                document: document, assets: coverage ? coverageAssets : assets,
                settings: .init(bloom: false, msaaSampleCount: samples,
                                colorCorrection: .init(wecE: true, wecBrs: 75)),
                width: 320, height: 180
            )
            XCTAssertEqual(plan.scene.models["112"]?.meshes.count, 1)
            XCTAssertEqual(plan.scene.scene.msaaSamples, samples)
            XCTAssertEqual(plan.post.msaaSampleCount, samples)
            let modelIndices = plan.frames[0].draws.compactMap { index, draw -> Int? in
                guard case let .scene(scene) = draw, scene.geometry == .modelMesh else { return nil }
                return index
            }
            XCTAssertEqual(modelIndices.count, 2)
            if coverage {
                for index in modelIndices {
                    guard case let .scene(draw)? = plan.frames[0].draws[index] else {
                        return XCTFail("Missing actual model draw")
                    }
                    XCTAssertEqual(draw.blend, .alphaToCoverage)
                    XCTAssertTrue(draw.depthTest && draw.depthWrite)
                }
            }
            let post = try postIndex("ccsimple", in: plan)
            let renderer = try await makeRenderer(plan, device: device, queue: queue)
            let color = try XCTUnwrap(renderer.targets[WPEParitySceneResource.multisampled])
            let depth = try XCTUnwrap(renderer.targets[WPEParitySceneResource.multisampledDepth])
            XCTAssertEqual(color.textureType, .type2DMultisample)
            XCTAssertEqual(depth.textureType, .type2DMultisample)
            XCTAssertEqual(color.sampleCount, samples)
            XCTAssertEqual(depth.sampleCount, samples)
            XCTAssertEqual(renderer.backbuffer.sampleCount, 1)
            for index in modelIndices + [post] {
                XCTAssertNil(renderer.skipped[index], "\(renderer.skipped)")
            }
            XCTAssertTrue(plan.frames[0].operations.contains { operation in
                guard case let .resolve(source, destination) = operation.kind else { return false }
                return source == WPEParitySceneResource.multisampled && destination == WPEParitySceneResource.backbuffer
            })
            try await render(renderer)
            let executed = Set(renderer.lastFrameDraws.map(\.operation))
            XCTAssertTrue(Set(modelIndices + [post]).isSubset(of: executed), "real mesh PSOs and post PSO must encode")
            let postDraw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == post }?.draw)
            XCTAssertEqual(postDraw.textures["g_Texture0"]?.sampleCount, 1)
            XCTAssertGreaterThan(renderer.pipelineCreations, 0)
            let pixels = try await present(renderer, device: device, queue: queue)
            let earth = try XCTUnwrap(modelIndices.first { index in
                guard case let .scene(scene)? = plan.frames[0].draws[index] else { return false }
                return scene.objectID == "112"
            })
            let bounds = try XCTUnwrap(plan.scene.models["112"]?.meshes.first?.bounds)
            let mvp = try XCTUnwrap(renderer.uniforms(earth)).matrices.modelViewProjection
            var low = SIMD2<Float>(repeating: .infinity)
            var high = -low
            for corner in 0 ..< 8 {
                let point = SIMD3(corner & 1 == 0 ? bounds.minimum.x : bounds.maximum.x,
                                  corner & 2 == 0 ? bounds.minimum.y : bounds.maximum.y,
                                  corner & 4 == 0 ? bounds.minimum.z : bounds.maximum.z)
                let clip = mvp * SIMD4(point, 1)
                let ndc = SIMD2(clip.x, clip.y) / clip.w
                let pixel = SIMD2((ndc.x + 1) / 2 * 320, (1 - ndc.y) / 2 * 180)
                low = simd_min(low, pixel)
                high = simd_max(high, pixel)
            }
            let size = SIMD2<Float>(320, 180)
            let lower = SIMD2<Int>(simd_clamp(low, .zero, size), rounding: .down)
            let upper = SIMD2<Int>(simd_clamp(high, .zero, size), rounding: .up)
            XCTAssertTrue(lower.x < upper.x && lower.y < upper.y, "Earth must project on screen")
            let lit = (lower.y ..< max(lower.y, upper.y)).reduce(0) { total, row in
                total + (lower.x ..< max(lower.x, upper.x)).count { column in
                    let offset = (row * 320 + column) * 4
                    return pixels[offset ..< offset + 3].contains { $0 > 16 }
                }
            }
            XCTAssertGreaterThan(lit, 0, "Earth must survive MSAA resolve and post inside its projected bounds")
            print("real MDL MSAA sampleCount=\(samples): native targets, mesh/post PSOs, resolve and sRGB present completed")
        }
    }

    private func clearPlan(assets: WPEParityProgramAssets, color: String, hdr: Bool = false,
                           correction: WPEParityColorCorrection = .init()) throws -> WPEParityFramePlan {
        let document = try parse([
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32],
                        "clearcolor": color, "clearenabled": true, "bloom": true, "hdr": hdr],
            "objects": [],
        ])
        return try WPEParityFramePlan(document: document, assets: assets,
                                      settings: .init(bloom: false, hdrPostProcessing: hdr,
                                                      colorCorrection: correction), width: 32, height: 32)
    }

    private func parse(_ json: [String: Any]) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                         makeTransformScriptResolver: { _, _ in NoPostProcessScripts() })
    }

    private func postIndex(_ name: String, in plan: WPEParityFramePlan) throws -> Int {
        try XCTUnwrap(plan.frames[0].draws.first { _, draw in
            if case let .post(post) = draw {
                return post.shader == name
            }
            return false
        }?.key)
    }

    private func engineAssets() throws -> URL {
        let engine = try ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? realHome().appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        for path in ["materials/util/combine_srgb.json", "materials/util/ccsimple.json",
                     "shaders/passthroughsrgb.frag", "shaders/ccsimple.frag"] {
            guard FileManager.default.fileExists(atPath: engine.appendingPathComponent(path).path) else {
                throw XCTSkip("Needs original WPE assets (WPE_ASSETS_DIR), including \(path)")
            }
        }
        return engine
    }

    private func realHome() throws -> URL {
        try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
    }

    private func makeRenderer(_ plan: WPEParityFramePlan, device: MTLDevice,
                              queue: MTLCommandQueue) async throws -> WPEParityFrameRenderer {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER"]
        let urls = keys.compactMap { environment[$0].map { URL(fileURLWithPath: $0) } }
        let compiler: WPEParityHelperShaderCompiler
        if !urls.isEmpty {
            guard urls.count == 3, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw XCTSkip("Supply all three current toolchain paths: \(keys.joined(separator: ", "))")
            }
            compiler = try WPEParityHelperShaderCompiler(helper: urls[0], dxcompiler: urls[1], metalIRConverter: urls[2],
                                                         workDirectory: scratch.appendingPathComponent("shaderc"))
        } else {
            switch WPEParityShaderToolchain.makeCompiler() {
            case let .success(selected): compiler = selected
            case let .failure(error): throw XCTSkip("Needs current bundled helper or explicit toolchain: \(error)")
            }
        }
        print("postprocess product compilerIdentity=\(compiler.compilerIdentity)")
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appendingPathComponent("shader-cache")
        ))
        return try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1)
        )
    }

    private func render(_ renderer: WPEParityFrameRenderer) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 0) else {
            return XCTFail("frame was not committed")
        }
        await commandBuffer.completed()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
    }

    private func present(_ renderer: WPEParityFrameRenderer, device: MTLDevice,
                         queue: MTLCommandQueue) async throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                  width: renderer.backbuffer.width,
                                                                  height: renderer.backbuffer.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let executor = try WPEMetalRenderExecutor(device: device)
        try executor.encodePresentPass(source: renderer.backbuffer, target: target, fitMode: .stretch,
                                       worldSourceSize: nil, uniforms: nil, colorTransfer: renderer.colorTransfer,
                                       into: commandBuffer)
        commandBuffer.commit()
        await commandBuffer.completed()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        return try read(target, bytesPerPixel: 4, device: device, queue: queue)
    }

    /// Row padding belongs to Metal's buffer copy, not to the returned pixel array.
    private func read(_ texture: MTLTexture, bytesPerPixel: Int, device: MTLDevice,
                      queue: MTLCommandQueue) throws -> [UInt8] {
        let row = texture.width * bytesPerPixel
        let stride = (row + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(length: stride * texture.height, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return (0 ..< texture.height).flatMap { Array(UnsafeBufferPointer(start: bytes + $0 * stride, count: row)) }
    }

    private func centerRGBA(_ bgra: [UInt8], width: Int, height: Int) -> [UInt8] {
        let offset = (height / 2 * width + width / 2) * 4
        return [bgra[offset + 2], bgra[offset + 1], bgra[offset], bgra[offset + 3]]
    }

    private func components(_ value: WPECBufferValue?) -> [Float]? {
        switch value {
        case let .float(number)?: [number]
        case let .vector(values)?: values
        default: nil
        }
    }

    /// TEXV5/TEXI1, raw RGBA8, clamp and volume flags. x runs fastest; output RGB is (z,x,y).
    private func rawAxisLUT() -> Data {
        var payload = Data()
        for z in 0 ..< 2 {
            for y in 0 ..< 2 {
                for x in 0 ..< 2 {
                    payload.append(contentsOf: [UInt8(z * 255), UInt8(x * 255), UInt8(y * 255), 255])
                }
            }
        }
        var data = Data()
        func magic(_ text: String) {
            data.append(contentsOf: text.utf8); data.append(0)
        }
        func word(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        magic("TEXV0005"); magic("TEXI0001")
        for value in [UInt32(0), 0x42, 2, 2, 2, 2, 2, 0] {
            word(value)
        }
        magic("TEXB0003")
        for value in [UInt32(1), .max, 1, 2, 2, 2, 0, UInt32(payload.count), UInt32(payload.count)] {
            word(value)
        }
        data.append(payload)
        return data
    }
}

private struct NoPostProcessScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
