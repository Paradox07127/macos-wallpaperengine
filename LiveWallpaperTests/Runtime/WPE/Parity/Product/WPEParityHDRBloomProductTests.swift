#if !LITE_BUILD && DEBUG
import CryptoKit
import Darwin
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// Real original util programs and production frame/present encoders; arithmetic expectations live separately.
final class WPEParityHDRBloomProductTests: XCTestCase {
    private var scratch: URL!
    private static let floatTolerance = 0.001
    private static let presentTolerance = 2.0

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("parity-hdr-bloom-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testOriginalHDRBloomSoftKneeLowLightAndSaturationPixels() async throws {
        let context = try makeContext()
        for color in [SIMD3<Double>(0.5, 0.25, 0.125), .init(repeating: 0.1), .init(repeating: 0.8)] {
            try await verify(width: 64, height: 64, color: color, gradient: false, context: context)
        }
    }

    func testAuthoredHDRPredicateChoosesActualTextureAndOriginalTerminal() async throws {
        let context = try makeContext()
        let cases: [(String, Any?, Bool, Bool)] = [
            ("literal true", true, true, true),
            ("false envelope overridden true", ["value": false, "user": "on"], true, false),
            ("true envelope overridden false", ["value": true, "user": "on"], false, true),
            ("missing bloom", nil, true, false),
            ("numeric bloom", 1, true, false),
        ]
        for (label, bloom, userValue, expectedHDR) in cases {
            var general: [String: Any] = [
                "orthogonalprojection": ["width": 32, "height": 32], "hdr": true,
                "clearenabled": true, "clearcolor": "0.5 0.5 0.5",
                "camerashake": false, "cameraparallax": false,
            ]
            general["bloom"] = bloom
            let json: [String: Any] = ["camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                                       "general": general, "objects": []]
            let document = try WPESceneDocumentParser.parse(
                data: JSONSerialization.data(withJSONObject: json), userValues: ["on": .bool(userValue)],
                makeTransformScriptResolver: { _, _ in HDRBloomNoScripts() }
            )
            let plan = try WPEParityFramePlan(
                document: document, assets: .init(sceneDirectory: scratch, assetRoots: [context.engine]),
                settings: .init(bloom: false, hdrPostProcessing: true), width: 32, height: 32
            )
            XCTAssertEqual(plan.post.sceneBloomEnabled, label == "true envelope overridden false" ? false : true,
                           "resolved runtime bloom remains independent: \(label)")
            XCTAssertEqual(plan.post.hdrEnabled, expectedHDR, label)
            XCTAssertEqual(plan.requiredPresentationPass, expectedHDR ? "combine_srgb" : nil, label)
            XCTAssertEqual(plan.colorTransfer, expectedHDR ? .linear : .authored, label)
            let renderer = try await WPEParityFrameRenderer(plan: plan, device: context.device, queue: context.queue,
                                                            shaders: context.shaders)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(label): \(renderer.skipped)")
            XCTAssertTrue(renderer.fallbackTextures.isEmpty, label)
            guard case let .committed(command) = try renderer.encodeFrame(elapsed: 0) else {
                return XCTFail("HDR predicate case was not committed: \(label)")
            }
            await command.completed()
            try requireCompleted(command)
            XCTAssertEqual(renderer.backbuffer.pixelFormat, expectedHDR ? .rgba16Float : .rgba8Unorm, label)
            if expectedHDR {
                let terminal = try XCTUnwrap(plan.programs.values.first { $0.shader == "passthroughsrgb" })
                XCTAssertTrue(renderer.lastFrameDraws.contains { plan.programs[$0.operation]?.shader == terminal.shader })
                let expected = WPEParityHDRBloomReference.Image(
                    width: 32, height: 32, storageRounding: context.storageRounding
                ) { _, _ in SIMD3(repeating: 0.21404114048223255) }
                try assertFloatImage(renderer.backbuffer, expected, context: context, label: label,
                                     diagnosticCase: "authored-hdr-predicate")
            } else {
                XCTAssertTrue(renderer.lastFrameDraws.isEmpty, "no HDR terminal may be silently drawn: \(label)")
                let raw = try read(renderer.backbuffer, bytesPerPixel: 4, queue: context.queue)
                XCTAssertEqual(raw.count, 32 * 32 * 4)
                for channel in 0 ..< 3 {
                    XCTAssertLessThanOrEqual(abs(Int(raw[channel]) - 128), 1, label)
                }
            }
            let shown = try await present(renderer, context: context)
            XCTAssertEqual(shown.count, 32 * 32 * 4)
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(shown[channel]) - 128), 2, "terminal display gray: \(label)")
            }
            XCTAssertEqual(shown[3], 255, label)
        }
    }

    func testOriginalHDRBloomOddSizeGradientUsesLogicalOffsetsAndCubicPixels() async throws {
        let context = try makeContext()
        // Pre-GPU sensitivity review: both cubic replacement and physical-size substitution
        // must exceed the fixed float tolerance, including on a taller odd texture.
        // 33x17 reaches a 2x2 native RT at divisor16: a one-pixel height changes the actual sampling grid.
        for (width, height) in [(65, 33), (63, 159), (33, 17)] {
            try await verify(width: width, height: height, color: SIMD3(0.5, 0.49, 0.48), gradient: true,
                             context: context)
        }
    }

    private struct Context {
        let engine: URL
        let device: MTLDevice
        let queue: MTLCommandQueue
        let storageRounding: WPEParityHDRBloomReference.StorageRounding
        let shaders: WPEParityFrameShaderSource
    }

    private func verify(width: Int, height: Int, color: SIMD3<Double>, gradient: Bool,
                        context: Context) async throws {
        let diagnosticCase = "\(width)x\(height)-\(gradient ? "gradient-S2" : "constant-S0.5")"
            + "-\(color.x)-\(color.y)-\(color.z)-storage-\(context.storageRounding.rawValue)"
        let expected = WPEParityHDRBloomReference.evaluate(width: width, height: height, color: color, gradient: gradient,
                                                           storageRounding: context.storageRounding)
        let plan = try makePlan(width: width, height: height, color: color, gradient: gradient, engine: context.engine)
        XCTAssertTrue(plan.post.hdrEnabled && plan.post.bloomEnabled)
        XCTAssertEqual(plan.requiredPresentationPass, "combine_hdr")
        XCTAssertEqual(plan.colorTransfer, .linear)
        XCTAssertEqual(plan.post.msaaSampleCount, 1)
        let post = plan.frames[0].draws.sorted { $0.key < $1.key }.compactMap { index, draw -> (Int, String)? in
            guard case let .post(post) = draw else { return nil }
            return (index, post.shader)
        }
        XCTAssertEqual(post.map(\.1), ["hdr_downsample_bloom", "hdr_downsample", "hdr_downsample", "hdr_downsample",
                                       "hdr_upsample_cubic", "hdr_upsample_cubic", "hdr_upsample", "combine_hdr"])
        guard post.count == 8 else { return XCTFail("The required eight HDR+bloom draws are absent") }
        let renderer = try await WPEParityFrameRenderer(plan: plan, device: context.device, queue: context.queue,
                                                        shaders: context.shaders)
        guard renderer.skipped.isEmpty, renderer.fallbackTextures.isEmpty else {
            return XCTFail("HDR+bloom prerequisites failed: skips=\(renderer.skipped), fallbacks=\(renderer.fallbackTextures)")
        }
        guard case let .committed(command) = try renderer.encodeFrame(elapsed: 0) else {
            return XCTFail("HDR+bloom frame was not committed")
        }
        await command.completed()
        try requireCompleted(command)
        XCTAssertEqual(Set(renderer.lastFrameDraws.map(\.operation)), Set(plan.frames[0].draws.keys))
        func draw(_ position: Int) throws -> WPEParityDraw {
            let operation = try XCTUnwrap(post.indices.contains(position) ? post[position].0 : nil)
            return try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
        }
        func uniform(_ position: Int, _ name: String, _ values: [Float]) throws {
            let actual = try XCTUnwrap(components(draw(position).constants[.fragment]?[name]), name)
            XCTAssertEqual(actual.count, values.count, name)
            for (a, b) in zip(actual, values) {
                XCTAssertEqual(a, b, accuracy: 1e-6, name)
            }
        }
        for position in 0 ..< 7 {
            let program = try XCTUnwrap(plan.programs[post[position].0])
            XCTAssertEqual(program.shader, "hdr_downsample")
            let combos = Dictionary(program.combos.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
            XCTAssertEqual(combos["BLOOM"] == "1", position == 0)
            XCTAssertEqual(combos["UPSAMPLE"] == "1", position >= 4)
            XCTAssertEqual(combos["BICUBIC"] == "1", position == 4 || position == 5)
            let scale = [1, 2, 4, 8, 8, 4, 2][position]
            let x = Float(scale) / Float(width), y = Float(scale) / Float(height)
            try uniform(position, "g_RenderVar0", [x, y, -x, -y])
            if position >= 4 {
                try uniform(position, "g_BloomScatter", [0.5])
            }
        }
        try uniform(0, "g_BloomStrength", [gradient ? 1.6 : 0.4])
        try uniform(0, "g_BloomBlendParams", [0.4, 0.2, 0.4, 0.25 / (0.2 + 1e-5)])
        try uniform(0, "g_BloomTint", [1, 1, 1])
        try uniform(7, "g_RenderVar0", [1, 1, -2 / Float(width), -2 / Float(height)])
        try uniform(7, "g_TexelSize", [1 / Float(width), 1 / Float(height)])
        XCTAssertEqual(plan.programs[post[7].0]?.shader, "combine_hdr")
        let terminal = try draw(7)
        print("HDR+bloom \(diagnosticCase) terminal samplers=\(terminal.samplers)")
        let source = try XCTUnwrap(terminal.textures["g_Texture0"])
        guard try assertFloatImage(source, expected.source, context: context, label: "authored FFB producer",
                                   diagnosticCase: diagnosticCase) else { return }
        var pyramid: [Int: MTLTexture] = try [2: XCTUnwrap(terminal.textures["g_Texture1"])]
        for (position, divisor) in [(4, 16), (5, 8), (6, 4)] {
            pyramid[divisor] = try XCTUnwrap(draw(position).textures["g_Texture0"])
        }
        // Every pyramid value is live across its downsample-to-additive interval;
        // read their actual bound textures after this frame, before submitting another.
        XCTAssertEqual(Set(pyramid.values.map(ObjectIdentifier.init)).count, 4)
        let live = pyramid.sorted { $0.key < $1.key }.map(\.value)
        for (index, texture) in live.enumerated() {
            XCTAssertGreaterThan(texture.allocatedSize, 0)
            print("HDR+bloom RT \(texture.width)x\(texture.height) heapOffset=\(texture.heapOffset) allocated=\(texture.allocatedSize)")
            for other in live.prefix(index) {
                guard let heap = texture.heap, let otherHeap = other.heap,
                      ObjectIdentifier(heap) == ObjectIdentifier(otherHeap) else { continue }
                XCTAssertEqual(heap.type, .placement, "Opaque heap offsets cannot prove safe intermediate readback")
                let overlaps = texture.heapOffset < other.heapOffset + other.allocatedSize
                    && other.heapOffset < texture.heapOffset + texture.allocatedSize
                XCTAssertFalse(overlaps, "Pyramid lifetimes overlap until their additive destinations are consumed")
            }
        }
        for level in 0 ..< 4 {
            let divisor = 1 << (level + 1)
            try assertFloatImage(XCTUnwrap(pyramid[divisor]), expected.pyramid[level], context: context,
                                 label: "final _rt\(divisor)", diagnosticCase: diagnosticCase)
        }
        try assertFloatImage(renderer.backbuffer, expected.linear, context: context, label: "linear combine_hdr",
                             diagnosticCase: diagnosticCase)
        let presented = try await present(renderer, context: context)
        guard presented.count == expected.linear.pixels.count * 4 else { return XCTFail("Invalid present readback length") }
        var worst = 0.0, worstPixel = 0, worstChannel = 0
        for (pixel, rgb) in expected.linear.pixels.enumerated() {
            for channel in 0 ..< 3 {
                let actual = Double(presented[pixel * 4 + [2, 1, 0][channel]])
                let difference = abs(actual - WPEParityHDRBloomReference.sRGBByte(rgb[channel]))
                if difference > worst {
                    (worst, worstPixel, worstChannel) = (difference, pixel, channel)
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, Self.presentTolerance,
                                 "sRGB present worst=(\(worstPixel % width),\(worstPixel / width)), channel=\(worstChannel)")
        XCTAssertTrue(stride(from: 3, to: presented.count, by: 4).allSatisfy { presented[$0] == 255 })
        print("HDR+bloom \(width)x\(height), gradient=\(gradient), color=\(color): original pyramid, linear and present checked")
    }

    private func makePlan(width: Int, height: Int, color: SIMD3<Double>, gradient: Bool, engine: URL) throws
        -> WPEParityFramePlan {
        let rgb = gradient ? """
        g_Color4.rgb * vec3(1.0,
            0.2 * v_TexCoord.x + 0.8 * step(0.37, v_TexCoord.x),
            0.2 * v_TexCoord.y + 0.8 * step(0.61, v_TexCoord.y))
        """ : "g_Color4.rgb"
        let fragment = """
        uniform vec4 g_Color4;
        varying vec2 v_TexCoord;
        void main() {
            gl_FragColor = vec4(\(rgb), 1.0);
        }
        """
        let files: [String: Data] = try [
            "models/bloom-input.json": Data(#"{"material":"materials/bloom-input.json"}"#.utf8),
            "materials/bloom-input.json": Data(#"{"passes":[{"shader":"bloom-input","combos":{"TRANSFORM":1},"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]}"#.utf8),
            "shaders/bloom-input.vert": Data(contentsOf: engine.appendingPathComponent("shaders/passthrough.vert")),
            "shaders/bloom-input.frag": Data(fragment.utf8),
        ]
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }, .directory(engine)])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": width, "height": height],
                        "clearcolor": "0 0 0", "clearenabled": true, "bloom": true, "hdr": true, "camerafade": false,
                        "bloomhdriterations": 4, "bloomhdrstrength": gradient ? 2.0 : 0.5, "bloomhdrthreshold": 0.4,
                        "bloomhdrfeather": 0.5, "bloomhdrscatter": 0.5, "bloomtint": "1 1 1"],
            "objects": [["id": 1, "image": "models/bloom-input.json", "size": "\(width) \(height)",
                         "origin": "\(Double(width) / 2) \(Double(height) / 2) 0",
                         "color": "\(color.x) \(color.y) \(color.z)", "alpha": 1, "brightness": 1]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in HDRBloomNoScripts() })
        return try WPEParityFramePlan(document: document, assets: assets,
                                      settings: .init(bloom: true, hdrPostProcessing: true), width: width, height: height)
    }

    private func makeContext() throws -> Context {
        let environment = ProcessInfo.processInfo.environment
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        // These originals match the preserved Windows engine-resource manifest, not a generated shader oracle.
        for (path, expected) in [
            ("materials/util/hdr_downsample_bloom.json", "1aee61c3e2bc1f641a07ddc4cbfb52dafa22ffcec31afd4a2d182fbf2d3397a5"),
            ("materials/util/hdr_downsample.json", "3e453dfe06db50adaf07a7c2ca4b273bb5144088147076b71aa4b035f8b281fc"),
            ("materials/util/hdr_upsample_cubic.json", "70e6751ef097672998991213b9715182b9e4734119a3c9c742b73f42bb0603bd"),
            ("materials/util/hdr_upsample.json", "05d5ab7aa51b0b006ec69d80c5e668d977ad8fb6ea6c782c2997626635f03d12"),
            ("materials/util/combine_hdr_upsample.json", "844d885484c09908882065d7663b8d39c415e194c638bc0ea7ff706c14549ce1"),
            ("materials/util/combine_srgb.json", "e6a64f1790250830837e8a0960d698c5890d2be54b062eaf3df06cdff163b99a"),
            ("shaders/hdr_downsample.vert", "8a1ffaa2cbf79f3be3faa3e1aac5670d66711ec656cfdb1d5a89d8b6614e80b0"),
            ("shaders/hdr_downsample.frag", "f702cc282d08b6c618646ee78305991139185e626e454ab8a2e40600bb41c874"),
            ("shaders/combine_hdr.vert", "25d48e4e45c8f2092e87d1a29eb2aeb62e5592e1581a6efc15dd06e9790f53cd"),
            ("shaders/combine_hdr.frag", "755db6efba18303898c9a7fb2cb892f57fcddd11888d840e1be826d535ed83f2"),
            ("shaders/passthroughsrgb.vert", "25d48e4e45c8f2092e87d1a29eb2aeb62e5592e1581a6efc15dd06e9790f53cd"),
            ("shaders/passthroughsrgb.frag", "2f2e05eb25ad355bdf15b65de27950d5231e7cc31ede8bd82f0589623c712ee0"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("shaders/common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
            ("shaders/common_fog.h", "a10116adc59b2232e24e06f9c01079393901c45cf47d45ecd17baa2583146201"),
            ("shaders/common_pbr_2.h", "c6c7cc0a57e8621c00b940aaacdcfffa7eaf7d2b84af6a8feb4a9ed597772634"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
        ] {
            let bytes = try Data(contentsOf: engine.appendingPathComponent(path))
            let actual = digest(bytes)
            _ = try XCTUnwrap(actual == expected ? true : nil,
                              "Required original \(path): expected SHA \(expected), actual \(actual)")
            print("HDR+bloom source \(path) SHA256=\(actual)")
        }
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER",
                    "TEST_RUNNER_WPE_SHADERC", "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        _ = try XCTUnwrap(keys.allSatisfy { environment[$0] == nil } ? true : nil,
                          "This product guard requires the current app bundle compiler")
        let contents = Bundle.main.bundleURL.appending(path: "Contents").standardizedFileURL.resolvingSymlinksInPath()
        let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
            return try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? url : nil,
                                 "Compiler escaped current bundle: \(path)")
        }
        let identity = try "wpe-shaderc " + tools.map { try digest(Data(contentsOf: $0)) }.joined(separator: " ")
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1],
                                                         metalIRConverter: tools[2],
                                                         workDirectory: scratch.appendingPathComponent("shaderc"))
        _ = try XCTUnwrap(compiler.compilerIdentity == identity ? compiler : nil,
                          "Actual current app bundle compiler byte identity")
        print("HDR+bloom compilerOrigin=current-app-bundle compilerIdentity=\(compiler.compilerIdentity)")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let storageRounding = try calibrateStorageRounding(device: device, queue: queue)
        let store = WPEParityShaderStore(compiler: compiler,
                                         diskCache: .init(cachesURL: scratch.appendingPathComponent("cache")))
        return Context(engine: engine, device: device, queue: queue, storageRounding: storageRounding,
                       shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1))
    }

    /// Constant float32 output isolates native attachment narrowing from WPE programs and texture filtering.
    private func calibrateStorageRounding(device: MTLDevice, queue: MTLCommandQueue) throws
        -> WPEParityHDRBloomReference.StorageRounding {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 hdr_storage_vertex(uint id [[vertex_id]]) {
            constexpr float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            return float4(positions[id], 0, 1);
        }
        fragment float4 hdr_storage_fragment(constant float4& value [[buffer(0)]]) { return value; }
        """, options: nil)
        var values = SIMD4<Float>(0.3, -0.3, 0.4301, 0.9999)
        func render(_ format: MTLPixelFormat, bytesPerPixel: Int) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1,
                                                                      mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = .renderTarget
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let pipeline = MTLRenderPipelineDescriptor()
            pipeline.vertexFunction = try XCTUnwrap(library.makeFunction(name: "hdr_storage_vertex"))
            pipeline.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "hdr_storage_fragment"))
            pipeline.colorAttachments[0].pixelFormat = format
            pipeline.colorAttachments[0].isBlendingEnabled = false
            let state = try device.makeRenderPipelineState(descriptor: pipeline)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            try requireCompleted(command)
            return try read(texture, bytesPerPixel: bytesPerPixel, queue: queue)
        }
        let full = try render(.rgba32Float, bytesPerPixel: 16)
        let narrowed = try render(.rgba16Float, bytesPerPixel: 8)
        let baseline = (0 ..< 4).map { channel in
            full.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: channel * 4, as: Float.self) }
        }
        _ = try XCTUnwrap((0 ..< 4).allSatisfy { baseline[$0] == values[$0] } ? true : nil,
                          "Native float32 calibration did not preserve its independent constant input")
        let bits = (0 ..< 4).map { channel in
            UInt16(narrowed[channel * 2]) | UInt16(narrowed[channel * 2 + 1]) << 8
        }
        let candidates = WPEParityHDRBloomReference.StorageRounding.allCases.filter { policy in
            (0 ..< 4).allSatisfy { Double(Float16(bitPattern: bits[$0])) == policy.store(Double(baseline[$0])) }
        }
        let selected = try XCTUnwrap(candidates.count == 1 ? candidates.first : nil,
                                     "Unknown/mixed native attachment rounding: float32=\(baseline), halfBits=\(bits)")
        print("HDR+bloom native attachment calibration device=\(device.name), policy=\(selected.rawValue), "
            + "float32=\(baseline), halfBits=\(bits)")
        return selected
    }

    @discardableResult
    private func assertFloatImage(_ texture: MTLTexture, _ expected: WPEParityHDRBloomReference.Image,
                                  context: Context, label: String, diagnosticCase: String) throws -> Bool {
        XCTAssertEqual(texture.width, expected.width, label)
        XCTAssertEqual(texture.height, expected.height, label)
        XCTAssertEqual(texture.pixelFormat, .rgba16Float, label)
        XCTAssertEqual(texture.sampleCount, 1, label)
        let bytes = try read(texture, bytesPerPixel: 8, queue: context.queue)
        guard bytes.count == expected.pixels.count * 8 else {
            XCTFail("\(label): invalid readback length")
            return false
        }
        // Diagnostic observations stay outside the independent expected-value path.
        // Root may retain these tightly packed, little-endian RGBA16F rows for offline analysis.
        if let directory = ProcessInfo.processInfo.environment["WPE_HDR_BLOOM_DIAGNOSTICS_DIR"], !directory.isEmpty {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("\(diagnosticCase)-\(label.replacingOccurrences(of: " ", with: "-"))")
            try Data(bytes).write(to: file.appendingPathExtension("rgba16f"), options: .atomic)
            let metadata: [String: Any] = ["case": diagnosticCase, "label": label,
                                           "width": texture.width, "height": texture.height,
                                           "rowBytes": texture.width * 8, "format": "rgba16Float",
                                           "byteOrder": "little", "sampleCount": texture.sampleCount]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                .write(to: file.appendingPathExtension("json"), options: .atomic)
        }
        var worst = 0.0, worstPixel = 0, worstChannel = 0, opaque = true
        for (pixel, rgb) in expected.pixels.enumerated() {
            for channel in 0 ..< 4 {
                let offset = pixel * 8 + channel * 2
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let actual = Double(Float16(bitPattern: bits))
                if channel == 3 {
                    opaque = opaque && actual == 1
                }
                let wanted = channel == 3 ? 1 : rgb[channel]
                let difference = actual.isFinite ? abs(actual - wanted) : .infinity
                if difference > worst {
                    (worst, worstPixel, worstChannel) = (difference, pixel, channel)
                }
            }
        }
        let offset = worstPixel * 8 + worstChannel * 2
        let actualBits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        let actual = Double(Float16(bitPattern: actualBits))
        let wanted = worstChannel == 3 ? 1 : expected.pixels[worstPixel][worstChannel]
        let wantedBits = Float16(wanted).bitPattern
        let detail = "\(diagnosticCase) \(label): worst=(\(worstPixel % expected.width),\(worstPixel / expected.width)), "
            + "channel=\(worstChannel), actual=\(actual), wanted=\(wanted), signedDelta=\(actual - wanted), "
            + "bits=0x\(String(actualBits, radix: 16))/0x\(String(wantedBits, radix: 16)), "
            + "bitDistance=\(abs(Int(actualBits) - Int(wantedBits))), maxAbs=\(worst)"
        print("HDR+bloom observation \(detail)")
        XCTAssertLessThanOrEqual(worst, Self.floatTolerance,
                                 detail)
        XCTAssertTrue(opaque, "\(label): alpha must remain exactly one")
        return texture.width == expected.width && texture.height == expected.height
            && texture.pixelFormat == .rgba16Float && texture.sampleCount == 1
            && opaque && worst <= Self.floatTolerance
    }

    private func present(_ renderer: WPEParityFrameRenderer, context: Context) async throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                  width: renderer.backbuffer.width,
                                                                  height: renderer.backbuffer.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(context.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(context.queue.makeCommandBuffer())
        let executor = try WPEMetalRenderExecutor(device: context.device)
        try executor.encodePresentPass(source: renderer.backbuffer, target: target, fitMode: .stretch,
                                       worldSourceSize: nil, uniforms: nil, colorTransfer: renderer.colorTransfer, into: command)
        command.commit()
        await command.completed()
        try requireCompleted(command)
        return try read(target, bytesPerPixel: 4, queue: context.queue)
    }

    private func read(_ texture: MTLTexture, bytesPerPixel: Int, queue: MTLCommandQueue) throws -> [UInt8] {
        let row = texture.width * bytesPerPixel, stride = (row + 255) & ~255
        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: stride * texture.height, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try requireCompleted(command)
        let base = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return (0 ..< texture.height).flatMap { Array(UnsafeBufferPointer(start: base + $0 * stride, count: row)) }
    }

    private func requireCompleted(_ command: MTLCommandBuffer) throws {
        _ = try XCTUnwrap(command.status == .completed && command.error == nil ? true : nil,
                          "GPU command failed: status=\(command.status.rawValue), error=\(String(describing: command.error))")
    }

    private func components(_ value: WPECBufferValue?) -> [Float]? {
        switch value {
        case let .float(number)?: [number]
        case let .vector(numbers)?: numbers
        default: nil
        }
    }
}

private struct HDRBloomNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue], seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
