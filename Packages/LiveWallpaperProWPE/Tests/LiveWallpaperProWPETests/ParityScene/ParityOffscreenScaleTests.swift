import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures
private typealias D = ParitySceneDocuments

/// Expected extents are fixed arithmetic: x0.5 for divided effect FBOs and the first HDR bloom level, x0.75 for
/// full-size effect FBOs and pooled composites, each edge floored at 64 px, long edges under 256 px untouched.
struct ParityOffscreenScaleTests {
    private static let black = WPEClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let fbos = [
        fbo("half", 960, 540), fbo("small", 200, 100), fbo("thin", 600, 100), fbo("narrow", 512, 40),
        fbo("full", 960, 540, scale: 1), fbo("cleared", 960, 540, initialClear: black),
        fbo("script", 960, 540, scriptClearable: true),
        fbo("pingA", 960, 540, swapPartner: "pingB"), fbo("pingB", 960, 540, swapPartner: "pingA"),
        fbo("copyA", 960, 540), fbo("copyB", 960, 540),
    ]

    private static func fbo(_ name: String, _ width: Int, _ height: Int, scale: Int = 2, swapPartner: String? = nil,
                            initialClear: WPEClearColor? = nil, scriptClearable: Bool = false) -> WPEParitySceneFBO {
        WPEParitySceneFBO(name: name, width: width, height: height, swapPartner: swapPartner, scale: scale,
                          initialClear: initialClear, scriptClearable: scriptClearable)
    }

    private static func id(_ name: String) -> WPEResourceID {
        WPEParitySceneResource.effectFBO(fbos.first { $0.name == name }!, effectID: "fx", fullscreen: false)
    }

    /// One layer drawing into every FBO, a point-sampled layer, and a fullscreen layer whose composite is copied.
    private static func scene(tier: Int, msaaSamples: Int = 1) -> WPEParitySceneDescription {
        let draws = ["half", "small", "thin", "narrow", "full", "cleared", "pingA"].map {
            WPEParityScenePass(shader: "p", target: $0)
        }
        let passes = draws + [
            WPEParityScenePass(shader: "c", target: "copyB", kind: .copy(source: "copyA")),
            WPEParityScenePass(shader: "s", kind: .swap(first: "pingA", second: "pingB")),
            WPEParityScenePass(shader: "final", readsFullFrameBuffer: true),
        ]
        let layer = WPEParitySceneObject(id: "L", width: 1024, height: 512,
                                         effects: [WPEParitySceneEffect(id: "fx", passes: passes, fbos: fbos)])
        let point = WPEParitySceneObject(id: "N", width: 800, height: 400, noInterpolation: true,
                                         effects: [F.effect("nfx")])
        let fullscreen = WPEParitySceneObject(id: "S", width: 1920, height: 1080, fullscreen: true,
                                              effects: [F.effect("sfx")])
        let composite = WPEParitySceneObject(id: "C", width: 640, height: 320, colorBlendMode: 5,
                                             effects: [F.effect("cfx")])
        var scene = F.scene([layer, point, fullscreen, composite], msaaSamples: msaaSamples)
        scene.offscreenScaleTier = tier
        scene.shadowAtlas = true
        return scene
    }

    private static func post(tier: Int, msaaSamples: Int = 1) -> WPEParityPostProcessConfig {
        var post = WPEParityPostProcessConfig(
            sceneBloomEnabled: true, userBloomEnabled: true, objectTableNonEmpty: true, hdrEnabled: true,
            msaaSampleCount: msaaSamples, sceneMipMappedFrameBufferEnabled: true,
            qualityMipMappedFrameBufferEnabled: true, backbufferWidth: F.sceneWidth, backbufferHeight: F.sceneHeight
        )
        post.offscreenScaleTier = tier
        return post
    }

    private static func compose(tier: Int, msaaSamples: Int = 1) throws -> WPEParityFrame {
        try WPEParityFrameComposer.compose(scene: scene(tier: tier, msaaSamples: msaaSamples),
                                           post: post(tier: tier, msaaSamples: msaaSamples))
    }

    private static func size(_ resources: [WPELogicalResource], _ id: WPEResourceID) -> SIMD2<Int>? {
        resources.first { $0.id == id }.map { SIMD2($0.width, $0.height) }
    }

