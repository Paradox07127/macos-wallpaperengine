#if !LITE_BUILD && DEBUG
import CryptoKit
import Darwin
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
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

    /// General descriptor -> authored timeline -> bloom invalidation -> original four-pass LDR bloom -> present.
    func testRegisteredGeneralAnimationUpdatesOriginalBloomAndPresentedPixels() async throws {
        let engine: URL
        do {
            engine = try engineAssets()
        } catch {
            throw NSError(domain: "S06.RequiredBloomInputs", code: 1)
        }
        for (path, expected) in [
            ("materials/util/downsample_quarter_bloom.json", "bc240ebf7d1c74e7280d9c9101a274a0281f1bf65ab6c229c093b01827afd4a0"),
            ("shaders/downsample_quarter_bloom.vert", "024d1f44853a78087aeed4c402d1f3b69549eaaf26c48d71baf551b91332802d"),
            ("shaders/downsample_quarter_bloom.frag", "c0b118ac84ea53bfa244596b0844c7dd286f00abe95aae8578a0d129a03ceb19"),
            ("materials/util/downsample_eighth_blur_v.json", "b303a8f31240dbd9c1355faaa98ebb7e1bacd9762b84f430ad25c7fef1f76940"),
            ("shaders/downsample_eighth_blur_v.vert", "0b15d66239b4caec801de17349d3975bc76a277a7f3d123e28983190ea7c2d84"),
            ("shaders/downsample_eighth_blur_v.frag", "703e2837db811b4a1366813225eace1499f01d7be933308e8e3d7e62f39086eb"),
            ("materials/util/blur_h_bloom.json", "f55d402c333d792c53aa7ec4e61e8c3df79331da9a1c231f0c3a0ae5b0d73e32"),
            ("shaders/blur_h_bloom.vert", "33072940f29ccd8f3b9b5dbc8708cff23d3a041d3f35119fbeb9662543840e24"),
            ("shaders/blur_h_bloom.frag", "703e2837db811b4a1366813225eace1499f01d7be933308e8e3d7e62f39086eb"),
            ("materials/util/combine_ldr.json", "71b211e2501b6c6d815d8509a49b98baa97aa9397db2193d57a3378807692b4b"),
            ("shaders/combine.vert", "25d48e4e45c8f2092e87d1a29eb2aeb62e5592e1581a6efc15dd06e9790f53cd"),
            ("shaders/combine.frag", "94fdbeb77d365f330e538db4493b0b8374b48d2d95fd460f6dc34036d6868ddf"),
        ] {
            let bytes = try Data(contentsOf: engine.appendingPathComponent(path))
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            _ = try XCTUnwrap(hash == expected ? true : nil, "pinned original input \(path): \(hash)")
        }
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "TEST_RUNNER_WPE_SHADERC",
                    "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        guard keys.allSatisfy({ ProcessInfo.processInfo.environment[$0] == nil }) else {
            throw NSError(domain: "S06.BloomToolOverride", code: 1)
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
            .map { path in
                let url = contents.appending(path: path).resolvingSymlinksInPath()
                return try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? url : nil)
            }
        let hashes = try tools.map { url in
            try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1], metalIRConverter: tools[2],
                                                         workDirectory: scratch.appending(path: "scene-animation-shaderc"))
        _ = try XCTUnwrap(compiler.compilerIdentity == "wpe-shaderc " + hashes.joined(separator: " ") ? true : nil)
        print("S06 general animation toolchain origin=app-bundle compilerIdentity=\(compiler.compilerIdentity)")
        let document = try parse([
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32], "clearcolor": "0.5 0.5 0.5",
                        "clearenabled": true, "bloom": true, "hdr": false, "camerafade": false, "bloomthreshold": 0,
                        "bloomstrength": ["value": 0, "animation": [
                            "c0": [["frame": 0, "value": 0], ["frame": 3, "value": 0],
                                   ["frame": 4, "value": 1], ["frame": 7, "value": 1],
                                   ["frame": 8, "value": 0], ["frame": 11, "value": 0]],
                            "options": ["fps": 4, "length": 12],
                        ]]],
            // Native bloom requires a nonempty object table. A camera is a real object with no color draw.
            "objects": [["id": 1, "camera": "bloom witness", "origin": "0 0 0", "angles": "0 0 0"]],
        ])
        let plan = try WPEParityFramePlan(document: document,
                                          assets: .init(sceneDirectory: scratch, assetRoots: [engine]),
                                          settings: .init(bloom: true, hdrPostProcessing: false), width: 32, height: 32)
        let operation = try postIndex("downsample_quarter_bloom", in: plan)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let store = WPEParityShaderStore(compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "cache")))
        let renderer = try await WPEParityFrameRenderer(plan: plan, device: device, queue: queue,
                                                        shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity,
                                                                       bindingABIVersion: 1))
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        let unchanged = try XCTUnwrap(WPEParityUserPropertyUpdate(from: document, to: document))
        for (strength, expected, advances): (Float, Int, Int) in [(0, 128, 1), (1, 192, 4), (0, 128, 4)] {
            for _ in 0 ..< (advances - 1) {
                guard case let .committed(command) = try renderer.encodeFrame(elapsed: 0.25) else {
                    return XCTFail("authored plateau warmup was not committed")
                }
                await command.completed()
                XCTAssertNil(command.error)
            }
            for elapsed in [0.25, 0.0] {
                let generation = renderer.state.generation(.bloom)
                if elapsed == 0 {
                    try renderer.applyUserProperties(unchanged)
                }
                guard case let .committed(command) = try renderer.encodeFrame(elapsed: elapsed) else {
                    return XCTFail("authored general animation frame was not committed")
                }
                await command.completed()
                XCTAssertNil(command.error)
                if elapsed == 0 {
                    // Clock clamps to a positive minimum step. Sample inside a plateau so it cannot re-dirty
                    // the unchanged field and mask a document snapshot restoring the authored strength.
                    XCTAssertEqual(renderer.state.generation(.bloom), generation)
                }
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
                guard case let .vector(canonical)? = renderer.state.scriptField("bloomstrength", of: "") else {
                    return XCTFail("Animated strength must be present in canonical State")
                }
                // The existing sampler may round the authored plateau by one ULP; this guard qualifies the
                // consumer, whose encoded value must preserve the canonical Float's exact bits.
                XCTAssertEqual(canonical.x, strength, accuracy: Float.ulpOfOne)
                XCTAssertEqual(components(draw.constants[.fragment]?["g_BloomStrength"])?.map(\.bitPattern),
                               [canonical.x.bitPattern])
                let pixels = try await present(renderer, device: device, queue: queue)
                let pixel = centerRGBA(pixels, width: 32, height: 32)
                // Original bloom source: constant 128/255 squared, then contrast/saturation -> byte64;
                // the two normalized blurs preserve it and combine adds 128+64. Zero strength removes it.
                for channel in pixel.prefix(3) {
                    XCTAssertLessThanOrEqual(abs(Int(channel) - expected), 1)
                }
            }
        }
    }

    /// Strict native seeds and live HDR fields reach the original shader without replacing prepared resources.
    func testHDRBloomFloatFieldsReachOriginalDrawsAndPreserveLiveValuesAcrossDocumentUpdates() async throws {
        let engine = try engineAssets()
        let assets = WPEParityProgramAssets(sceneDirectory: scratch, assetRoots: [engine])
        let fields = ["bloomhdrstrength", "bloomhdrthreshold", "bloomhdrfeather", "bloomhdrscatter"]
        let source: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32],
                        "clearcolor": "0.5 0.5 0.5", "clearenabled": true,
                        "bloom": true, "hdr": true, "camerafade": false,
                        "bloomhdrstrength": ["value": false, "user": fields[0], "script": """
                        shared.hdrLoads = (shared.hdrLoads || 0) + 1;
                        export function update(value) {
                          if (shared.hdrLoads !== 1) throw new Error('HDR module rerun');
                          if (!engine.userProperties.animate) return value;
                          thisScene.bloomhdrthreshold = engine.userProperties.threshold;
                          thisScene.bloomhdrfeather = engine.userProperties.feather;
                          thisScene.bloomhdrscatter = engine.userProperties.scatter;
                          return engine.userProperties.strength;
                        }
                        """],
                        "bloomhdrthreshold": ["value": "0.05", "user": fields[1]],
                        "bloomhdrfeather": ["value": ["value": 0.2], "user": fields[2],
                                            "script": "export function update(value) { return value; }"],
                        "bloomhdrscatter": ["value": [1.25], "user": fields[3]]],
            "objects": [["id": 1, "camera": "HDR witness", "origin": "0 0 0", "angles": "0 0 0",
                         "alpha": ["value": 1, "user": "fade"]]],
        ]
        func document(_ users: [String: WallpaperEngineProjectPropertyValue] = [:]) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source), userValues: users,
                                             makeTransformScriptResolver: { _, _ in NoPostProcessScripts() })
        }
        func host(_ animate: Bool) throws -> String {
            let values: [String: Any] = ["animate": ["type": "bool", "value": animate],
                                         "strength": ["type": "slider", "value": 1],
                                         "threshold": ["type": "slider", "value": 0.05],
                                         "feather": ["type": "slider", "value": 0.2],
                                         "scatter": ["type": "slider", "value": 1.25]]
            return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8))
        }
        let initial = try document()
        for field in fields {
            XCTAssertNil(WPEParityScriptProperty.bloomFloatValue(fromJSON: initial.resolvedGeneralJSON[field]),
                         "This fixture must reach the typed reader with an invalid seed after envelope resolution")
        }
        let plan = try WPEParityFramePlan(document: initial, assets: assets,
                                          settings: .init(bloom: true, hdrPostProcessing: true), width: 32, height: 32)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(plan, device: device, queue: queue)
        let script = try WPEParitySceneScript(document: initial, state: renderer.state, assets: assets,
                                              canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32),
                                              materialConstants: plan.materialConstants,
                                              host: .init(userPropertiesJSON: host(false)))
        try renderer.attachScript(script)
        let defaultValues = [Float(2), 1, 0.1, 1.619]
        for (field, value) in zip(fields, defaultValues) {
            XCTAssertEqual(renderer.state.scriptField(field, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        let validUsers = Dictionary(uniqueKeysWithValues: zip(fields, [0.0, 0.3, 0.4, 2.0]).map { ($0, WallpaperEngineProjectPropertyValue.number($1)) })
        let faded = try document(["fade": .number(0.25)])
        let changed = try document(validUsers)
        let invalid = try document(Dictionary(uniqueKeysWithValues: fields.map { ($0, WallpaperEngineProjectPropertyValue.bool(false)) }))
        let unchanged = try XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: initial))
        let steps: [(WPEParityUserPropertyUpdate, Bool, [Float])] = try [
            (unchanged, false, defaultValues), (unchanged, true, [1, 0.05, 0.2, 1.25]),
            (XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: faded)), false, [1, 0.05, 0.2, 1.25]),
            (XCTUnwrap(WPEParityUserPropertyUpdate(from: faded, to: changed)), false, [0, 0.3, 0.4, 2]),
            (XCTUnwrap(WPEParityUserPropertyUpdate(from: changed, to: invalid)), false, [0, 0.3, 0.4, 2]),
        ]
        let backbuffer = renderer.backbuffer
        let executors = renderer.graphExecutorIdentities
        let targets = renderer.targets.mapValues(ObjectIdentifier.init)
        var firstPipelines: [Int: ObjectIdentifier] = [:]
        var positivePixels: [UInt8] = []
        for (step, entry) in steps.enumerated() {
            let (update, animate, values) = entry
            try renderer.applyUserProperties(update, changedJSON: host(animate), mergedJSON: host(animate))
            try await render(renderer)
            let down = try XCTUnwrap(renderer.lastFrameDraws.first { entry in
                if case let .post(post)? = renderer.frames[0].draws[entry.operation] {
                    return post.shader == "hdr_downsample_bloom"
                }
                return false
            }?.draw)
            let (threshold, feather, scatter) = (values[1], values[2], values[3])
            let strength = values[0] / (pow(scatter, Float(max(plan.post.hdrBloomLevelCount, 2) - 2)) + 1)
            XCTAssertEqual(components(down.constants[.fragment]?["g_BloomStrength"]), [strength])
            XCTAssertEqual(components(down.constants[.fragment]?["g_BloomBlendParams"]),
                           [threshold, threshold - threshold * feather, 2 * threshold * feather, 0.25 / (threshold * feather + 1e-5)])
            let up = renderer.lastFrameDraws.filter { entry in
                guard case let .post(post)? = renderer.frames[0].draws[entry.operation] else { return false }
                return post.shader == "hdr_upsample" || post.shader == "hdr_upsample_cubic"
            }
            XCTAssertEqual(up.count, plan.post.hdrBloomLevelCount - 1)
            for entry in up {
                XCTAssertEqual(components(entry.draw.constants[.fragment]?["g_BloomScatter"]), [scatter])
            }
            for (field, value) in zip(fields, values) {
                XCTAssertEqual(renderer.state.scriptField(field, of: ""), .vector(SIMD4(value, 0, 0, 0)))
            }
            let pixels = try await present(renderer, device: device, queue: queue)
            if step == 1 {
                positivePixels = pixels
                XCTAssertTrue(pixels.prefix(3).allSatisfy { $0 > 130 })
            } else if step == 2 {
                XCTAssertEqual(pixels, positivePixels, "Unrelated hot change must preserve script HDR values")
            } else {
                XCTAssertTrue(pixels.prefix(3).allSatisfy { abs(Int($0) - 128) <= 2 })
            }
            let pipelines = Dictionary(uniqueKeysWithValues: renderer.lastFrameDraws.map { ($0.operation, ObjectIdentifier($0.draw.pipeline.state)) })
            if step == 0 {
                firstPipelines = pipelines
            }
            XCTAssertEqual(pipelines, firstPipelines)
            XCTAssertTrue(renderer.backbuffer === backbuffer)
            XCTAssertEqual(renderer.graphExecutorIdentities, executors)
            XCTAssertEqual(renderer.targets.mapValues(ObjectIdentifier.init), targets)
            XCTAssertTrue(renderer.skipped.isEmpty)
        }
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    /// Typed live writes select active N while the original tint shaders reuse the prepared HDR capacity.
    func testBloomTintAndIterationsReachOriginalMetalPassesPixelsAndPreparedCapacity() async throws {
        let engine: URL
        do { engine = try engineAssets() } catch { throw NSError(domain: "Bloom.RequiredOriginalInputs", code: 1) }
        let overrideKeys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER",
                            "TEST_RUNNER_WPE_SHADERC", "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        guard overrideKeys.allSatisfy({ ProcessInfo.processInfo.environment[$0] == nil }) else {
            throw NSError(domain: "Bloom.ToolOverride", code: 1)
        }
        let assets = WPEParityProgramAssets(sceneDirectory: scratch, assetRoots: [engine])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func document(hdr: Bool, iterations: Any = 2, tint: Any = "1 0 0", visible: Bool = true,
                      scripts: Bool = true, bloom: Bool = true) throws -> WPESceneDocument {
            var general: [String: Any] = [
                "orthogonalprojection": ["width": 32, "height": 32], "clearcolor": "0.5 0.5 0.5",
                "clearenabled": true, "bloom": ["value": true, "user": "toggle"], "hdr": hdr, "camerafade": false,
                "bloomstrength": 1, "bloomthreshold": 0, "bloomhdrstrength": 2,
                "bloomhdrthreshold": 0, "bloomhdrfeather": 0.1, "bloomhdrscatter": 1.25,
                "bloomhdriterations": iterations, "bloomtint": tint,
            ]
            if scripts {
                general["bloomhdriterations"] = ["value": iterations, "script": """
                shared.iterationLoads = (shared.iterationLoads || 0) + 1;
                export function update(value) {
                  if (shared.iterationLoads !== 1) throw new Error('module rerun');
                  if (!engine.userProperties.drive) return value;
                  thisScene.bloomtint = new Vec3(engine.userProperties.red, 0, engine.userProperties.blue);
                  return engine.userProperties.iterations;
                }
                """]
                general["bloomtint"] = ["value": tint, "script": "export function update(value) { return value; }"]
            }
            let source: [String: Any] = [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"], "general": general,
                "objects": [["id": 1, "camera": "capacity witness", "origin": "0 0 0", "angles": "0 0 0", "visible": visible]],
            ]
            let data = try JSONSerialization.data(withJSONObject: source)
            if let number = iterations as? Double, number == 1e100 {
                let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
                XCTAssertNotNil(raw.range(of: #""bloomhdriterations":1[eE]\+?100"#, options: .regularExpression),
                                "The overflow witness must actually be serialized as a real exponent token")
            }
            return try WPESceneDocumentParser.parse(data: data,
                                                    userValues: ["toggle": .bool(bloom)],
                                                    makeTransformScriptResolver: { _, _ in NoPostProcessScripts() })
        }
        func host(drive: Bool, iterations: Int = 2, blue: Bool = false) -> String {
            "{\"drive\":{\"type\":\"bool\",\"value\":\(drive)},\"iterations\":{\"type\":\"slider\",\"value\":\(iterations)},\"red\":{\"type\":\"slider\",\"value\":\(blue ? 0 : 1)},\"blue\":{\"type\":\"slider\",\"value\":\(blue ? 1 : 0)}}"
        }
        for hdr in [false, true] {
            let initial = try document(hdr: hdr)
            let plan = try WPEParityFramePlan(document: initial, assets: assets,
                                              settings: .init(bloom: true, hdrPostProcessing: hdr), width: 32, height: 32)
            let renderer = try await makeRenderer(plan, device: device, queue: queue)
            let script = try WPEParitySceneScript(document: initial, state: renderer.state, assets: assets,
                                                  canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32),
                                                  materialConstants: plan.materialConstants,
                                                  host: .init(userPropertiesJSON: host(drive: false)))
            try renderer.attachScript(script)
            let backbuffer = renderer.backbuffer
            let capacityIDs = (1 ... plan.post.hdrBloomCapacity).map { WPEResourceID("_rt_\(1 << $0)FrameBuffer") }
            let capacity = try hdr ? Dictionary(uniqueKeysWithValues: capacityIDs.map { id in
                let texture = try XCTUnwrap(renderer.targets[id], "Every capacity target must exist before the first frame")
                XCTAssertEqual(texture.pixelFormat, .rgba16Float)
                return (id, ObjectIdentifier(texture))
            }) : [:]
            if hdr {
                for level in 1 ... plan.post.hdrBloomCapacity {
                    let target = try XCTUnwrap(renderer.targets[capacityIDs[level - 1]])
                    XCTAssertEqual(target.width, max(2, 32 / (1 << level)))
                    XCTAssertEqual(target.height, target.width)
                }
            }
            let pipelines = renderer.pipelineCreations
            func check(_ raw: Int32, _ tint: SIMD3<Float>) async throws -> [UInt8] {
                try await render(renderer)
                XCTAssertEqual(renderer.state.scriptField("bloomhdriterations", of: ""), .integer(raw))
                XCTAssertEqual(renderer.state.scriptField("bloomtint", of: ""), .vector(SIMD4(tint, 0)))
                let post = renderer.lastFrameDraws.compactMap { entry -> (WPEParityPostProcessDraw, WPEParityDraw)? in
                    guard case let .post(draw)? = renderer.frames[0].draws[entry.operation] else { return nil }
                    return (draw, entry.draw)
                }
                let bloomName = hdr ? "hdr_downsample_bloom" : "downsample_quarter_bloom"
                let down = try XCTUnwrap(post.first { $0.0.shader == bloomName }?.1)
                XCTAssertEqual(components(down.constants[.fragment]?["g_BloomTint"])?.map(\.bitPattern),
                               [tint.x, tint.y, tint.z].map(\.bitPattern))
                if hdr {
                    let n = max(1, min(Int(raw), plan.post.hdrBloomCapacity))
                    let expected = ["hdr_downsample_bloom"] + Array(repeating: "hdr_downsample", count: n - 1)
                        + stride(from: n - 1, through: 1, by: -1).map { $0 >= n - 2 ? "hdr_upsample_cubic" : "hdr_upsample" }
                    XCTAssertEqual(post.map(\.0.shader).filter { $0.hasPrefix("hdr_") }, expected)
                    let strength: Float = 2 / (pow(1.25, Float(max(n, 2) - 2)) + 1)
                    XCTAssertEqual(components(down.constants[.fragment]?["g_BloomStrength"])?.map(\.bitPattern), [strength.bitPattern])
                    XCTAssertEqual(try Dictionary(uniqueKeysWithValues: capacityIDs.map { try ($0, ObjectIdentifier(XCTUnwrap(renderer.targets[$0]))) }), capacity)
                }
                XCTAssertEqual(renderer.pipelineCreations, pipelines, "N changes must use already prepared PSOs")
                XCTAssertTrue(renderer.backbuffer === backbuffer)
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                return try await centerRGBA(present(renderer, device: device, queue: queue), width: 32, height: 32)
            }
            let unchanged = try XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: initial))
            var ldrExecutors: [ObjectIdentifier] = []
            for (raw, blue) in [(2, false), (plan.post.hdrBloomCapacity, true), (1, false), (2, true)] {
                let json = host(drive: true, iterations: raw, blue: blue)
                try renderer.applyUserProperties(unchanged, changedJSON: json, mergedJSON: json)
                let pixel = try await check(Int32(raw), blue ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0))
                if hdr {
                    XCTAssertGreaterThan(Int(pixel[blue ? 2 : 0]), Int(pixel[1]) + 5)
                } else {
                    for (actual, expected) in zip(pixel.prefix(3), blue ? [128, 128, 192] : [192, 128, 128]) {
                        XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 1)
                    }
                    if ldrExecutors.isEmpty {
                        ldrExecutors = renderer.graphExecutorIdentities
                    }
                    XCTAssertEqual(renderer.graphExecutorIdentities, ldrExecutors, "LDR ignores raw HDR N for graph selection")
                }
            }
            let unrelated = try document(hdr: hdr, visible: false)
            let invalid = try document(hdr: hdr, iterations: false, tint: [0, 0, 0], visible: false)
            let generation = renderer.state.generation(.bloom)
            let preservationUpdates = try [unchanged, XCTUnwrap(WPEParityUserPropertyUpdate(from: initial, to: unrelated)),
                                           XCTUnwrap(WPEParityUserPropertyUpdate(from: unrelated, to: invalid))]
            for (index, update) in preservationUpdates.enumerated() {
                let json = host(drive: false)
                try renderer.applyUserProperties(update, changedJSON: json, mergedJSON: json)
                _ = try await check(2, SIMD3(0, 0, 1))
                XCTAssertEqual(renderer.state.generation(.bloom), generation)
                XCTAssertEqual(renderer.state.object("1")?.visible, index == 0,
                               "The unrelated update must reach a real non-bloom State consumer")
            }
            let recovered = try document(hdr: hdr, iterations: 3.9, tint: "0.25 0.5 0.75", visible: false)
            try renderer.applyUserProperties(XCTUnwrap(WPEParityUserPropertyUpdate(from: invalid, to: recovered)))
            _ = try await check(3, SIMD3(0.25, 0.5, 0.75))
            XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        }
        // Explicit real-token overflow qualifies CVTTSD2SI, not integer/unsigned JSON tag preservation.
        for (enabled, quality) in [(true, true), (false, true), (true, false)] {
            let cold = try document(hdr: true, iterations: 1e100, tint: "0.25 0.5 0.75", scripts: false, bloom: enabled)
            let plan = try WPEParityFramePlan(document: cold, assets: assets,
                                              settings: .init(bloom: quality, hdrPostProcessing: true), width: 32, height: 32)
            XCTAssertTrue(plan.post.hdrEnabled, "Authored raw bloom controls HDR allocation independently of the resolved live Bool")
            XCTAssertEqual(plan.post.sceneBloomEnabled, enabled)
            XCTAssertEqual(plan.post.bloomEnabled, enabled && quality)
            XCTAssertEqual(plan.post.bloomSettings.hdrIterations, Int(Int32.min))
            let renderer = try await makeRenderer(plan, device: device, queue: queue)
            XCTAssertEqual(renderer.state.scriptField("bloomhdriterations", of: ""), .integer(.min))
            XCTAssertEqual(renderer.state.scriptField("bloomtint", of: ""), .vector(SIMD4(0.25, 0.5, 0.75, 0)))
            for level in 1 ... plan.post.hdrBloomCapacity {
                XCTAssertNotNil(renderer.targets[WPEResourceID("_rt_\(1 << level)FrameBuffer")])
            }
            try await render(renderer)
            let names = renderer.lastFrameDraws.compactMap { entry -> String? in
                guard case let .post(draw)? = renderer.frames[0].draws[entry.operation] else { return nil }
                return draw.shader
            }
            XCTAssertEqual(names.filter { $0.hasPrefix("hdr_") }, enabled && quality ? ["hdr_downsample_bloom"] : [])
            _ = try await present(renderer, device: device, queue: queue)
        }
    }

    /// Native no-hook Bool -> canonical State -> actual post graph, including cold-off and HDR terminals.
    func testScriptBloomBoolSelectsAndReusesActualLDRAndHDRGraphsWithoutChangingAllocationFormat() async throws {
        let engine = try engineAssets()
        let assets = WPEParityProgramAssets(sceneDirectory: scratch, assetRoots: [engine])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func properties(_ enabled: Bool) -> String {
            "{\"enable\":{\"type\":\"bool\",\"value\":\(enabled)}}"
        }
        for (hdr, initial, quality) in [(false, false, true), (false, true, true), (true, true, true), (false, true, false)] {
            let document = try parse([
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 32, "height": 32],
                            "clearcolor": "0.5 0.5 0.5", "clearenabled": true,
                            "bloom": initial, "hdr": hdr, "camerafade": false,
                            "bloomthreshold": 0, "bloomhdrthreshold": 0,
                            "bloomstrength": ["value": 1, "script": """
                            shared.bloomLoads = (shared.bloomLoads || 0) + 1;
                            export function update(value) {
                              if (shared.bloomLoads !== 1) throw new Error('module rerun');
                              thisScene.bloom = engine.userProperties.enable;
                              return value;
                            }
                            """]],
                "objects": [["id": 1, "camera": "bloom witness", "origin": "0 0 0", "angles": "0 0 0"]],
            ])
            let plan = try WPEParityFramePlan(document: document, assets: assets,
                                              settings: .init(bloom: quality, hdrPostProcessing: hdr), width: 32, height: 32)
            if quality {
                XCTAssertTrue(plan.loadPrograms.contains { $0.shader == (hdr ? "combine_hdr" : "combine") },
                              "The live-on utility programs must be prepared even for a cold-off scene")
            }
            let renderer = try await makeRenderer(plan, device: device, queue: queue)
            let backbuffer = renderer.backbuffer
            let script = try WPEParitySceneScript(
                document: document, state: renderer.state, assets: assets,
                canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32),
                materialConstants: plan.materialConstants, resolvedEffectRecords: plan.scene.resolvedEffectRecords,
                host: .init(userPropertiesJSON: properties(initial))
            )
            try renderer.attachScript(script)
            let hookGeneration = renderer.state.generation(.bloom)
            let unchanged = try XCTUnwrap(WPEParityUserPropertyUpdate(from: document, to: document))
            var firstPixels: [UInt8] = []
            var firstExecutors: [ObjectIdentifier] = []
            var firstPipelines: [Int: ObjectIdentifier] = [:]
            var secondTargets: [WPEResourceID: ObjectIdentifier] = [:]
            for (step, enabled) in [initial, !initial, initial].enumerated() {
                try renderer.applyUserProperties(unchanged, changedJSON: properties(enabled), mergedJSON: properties(enabled))
                try await render(renderer)
                let on = enabled && quality
                let posts = renderer.frames[0].draws.values.compactMap { draw -> String? in
                    if case let .post(post) = draw {
                        return post.shader
                    }
                    return nil
                }
                XCTAssertEqual(posts.contains(hdr ? "combine_hdr" : "combine"), on)
                if hdr {
                    XCTAssertEqual(posts.contains("combine_srgb"), !on)
                }
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                XCTAssertTrue(renderer.backbuffer === backbuffer)
                XCTAssertEqual(renderer.backbuffer.pixelFormat, hdr ? .rgba16Float : .rgba8Unorm)
                XCTAssertEqual(renderer.colorTransfer, hdr ? .linear : .authored)
                XCTAssertEqual(renderer.state.scriptField("bloom", of: ""), .vector(SIMD4(enabled ? 1 : 0, 0, 0, 0)))
                XCTAssertEqual(renderer.state.generation(.bloom), hookGeneration, "Bool must not fabricate the Float hook")
                let pixels = try await present(renderer, device: device, queue: queue)
                for channel in 0 ..< 3 {
                    if hdr, on {
                        XCTAssertGreaterThan(Int(pixels[channel]), 130, "Positive native bloom energy must reach present")
                    } else {
                        XCTAssertLessThanOrEqual(abs(Int(pixels[channel]) - (on ? 192 : 128)), hdr ? 2 : 1)
                    }
                }
                let pipelines = Dictionary(uniqueKeysWithValues: renderer.lastFrameDraws.map {
                    ($0.operation, ObjectIdentifier($0.draw.pipeline.state))
                })
                if step == 0 {
                    firstPixels = pixels; firstExecutors = renderer.graphExecutorIdentities; firstPipelines = pipelines
                } else if step == 1 {
                    secondTargets = renderer.targets.mapValues(ObjectIdentifier.init)
                    if !quality {
                        XCTAssertEqual(renderer.graphExecutorIdentities, firstExecutors)
                    }
                } else {
                    XCTAssertEqual(pixels, firstPixels)
                    XCTAssertEqual(renderer.graphExecutorIdentities, firstExecutors, "Return to the already prepared graph")
                    XCTAssertEqual(pipelines, firstPipelines)
                    XCTAssertEqual(renderer.targets.mapValues(ObjectIdentifier.init), secondTargets)
                }
            }
            // A live true Bool alone cannot bypass Main's nonempty common-vector gate.
            try renderer.applyUserProperties(unchanged, changedJSON: properties(true), mergedJSON: properties(true))
            XCTAssertTrue(renderer.state.removeObject("1"))
            try await render(renderer)
            XCTAssertTrue(renderer.state.commonOrder.isEmpty)
            XCTAssertEqual(renderer.state.scriptField("bloom", of: ""), .vector(SIMD4(1, 0, 0, 0)))
            let pixels = try await present(renderer, device: device, queue: queue)
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(pixels[channel]) - 128), hdr ? 2 : 1)
            }
            XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        }
    }

    func testResolvedBloomDocumentDeltaSwitchesHDRGraphWithoutReallocatingBackbuffer() async throws {
        let engine = try engineAssets()
        let assets = WPEParityProgramAssets(sceneDirectory: scratch, assetRoots: [engine])
        let source: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32],
                        "clearcolor": "0.5 0.5 0.5", "clearenabled": true, "camerafade": false,
                        "bloom": ["value": true, "user": "toggle"], "hdr": true, "bloomhdrthreshold": 0],
            "objects": [["id": 1, "camera": "bloom witness", "origin": "0 0 0", "angles": "0 0 0"]],
        ]
        func document(_ enabled: Bool) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source),
                                             userValues: ["toggle": .bool(enabled)],
                                             makeTransformScriptResolver: { _, _ in NoPostProcessScripts() })
        }
        var previous = try document(false)
        let plan = try WPEParityFramePlan(document: previous, assets: assets,
                                          settings: .init(bloom: true, hdrPostProcessing: true), width: 32, height: 32)
        XCTAssertTrue(plan.post.hdrEnabled, "Raw source Bool controls allocation independently of the resolved live Bool")
        XCTAssertFalse(plan.post.bloomEnabled)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await makeRenderer(plan, device: device, queue: queue)
        let backbuffer = renderer.backbuffer
        var firstExecutors: [ObjectIdentifier] = []
        for (step, enabled) in [false, true, false].enumerated() {
            let next = try document(enabled)
            let update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: previous, to: next))
            XCTAssertEqual(update.sceneBloom, step == 0 ? nil : enabled)
            try renderer.applyUserProperties(update)
            try await render(renderer)
            let terminal = enabled ? "combine_hdr" : "combine_srgb"
            XCTAssertTrue(renderer.frames[0].draws.values.contains {
                if case let .post(post) = $0 {
                    return post.shader == terminal
                }; return false
            })
            XCTAssertTrue(renderer.backbuffer === backbuffer)
            XCTAssertEqual(renderer.backbuffer.pixelFormat, .rgba16Float)
            let pixels = try await present(renderer, device: device, queue: queue)
            for channel in 0 ..< 3 {
                if enabled {
                    XCTAssertGreaterThan(Int(pixels[channel]), 130)
                } else {
                    XCTAssertLessThanOrEqual(abs(Int(pixels[channel]) - 128), 2)
                }
            }
            if step == 0 {
                firstExecutors = renderer.graphExecutorIdentities
            }
            if step == 2 {
                XCTAssertEqual(renderer.graphExecutorIdentities, firstExecutors)
            }
            previous = next
        }
    }

    func testInactiveHDRTerminalTransferIsRejectedDuringReachablePreparation() async throws {
        let engine = try engineAssets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for initial in [false, true] {
            let path = initial ? "materials/util/combine_srgb.json" : "materials/util/combine_hdr_upsample.json"
            var material = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: engine.appendingPathComponent(path))) as? [String: Any])
            var passes = try XCTUnwrap(material["passes"] as? [[String: Any]])
            var combos = passes[0]["combos"] as? [String: Any] ?? [:]
            combos["LINEAR"] = 1
            passes[0]["combos"] = combos
            material["passes"] = passes
            let replacement = try JSONSerialization.data(withJSONObject: material)
            let assets = WPEParityProgramAssets(sources: [.lookup(engine) { name in
                name == path ? replacement : try? Data(contentsOf: engine.appendingPathComponent(name))
            }])
            let source: [String: Any] = [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 32, "height": 32],
                            "bloom": ["value": true, "user": "toggle"], "hdr": true, "camerafade": false],
                "objects": [["id": 1, "camera": "bloom witness", "origin": "0 0 0", "angles": "0 0 0"]],
            ]
            let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source),
                                                            userValues: ["toggle": .bool(initial)],
                                                            makeTransformScriptResolver: { _, _ in NoPostProcessScripts() })
            let plan = try WPEParityFramePlan(document: document, assets: assets,
                                              settings: .init(bloom: true, hdrPostProcessing: true), width: 32, height: 32)
            XCTAssertTrue(plan.post.hdrEnabled)
            XCTAssertEqual(plan.post.bloomEnabled, initial)
            do {
                _ = try await makeRenderer(plan, device: device, queue: queue)
                XCTFail("The inactive terminal must be qualified before a later toggle can select it")
            } catch let error as WPEParityFrameRenderError {
                guard case let .requiredPostProcessUnavailable(pass, reason) = error,
                      case let .program(message) = reason else { return XCTFail("unexpected failure: \(error)") }
                XCTAssertEqual(pass, initial ? "combine_srgb" : "combine_hdr")
                XCTAssertTrue(message.contains("Unsupported HDR presentation shader or transfer combo"))
            }
        }
    }

    func testColdOffBloomRejectsMissingReachableUtilityBeforePresent() async throws {
        let engine = try engineAssets()
        let path = "shaders/downsample_quarter_bloom.vert"
        let assets = WPEParityProgramAssets(sources: [.lookup(engine) { name in
            name == path ? nil : try? Data(contentsOf: engine.appendingPathComponent(name))
        }])
        let document = try parse([
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32],
                        "clearcolor": "0.5 0.5 0.5", "clearenabled": true,
                        "bloom": false, "hdr": false, "camerafade": false],
            "objects": [["id": 1, "camera": "bloom witness", "origin": "0 0 0", "angles": "0 0 0"]],
        ])
        let plan = try WPEParityFramePlan(document: document, assets: assets,
                                          settings: .init(bloom: true), width: 32, height: 32)
        XCTAssertFalse(plan.post.bloomEnabled)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        do {
            _ = try await makeRenderer(plan, device: device, queue: queue)
            XCTFail("An admitted live-on branch must not silently lose its required utility")
        } catch let error as WPEParityFrameRenderError {
            guard case let .requiredPostProcessUnavailable(pass, reason) = error else {
                return XCTFail("unexpected renderer failure: \(error)")
            }
            XCTAssertEqual(pass, "downsample_quarter_bloom")
            XCTAssertEqual(reason, .program("downsample_quarter_bloom: missingShader(\"\(path)\")"))
        }
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
