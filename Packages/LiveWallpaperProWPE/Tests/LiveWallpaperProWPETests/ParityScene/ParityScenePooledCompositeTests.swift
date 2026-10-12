import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures

struct ParityScenePooledCompositeTests {
    @Test(arguments: [(false, true, "bc"), (false, false, "br"), (true, true, "nc"), (true, false, "nr")])
    func nameEncodesFilterAndAddress(noInterpolation: Bool, clampUVs: Bool, letters: String) {
        var layer = F.layer(effects: [F.effect("e1"), F.effect("e2")])
        layer.noInterpolation = noInterpolation
        layer.clampUVs = clampUVs
        let frame = WPEParitySceneFrameBuilder.build(F.scene([layer]))
        #expect(Self.composites(frame) == ["sc.512.256.\(letters)0", "sc.512.256.\(letters)1"])
        #expect(frame.draws["L/albedo"]?.target == WPEResourceID("sc.512.256.\(letters)1"))
    }

    @Test func nestedLayerCountsAncestorsWithTheSamePrefix() {
        let scene = F.scene([
            F.layer("P", passthrough: true, copyBackground: false, effects: [F.effect("pe")]),
            F.layer("C", parentID: "P", effects: [F.effect("ce")]),
            F.layer("G", parentID: "C", effects: [F.effect("ge")]),
        ])
        let frame = WPEParitySceneFrameBuilder.build(scene)
        // P and C each draw their children into the composite named with index 0.
        #expect(frame.draws["P/pe/0"]?.reads == [WPEResourceID(F.bc0)])
        #expect(frame.draws["C/albedo"]?.target == "sc.512.256.bc01")
        #expect(frame.draws["G/albedo"]?.target == "sc.512.256.bc02")
        #expect(Self.composites(frame) == [F.bc0, "sc.512.256.bc01", "sc.512.256.bc02", F.bc1])
    }

    @Test func noSuffixWithoutAMatchingAncestorComposite() {
        var pointChild = F.layer("C", parentID: "P", effects: [F.effect("ce")])
        pointChild.noInterpolation = true
        let differentSampler = F.scene([
            F.layer("P", passthrough: true, copyBackground: false, effects: [F.effect("pe")]), pointChild,
        ])
        #expect(F.albedoTarget(differentSampler, "C") == "sc.512.256.nc0")
        let parentWithoutComposite = F.scene([F.layer("P"), F.layer("C", parentID: "P", effects: [F.effect("ce")])])
        #expect(F.albedoTarget(parentWithoutComposite, "C") == WPEResourceID(F.bc0))
    }

    @Test func tinyLayerGetsAFourByFourComposite() {
        let tiny = WPEParitySceneObject(id: "L", width: 2, height: 2, colorBlendMode: 5, effects: [F.effect("e1")])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([tiny]))
        let sizes = Dictionary(uniqueKeysWithValues: frame.resources.map { ($0.id, [$0.width, $0.height]) })
        #expect(sizes["sc.4.4.bc1"] == [4, 4])
        #expect(sizes["_rt_imageLayerComposite_L_a"] == [4, 4])
    }

    @Test func compositesFollowTheBackbufferFormat() {
        for format in ["rgba8unorm", "rgba16float"] {
            var scene = F.scene([F.layer(colorBlendMode: 5, effects: [F.effect("e1"), F.effect("e2")])])
            scene.backbufferFormat = format
            let frame = WPEParitySceneFrameBuilder.build(scene)
            for id: WPEResourceID in ["_rt_imageLayerComposite_L_a", WPEResourceID(F.bc1)] {
                #expect(frame.resources.first { $0.id == id }?.format == format, "\(id) \(format)")
            }
        }
    }

    @Test func hdrFullscreenLayerCopiesTheSceneIntoAMatchingComposite() throws {
        let fullscreen = WPEParitySceneObject(id: "S", width: 512, height: 256, fullscreen: true,
                                              effects: [F.effect("e1")])
        var scene = F.scene([fullscreen])
        scene.backbufferFormat = "rgba16float"
        let frame = WPEParitySceneFrameBuilder.build(scene)
        #expect(F.lines(frame).contains("copy backbuffer->sc.1920.1080.bc0"))
        #expect(frame.resources.first { $0.id == "sc.1920.1080.bc0" }?.format == "rgba16float")
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    @Test func samplersDescribeEveryComposite() throws {
        var layer = F.layer(colorBlendMode: 5, effects: [F.effect("e1")])
        layer.noInterpolation = true
        layer.clampUVs = false
        let pointWrap = WPEParitySceneSampler(filter: .point, address: .wrap)
        let frame = WPEParitySceneFrameBuilder.build(F.scene([layer, F.layer("D", effects: [F.effect("d1")])]))
        #expect(frame.samplers == [
            "_rt_imageLayerComposite_L_a": pointWrap,
            "sc.512.256.nr1": pointWrap,
            WPEResourceID(F.bc0): WPEParitySceneSampler(filter: .linear, address: .clamp),
            WPEResourceID(F.bc1): WPEParitySceneSampler(filter: .linear, address: .clamp),
        ])
        let composed = try WPEParityFrameComposer.compose(
            scene: F.scene([layer]), post: WPEParityPostProcessConfig(backbufferWidth: 1920, backbufferHeight: 1080),
            frameIndex: 0
        )
        #expect(composed.samplers["sc.512.256.nr1"] == pointWrap)
    }

    @Test func composerForwardsTheFrameIndex() throws {
        let effect = WPEParitySceneEffect(id: "e", passes: [WPEParityScenePass(shader: "step", target: "a")], fbos: [
            WPEParitySceneFBO(name: "a", width: 512, height: 256, swapPartner: "b"),
            WPEParitySceneFBO(name: "b", width: 512, height: 256, swapPartner: "a"),
        ])
        let post = WPEParityPostProcessConfig(backbufferWidth: 1920, backbufferHeight: 1080)
        for (frameIndex, target) in [(0, "L/e/a"), (1, "L/e/b")] {
            let frame = try WPEParityFrameComposer.compose(scene: F.scene([F.layer(effects: [effect])]), post: post,
                                                           frameIndex: frameIndex)
            let step = frame.draws.values.compactMap { draw -> WPEParitySceneDraw? in
                guard case let .scene(scene) = draw, scene.pass == "L/e/0" else { return nil }
                return scene
            }
            #expect(step.map(\.target) == [WPEResourceID(target)], "frame \(frameIndex)")
        }
    }

    @Test func passReadsAnFBODeclaredByAnotherEffectOfTheLayer() throws {
        let writer = WPEParitySceneEffect(id: "w", passes: [WPEParityScenePass(shader: "write", target: "half")],
                                          fbos: [WPEParitySceneFBO(name: "half", width: 256, height: 128)])
        let reader = WPEParitySceneEffect(id: "r", passes: [WPEParityScenePass(shader: "read", binds: ["half"])])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [writer, reader])]))
        #expect(frame.draws["L/w/0"]?.target == "L/w/half")
        #expect(frame.draws["L/r/0"]?.reads.last == "L/w/half")
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    private static func composites(_ frame: WPEParitySceneFrame) -> [String] {
        frame.resources.map(\.id.rawValue).filter { $0.hasPrefix("sc.") }
    }
}
