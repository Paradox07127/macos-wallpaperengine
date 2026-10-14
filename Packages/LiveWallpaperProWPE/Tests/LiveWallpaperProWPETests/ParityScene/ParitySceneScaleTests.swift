import Foundation
@testable import LiveWallpaperProWPE
import Testing

/// Mac pixel policy enters through one pure closure. Expected dimensions below are fixed arithmetic, not the
/// scene builder, FBO converter or post builder used as an oracle. No Metal/helper/font/corpus prerequisite.
struct ParitySceneScaleTests {
    private static func canvas(_ size: SIMD2<Int>, scale: Double) -> SIMD2<Int> {
        // Port of the app helper's documented floor/even/min1 input contract, not an expected-value generator.
        SIMD2(max(1, Int((Double(size.x) * scale).rounded(.down)) & ~1),
              max(1, Int((Double(size.y) * scale).rounded(.down)) & ~1))
    }

    @Test func physicalSceneTargetsKeepLogicalGeometryAndUnscaledAssets() throws {
        var puppet = WPEParitySceneObject(id: "P", width: 131, height: 35,
                                          effects: [ParitySceneFixtures.effect("fx", readsFullFrameBuffer: true)])
        puppet.puppetForcesComposite = true
        puppet.puppet = WPEParityScenePuppet(
            vertices: [], indices: Array(0 ... 8), boneCount: 1, skinned: true,
            parts: (0 ..< 3).map { WPEPuppetMeshPart(id: UInt32($0), start: $0 * 3, count: 3) },
            clipGroups: [.init(clipped: [0], mask: [1], maskTexture: "child", parent: 1),
                         .init(clipped: [1], mask: [2], maskTexture: "parent")]
        )
        let thin = WPEParitySceneObject(id: "T", width: 128, height: 16,
                                        effects: [ParitySceneFixtures.effect("thin")])
        let scene = WPEParitySceneDescription(width: 385, height: 217, msaaSamples: 4, objects: [puppet, thin])
        let post = WPEParityPostProcessConfig(
            sceneBloomEnabled: true, userBloomEnabled: true, objectTableNonEmpty: true, msaaSampleCount: 4,
            sceneMipMappedFrameBufferEnabled: true, qualityMipMappedFrameBufferEnabled: true,
            backbufferWidth: 288, backbufferHeight: 162
        )
        let frame = try WPEParityFrameComposer.compose(
            scene: scene, post: post, frameIndex: 0, physicalBackbufferSize: SIMD2(288, 162),
            physicalCanvasSize: { Self.canvas($0, scale: 0.75) }, pixelScale: 0.75
        )
        let sceneTargets: [WPEResourceID] = ["backbuffer", "backbufferDepth", "_rt_FullFrameBuffer",
                                             "_rt_FullFrameBufferMultiSampled", "_rt_FullFrameBufferMultiSampledDepth",
                                             "_rt_FullAlphaMask", "_rt_FullAlphaMaskIntermediate", "_rt_MipMappedFrameBuffer"]
        for id in sceneTargets {
            let resource = try #require(frame.resources.first { $0.id == id }, "Missing actual RT \(id)")
            #expect(SIMD2(resource.width, resource.height) == SIMD2(288, 162), "\(id)")
        }
        let sampled = try #require(frame.resources.first { $0.id == "_rt_FullFrameBufferMultiSampled" })
        #expect(sampled.sampleCount == 4)
        let mipmapped = try #require(frame.resources.first { $0.id == "_rt_MipMappedFrameBuffer" })
        #expect(mipmapped.mipCount == 5)
        for (id, expected) in [("_rt_4FrameBuffer", SIMD2(72, 40)), ("_rt_8FrameBuffer", SIMD2(36, 20)),
                               ("_rt_Bloom", SIMD2(36, 20)), ("sc.96.12.bc0", SIMD2(96, 12)),
                               ("_rt_imageLayerComposite_P_a", SIMD2(98, 26))] {
            let resource = try #require(frame.resources.first { $0.id.rawValue == id })
            #expect(SIMD2(resource.width, resource.height) == expected)
        }
        for (id, expected) in [("P/image", SIMD2(131, 35)), ("T/image", SIMD2(128, 16))] {
            let resource = try #require(frame.resources.first { $0.id.rawValue == id })
            #expect(resource.lifetime == .imported)
            #expect(SIMD2(resource.width, resource.height) == expected)
        }
        let albedo = try #require(frame.draws.values.compactMap { draw -> WPEParitySceneDraw? in
            guard case let .scene(draw) = draw, draw.pass == "T/albedo" else { return nil }
            return draw
        }.first)
        #expect(albedo.fillsComposite)
        #expect(albedo.logicalCompositeSize == SIMD2(128, 16))
        #expect(SIMD2(scene.width, scene.height) == SIMD2(385, 217))
        let quarter = try #require(frame.draws.values.compactMap { draw -> WPEParityPostProcessDraw? in
            guard case let .post(draw) = draw, draw.shader == "downsample_quarter_bloom" else { return nil }
            return draw
        }.first)
        #expect(quarter.texelSizes == [SIMD2<Float>(1 / 288, 1 / 162)])
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    @Test func rawFBOValidationPrecedesPixelScaleAndFitPrecedesByteDivisor() {
        let fbo = WPEParitySceneFBO(name: "A", width: 37, height: 18,
                                    sizing: .init(scale: 258, fit: 75, width: 401, height: 203))
        let scaled = fbo.resized(layerWidth: 131, layerHeight: 35,
                                 physicalCanvasSize: { Self.canvas($0, scale: 0.75) }, pixelScale: 0.75)
        // Native byte(258)=2. base401x203 -> 300x152, fit75*.75 ->56, fitted56x28, /2 ->28x14.
        #expect(SIMD2(scaled.width, scaled.height) == SIMD2(28, 14))
        #expect(scaled.unscaledSize == SIMD2(56, 28))
        #expect(scaled.scale == 2)
        #expect(scaled.sizing?.layerSize == SIMD2(131, 35))
        #expect(WPEParitySceneResource.effectFBO(scaled, effectID: "E", fullscreen: false) == "A_56_28_2")
        let native = fbo.resized(layerWidth: 131, layerHeight: 35)
        #expect(native.unscaledSize == SIMD2(75, 37))
        #expect(SIMD2(native.width, native.height) == SIMD2(37, 18))

        let invalid = WPEParitySceneFBO(name: "bad", width: 65, height: 17,
                                        sizing: .init(scale: 2, fit: 5000, width: 5000, height: -1))
        let rejected = invalid.resized(layerWidth: 131, layerHeight: 35,
                                       physicalCanvasSize: { Self.canvas($0, scale: 0.75) }, pixelScale: 0.75)
        // 5000 and uint16(-1) remain rejected, although 5000*.75 would lie below 4096.
        #expect(rejected.unscaledSize == SIMD2(98, 26))
        #expect(SIMD2(rejected.width, rejected.height) == SIMD2(49, 13))
        let tiny = WPEParitySceneFBO(name: "tiny", width: 2, height: 2,
                                     sizing: .init(scale: 256, width: 65537, height: 2))
            .resized(layerWidth: 131, layerHeight: 35,
                     physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5)
        #expect(tiny.unscaledSize == SIMD2(1, 1)) // uint16(65537)=1; helper floor is 1, not scaler's 64.
        #expect(tiny.scale == 1) // Existing Mac protection for the native zero byte divisor.
        #expect(SIMD2(tiny.width, tiny.height) == SIMD2(2, 2))
        for fit in [0.0, 1.0] {
            let smallest = WPEParitySceneFBO(name: "fit", width: 2, height: 2,
                                             sizing: .init(scale: 2, fit: fit))
                .resized(layerWidth: 128, layerHeight: 64,
                         physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5)
            #expect(smallest.unscaledSize == SIMD2<Int>.zero)
            #expect(SIMD2(smallest.width, smallest.height) == SIMD2(2, 2))
        }
    }

    @Test func hdrPostBuildsItsPyramidAndRenderVarsFromThePhysicalBackbufferOnly() throws {
        let scene = WPEParitySceneDescription(width: 385, height: 217, backbufferFormat: "rgba16float",
                                              objects: [ParitySceneFixtures.layer()])
        var bloom = WPEParityBloomSettings()
        bloom.hdrIterations = 4
        let post = WPEParityPostProcessConfig(sceneBloomEnabled: true, userBloomEnabled: true,
                                              objectTableNonEmpty: true, hdrEnabled: true, bloomSettings: bloom,
                                              backbufferWidth: 192, backbufferHeight: 108, backbufferFormat: "rgba16float")
        let frame = try WPEParityFrameComposer.compose(
            scene: scene, post: post, frameIndex: 0, physicalBackbufferSize: SIMD2(192, 108),
            physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5
        )
        for (name, expected) in [("_rt_2FrameBuffer", SIMD2(96, 54)), ("_rt_4FrameBuffer", SIMD2(48, 27)),
                                 ("_rt_8FrameBuffer", SIMD2(24, 13)), ("_rt_16FrameBuffer", SIMD2(12, 6))] {
            let resource = try #require(frame.resources.first { $0.id.rawValue == name })
            #expect(SIMD2(resource.width, resource.height) == expected)
            #expect(resource.format == "rgba16float")
        }
        let first = try #require(frame.draws.values.compactMap { draw -> WPEParityPostProcessDraw? in
            guard case let .post(draw) = draw, draw.shader == "hdr_downsample_bloom" else { return nil }
            return draw
        }.first)
        #expect(first.constants["g_RenderVar0"] == [Float(1) / 192, Float(1) / 108, -Float(1) / 192, -Float(1) / 108])
        let cubic = try #require(frame.draws.values.compactMap { draw -> WPEParityPostProcessDraw? in
            guard case let .post(draw) = draw, draw.shader == "hdr_upsample_cubic",
                  draw.reads == [WPEResourceID("_rt_16FrameBuffer")] else { return nil }
            return draw
        }.first)
        #expect(cubic.constants["g_RenderVar0"] == [Float(8) / 192, Float(8) / 108, -Float(8) / 192, -Float(8) / 108])
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    @Test func sharedFBOUsesItsDeclaringLayerBeforeFitAndEachBuildStartsLogical() throws {
        let declaration = WPEParityAuthoredObject(id: "D", width: 420, height: 203, effects: [
            WPEParityAuthoredEffect(id: "E", enabled: true,
                                    fbos: [WPEParityAuthoredFBO(name: "shared", scale: 2, fit: 75,
                                                                format: "rgba8888", swapPartner: nil, unique: false)],
                                    passes: [.init(kind: .draw, shader: "write", target: "shared", textures: [],
                                                   compose: false, blend: .normal, source: nil),
                                             .init(kind: .draw, shader: "read", target: nil, textures: ["shared"],
                                                   compose: false, blend: .normal, source: nil)]),
        ])
        let reader = WPEParityAuthoredObject(id: "R", width: 1024, height: 512, effects: [
            WPEParityAuthoredEffect(id: "RE", enabled: true, fbos: [],
                                    passes: [.init(kind: .draw, shader: "read", target: nil, textures: ["shared"],
                                                   compose: false, blend: .normal, source: nil)]),
        ])
        let scope = WPEParitySceneFBOScope([declaration, reader], backbufferFormat: "rgba8unorm")
        var diagnostics: [WPEParitySceneDiagnostic] = []
        let effects = scope.effects(of: reader, diagnostics: &diagnostics)
        let resolved = try #require(effects.first?.fbos.first)
        #expect(resolved.shared)
        #expect(resolved.sizing?.layerSize == SIMD2(420, 203))
        let scene = WPEParitySceneDescription(width: 1920, height: 1080, objects: [
            WPEParitySceneObject(id: "D", width: 420, height: 203,
                                 effects: scope.effects(of: declaration, diagnostics: &diagnostics)),
            WPEParitySceneObject(id: "R", width: 1024, height: 512, effects: effects),
        ])
        let first = WPEParitySceneFrameBuilder.build(scene, physicalCanvasSize: { Self.canvas($0, scale: 0.5) },
                                                     pixelScale: 0.5)
        let second = WPEParitySceneFrameBuilder.build(scene, frameIndex: 1,
                                                      physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5)
        let resource = try #require(first.resources.first { $0.id == "shared" })
        // Declaring420x203 ->210x100, fit37 ->37x17, /2 ->18x8. Reader extent would incorrectly yield18x9.
        #expect(SIMD2(resource.width, resource.height) == SIMD2(18, 8))
        #expect(first == second)
        let native = WPEParitySceneFrameBuilder.build(scene)
        let original = try #require(native.resources.first { $0.id == "shared" })
        #expect(SIMD2(original.width, original.height) == SIMD2(37, 18))
        #expect(scene.objects[1].effects[0].fbos[0].unscaledSize == SIMD2(75, 36))
        let relaid = resolved.resized(layerWidth: 300, layerHeight: 200)
        #expect(relaid.sizing?.layerSize == SIMD2(300, 200))
        #expect(relaid.unscaledSize == SIMD2(75, 50))
    }

    @Test func swapAndUniqueFBOsKeepTheirResourceNamesAndPhysicalPoolKeys() throws {
        let a = WPEParitySceneFBO(name: "A", width: 100, height: 50, swapPartner: "B",
                                  unscaledSize: SIMD2(200, 100), scale: 2,
                                  sizing: .init(scale: 2, layerSize: SIMD2(200, 100)))
        var b = a
        b.name = "B"
        b.swapPartner = "A"
        let unique = WPEParitySceneFBO(name: "unique", width: 128, height: 16, unique: true)
        let effect = WPEParitySceneEffect(id: "E", passes: [
            .init(shader: "write", target: "A"), .init(shader: "writeUnique", target: "unique"),
            .init(shader: "swap", kind: .swap(first: "A", second: "B")),
            .init(shader: "read", binds: ["A", "B", "unique"]),
        ], fbos: [a, b, unique])
        let scene = ParitySceneFixtures.scene([ParitySceneFixtures.layer(effects: [effect])])
        let frame = WPEParitySceneFrameBuilder.build(scene,
                                                     physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5)
        for name in ["A_100_50_2", "B_100_50_2"] {
            let id = WPEResourceID(name)
            let resource = try #require(frame.resources.first { $0.id == id })
            #expect(SIMD2(resource.width, resource.height) == SIMD2(50, 25))
            #expect(resource.lifetime == .persistent)
        }
        let absolute = try #require(frame.resources.first { $0.id == "unique_E" })
        #expect(SIMD2(absolute.width, absolute.height) == SIMD2(64, 8))
        #expect(frame.operations.contains { $0.kind == .swapResources(first: "A_100_50_2", second: "B_100_50_2") })
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    @Test func fullscreenCopiesShareExplicitPhysicalBackbufferAndCompositionStillRejectsMismatch() throws {
        var fullscreen = ParitySceneFixtures.layer(effects: [ParitySceneFixtures.effect("full")])
        fullscreen.fullscreen = true
        let scene = WPEParitySceneDescription(width: 127, height: 63, objects: [fullscreen])
        let post = WPEParityPostProcessConfig(backbufferWidth: 64, backbufferHeight: 64)
        let frame = try WPEParityFrameComposer.compose(
            scene: scene, post: post, frameIndex: 0, physicalBackbufferSize: SIMD2(64, 64),
            physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5
        )
        let composite = try #require(frame.resources.first { $0.id == "sc.64.64.bc0" })
        #expect(SIMD2(composite.width, composite.height) == SIMD2(64, 64))
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        #expect(throws: WPEParityFrameCompositionError.backbufferMismatch(scene: "62x30 rgba8unorm",
                                                                          post: "64x64 rgba8unorm")) {
            try WPEParityFrameComposer.compose(scene: scene, post: post, frameIndex: 0,
                                               physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5)
        }
    }

    @Test func fullscreenViewportResizesTheDeclarationBeforeForeignReadersResolve() throws {
        struct NoScripts: WPESceneTransformScriptResolving {
            func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                             seed _: SIMD3<Double>) -> SIMD3<Double>? {
                nil
            }
        }
        let resources: [String: Any] = [
            "models/full.json": ["fullscreen": true, "material": "materials/base.json"],
            "models/reader.json": ["material": "materials/base.json"],
            "materials/base.json": ["passes": [["shader": "probe"]]],
            "materials/read.json": ["passes": [["shader": "probe", "textures": ["F"]]]],
            "effects/declare.json": [
                "fbos": [["name": "F"], ["name": "X", "width": 640, "height": 360, "scale": 2]],
                "passes": [["material": "materials/base.json", "target": "F"],
                           ["material": "materials/base.json", "target": "X"],
                           ["material": "materials/read.json"]],
            ],
            "effects/read.json": ["passes": [["material": "materials/read.json"]]],
        ]
        let files = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let assets = WPEParityProgramAssets(sources: [.lookup(FileManager.default.temporaryDirectory) { files[$0] }])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [
                ["id": 1, "image": "models/full.json", "size": "1920 1080",
                 "effects": [["id": 10, "file": "effects/declare.json"]]],
                ["id": 2, "image": "models/reader.json", "size": "1024 512",
                 "effects": [["id": 20, "file": "effects/read.json"]]],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let program = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        for (viewport, expected) in [(SIMD2(3840, 2160), SIMD2(1920, 1080)),
                                     (SIMD2(2560, 1440), SIMD2(1280, 720))] {
            let description = program.scene(logicalViewport: viewport)
            #expect(SIMD2(description.width, description.height) == viewport)
            #expect(SIMD2(description.objects[0].width, description.objects[0].height) == viewport)
            #expect(SIMD2(description.objects[1].width, description.objects[1].height) == SIMD2(1024, 512))
            for object in description.objects {
                let shared = try #require(object.effects.first?.fbos.first { $0.name == "F" })
                #expect(shared.shared)
                #expect(shared.sizing?.layerSize == viewport)
            }
            let frame = WPEParitySceneFrameBuilder.build(
                description, physicalBackbufferSize: expected,
                physicalCanvasSize: { Self.canvas($0, scale: 0.5) }, pixelScale: 0.5
            )
            let shared = try #require(frame.resources.first { $0.id == "F" })
            #expect(SIMD2(shared.width, shared.height) == expected)
            let explicit = try #require(frame.resources.first { $0.id.rawValue.hasPrefix("X") })
            #expect(SIMD2(explicit.width, explicit.height) == SIMD2(160, 90))
            _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        }
        let native = WPEParitySceneFrameBuilder.build(program.scene(logicalViewport: SIMD2(3840, 2160)))
        let shared = try #require(native.resources.first { $0.id == "F" })
        #expect(SIMD2(shared.width, shared.height) == SIMD2(3840, 2160))
        #expect(SIMD2(program.scene.width, program.scene.height) == SIMD2(1920, 1080))
    }
}