    @Test func tierZeroBuildsTodaysFrames() throws {
        var tierZero = Self.scene(tier: 1)
        tierZero.offscreenScaleTier = 0
        let fixtures = [
            Self.scene(tier: 0),
            F.scene([F.layer(effects: [F.effect("fx", readsFullFrameBuffer: true)])]),
            F.scene([F.layer("A", passthrough: true), F.layer("B", parentID: "A", effects: [F.effect("e")])]),
        ]
        for scene in fixtures {
            var explicit = scene
            explicit.offscreenScaleTier = 0
            let frame = WPEParitySceneFrameBuilder.build(explicit)
            #expect(frame == WPEParitySceneFrameBuilder.build(scene))
            #expect(frame.logicalSizes.isEmpty)
        }
        let frame = WPEParitySceneFrameBuilder.build(tierZero)
        #expect(frame == WPEParitySceneFrameBuilder.build(Self.scene(tier: 0)))
        for fbo in Self.fbos {
            #expect(Self.size(frame.resources, Self.id(fbo.name)) == SIMD2(fbo.width, fbo.height), "\(fbo.name)")
        }
        let composed = try Self.compose(tier: 0)
        #expect(composed.logicalSizes.isEmpty)
        #expect(Self.size(composed.resources, "_rt_2FrameBuffer") == SIMD2(960, 540))

        let layer = D.layer(width: 1200, height: 600, effects: [
            D.effect(fbos: [D.fbo("buf", scale: 2)], passes: [D.pass("p", target: "buf"), D.pass("q", binds: [1: "buf"])]),
        ])
        let defaulted = try D.programScene([layer])
        let explicit = try D.programScene([layer], settings: WPEParityProgramSettings(offscreenScaleTier: 0))
        #expect(explicit.scene == defaulted.scene)
        #expect(try WPEParityFrameComposer.compose(scene: explicit.scene(), post: explicit.postProcess)
            == WPEParityFrameComposer.compose(scene: defaulted.scene(), post: defaulted.postProcess))
    }

    @Test func tierOneHalvesDividedEffectBuffersWithinTheFloors() {
        let frame = WPEParitySceneFrameBuilder.build(Self.scene(tier: 1))
        let expected: [String: SIMD2<Int>] = [
            "half": SIMD2(480, 270), "small": SIMD2(200, 100), "thin": SIMD2(300, 64), "narrow": SIMD2(256, 40),
            "full": SIMD2(960, 540), "cleared": SIMD2(960, 540), "script": SIMD2(960, 540),
            "pingA": SIMD2(960, 540), "pingB": SIMD2(960, 540), "copyA": SIMD2(960, 540), "copyB": SIMD2(960, 540),
        ]
        for (name, size) in expected {
            #expect(Self.size(frame.resources, Self.id(name)) == size, "\(name)")
        }
        #expect(frame.logicalSizes == [Self.id("half"): SIMD2(960, 540), Self.id("thin"): SIMD2(600, 100),
                                       Self.id("narrow"): SIMD2(512, 40)])
        #expect(Self.size(frame.resources, "sc.1024.512.bc0") == SIMD2(1024, 512))
    }

    @Test func tierThreeAddsFullSizeEffectBuffersAndPooledComposites() {
        let frame = WPEParitySceneFrameBuilder.build(Self.scene(tier: 3))
        #expect(Self.size(frame.resources, Self.id("half")) == SIMD2(480, 270))
        #expect(Self.size(frame.resources, Self.id("full")) == SIMD2(720, 405))
        #expect(Self.size(frame.resources, "sc.1024.512.bc0") == SIMD2(768, 384))
        // Point-sampled, and the fullscreen composite the scene is copied into.
        #expect(Self.size(frame.resources, "sc.800.400.nc0") == SIMD2(800, 400))
        #expect(Self.size(frame.resources, "sc.1920.1080.bc0") == SIMD2(1920, 1080))
        #expect(frame.logicalSizes["sc.1024.512.bc0"] == SIMD2(1024, 512))
        #expect(frame.logicalSizes[Self.id("full")] == SIMD2(960, 540))
    }

    @Test func tierTwoHalvesTheFirstHDRBloomLevelOnly() throws {
        let tierOne = try Self.compose(tier: 1)
        let tierTwo = try Self.compose(tier: 2)
        #expect(Self.size(tierOne.resources, "_rt_2FrameBuffer") == SIMD2(960, 540))
        #expect(Self.size(tierTwo.resources, "_rt_2FrameBuffer") == SIMD2(480, 270))
        #expect(Self.size(tierTwo.resources, "_rt_4FrameBuffer") == SIMD2(480, 270))
        #expect(tierTwo.logicalSizes["_rt_2FrameBuffer"] == SIMD2(960, 540))
        #expect(tierTwo.logicalSizes[Self.id("half")] == SIMD2(960, 540))
        let post = WPEParityPostProcessBuilder.build(Self.post(tier: 2))
        #expect(post.logicalSizes == ["_rt_2FrameBuffer": SIMD2(960, 540)])
        let combine = try #require(post.draws.first { $0.shader == "combine_hdr" })
        #expect(combine.texelSizes == [SIMD2<Float>(1 / 1920, 1 / 1080), SIMD2<Float>(1 / 960, 1 / 540)])
        #expect(post.draws == WPEParityPostProcessBuilder.build(Self.post(tier: 0)).draws)
    }

    @Test(arguments: 1 ... 3) func neverScaledTargetsKeepTheirSize(tier: Int) throws {
        let full = try Self.compose(tier: 0, msaaSamples: 4)
        let scaled = try Self.compose(tier: tier, msaaSamples: 4)
        let fixed: [WPEResourceID] = [
            "backbuffer", "backbufferDepth", "_rt_FullFrameBuffer", "_rt_FullFrameBufferMultiSampled",
            "_rt_FullFrameBufferMultiSampledDepth", "_rt_MipMappedFrameBuffer", "_rt_shadowAtlas",
            WPEParitySceneResource.layerCompositeA("C"), Self.id("pingA"), Self.id("pingB"),
        ]
        for id in fixed {
            let resource = try #require(full.resources.first { $0.id == id }, "Missing \(id)")
            #expect(scaled.resources.first { $0.id == id } == resource, "\(id)")
            #expect(scaled.logicalSizes[id] == nil, "\(id)")
        }
    }

    @Test(arguments: 1 ... 3) func logicalSizesListEveryShrunkTargetAndNothingElse(tier: Int) throws {
        let full = try Self.compose(tier: 0)
        let scaled = try Self.compose(tier: tier)
        let before = Dictionary(uniqueKeysWithValues: full.resources.map { ($0.id, SIMD2($0.width, $0.height)) })
        var shrunk: [WPEResourceID: SIMD2<Int>] = [:]
        for resource in scaled.resources where before[resource.id] != SIMD2(resource.width, resource.height) {
            shrunk[resource.id] = before[resource.id]
        }
        #expect(!shrunk.isEmpty)
        #expect(scaled.logicalSizes == shrunk)
        #expect(scaled.resources.map(\.id) == full.resources.map(\.id))
        #expect(scaled.operations == full.operations)
        #expect(scaled.draws == full.draws)
    }

    @Test func settingReachesBothBuildersAndMultipliesWithPixelScale() throws {
        let layer = D.layer(width: 1200, height: 600, effects: [
            D.effect(fbos: [D.fbo("buf", scale: 2)], passes: [D.pass("p", target: "buf"), D.pass("q", binds: [1: "buf"])]),
        ])
        let program = try D.programScene([layer], settings: WPEParityProgramSettings(offscreenScaleTier: 2))
        #expect(program.postProcess.offscreenScaleTier == 2)
        let scene = program.scene(effectVisible: { _, _ in true })
        #expect(scene.offscreenScaleTier == 2)
        func buffer(_ pixelScale: Double, _ scene: WPEParitySceneDescription) -> SIMD2<Int>? {
            let frame = WPEParitySceneFrameBuilder.build(scene, physicalCanvasSize: {
                SIMD2(Int(Double($0.x) * pixelScale), Int(Double($0.y) * pixelScale))
            }, pixelScale: pixelScale)
            return frame.resources.first { $0.id.rawValue.hasPrefix("buf_") }.map { SIMD2($0.width, $0.height) }
        }
        var unscaled = scene
        unscaled.offscreenScaleTier = 0
        #expect(buffer(1, unscaled) == SIMD2(600, 300))
        #expect(buffer(1, scene) == SIMD2(300, 150))
        #expect(buffer(0.5, unscaled) == SIMD2(300, 150))
        #expect(buffer(0.5, scene) == SIMD2(150, 75))
    }
}
