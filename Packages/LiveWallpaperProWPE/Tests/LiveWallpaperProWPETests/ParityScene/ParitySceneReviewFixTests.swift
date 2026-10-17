import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures
private typealias D = ParitySceneDocuments

struct ParitySceneLastEffectRoutingTests {
    @Test func onlyTheFinalPassOfTheLastEffectDrawsIntoTheDestination() throws {
        let last = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "p0", compose: true), WPEParityScenePass(shader: "p1"),
        ])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [last])]))
        #expect(Array(F.lines(frame).dropFirst(3)) == [
            "bind \(F.bc1)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.bc0)",
            "draw p0 [\(F.bc1)] normal rgba quad",
            F.sceneBind,
            "draw p1 [\(F.bc0)] translucent rgb mesh",
        ])
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        #expect(Self.compositeReadsBeforeWrite(frame) == [])
    }

    /// Draws that sample a pooled composite nothing has written earlier in the frame.
    private static func compositeReadsBeforeWrite(_ frame: WPEParitySceneFrame) -> [String] {
        var written: Set<WPEResourceID> = []
        var unwritten: [String] = []
        for operation in frame.operations {
            switch operation.kind {
            case .draw:
                guard let draw = frame.draws[operation.pass] else { continue }
                unwritten += draw.reads.filter { $0.rawValue.hasPrefix("sc.") && !written.contains($0) }
                    .map { "\(operation.pass.rawValue) reads \($0)" }
                written.insert(draw.target)
            case let .copy(_, destination), let .resolve(_, destination):
                written.insert(destination)
            case let .clearColor(view, _):
                written.insert(view.resource)
            default:
                break
            }
        }
        return unwritten
    }
}

struct ParitySceneFBOConversionTests {
    @Test func fboFormatFollowsWPEsTable() throws {
        let expected = [
            "rgba8888": "rgba8unorm", "rgb888": "rgba8unorm", "rgb565": "rgba8unorm", "rgba8888s": "rgba8unorm",
            "rg88": "rg8unorm", "r8": "r8unorm", "rg1616f": "rg16float", "r16f": "r16float",
            "rgba1010102": "rgb10a2unorm", "rgba16161616f": "rgba16float", "rgb161616f": "rgba16float",
            "rgba16161616": "rgba16unorm", "rgb161616": "rgba16unorm", "rgba16161616S": "rgba16snorm",
            "rgb161616S": "rgba16snorm",
            // The table is case-sensitive and an unknown string decodes to RGBA8 without an error.
            "R8": "rgba8unorm", "rgba16161616s": "rgba8unorm", "RGBA16F": "rgba8unorm", "bogus": "rgba8unorm",
            "rgba_backbuffer": "rgba8unorm", "RGB_Backbuffer": "rgba8unorm",
        ]
        for (authored, metal) in expected {
            let fbos = try D.converted(D.fbo("f", format: authored))
            #expect(fbos.map(\.format) == [metal], "\(authored)")
        }
    }

    @Test func backbufferFormatFollowsHDR() throws {
        let layer = D.layer(effects: [D.effect(fbos: [D.fbo("f", format: "RGBA_BACKBUFFER"),
                                                      D.fbo("g", format: "rgb_backbuffer")],
            passes: [D.pass("p", target: "f", binds: [1: "g"])])])
        let hdr = try D.convert([layer], general: ["bloom": true, "hdr": true],
                                settings: WPEParityProgramSettings(hdrPostProcessing: true))
        #expect(hdr.backbufferFormat == "rgba16float")
        #expect(hdr.objects[0].effects[0].fbos.map(\.format) == ["rgba16float", "rgba16float"])
    }

    @Test func compressedFBOFormatAllocatesRGBA8AndIsReported() throws {
        let layer = D.layer(effects: [D.effect(fbos: [D.fbo("f", format: "dxt5"), D.fbo("g", format: "bc7")],
                                               passes: [D.pass("p", target: "f", binds: [1: "g"])])])
        let description = try D.convert([layer])
        #expect(description.objects[0].effects[0].fbos.map(\.format) == ["rgba8unorm", "rgba8unorm"])
        #expect(WPEParitySceneFrameBuilder.build(description).diagnostics == [
            .compressedFBOFormat(fbo: "f", format: "dxt5"), .compressedFBOFormat(fbo: "g", format: "bc7"),
        ])
    }

    @Test func fboExtentFollowsFitThenScale() throws {
        func extent(scale: Double, fit: Double? = nil) throws -> [Int] {
            try D.converted(D.fbo("f", scale: scale, fit: fit)).flatMap { [$0.width, $0.height] }
        }
        #expect(try extent(scale: 2) == [200, 100])
        // Native truncates the divided extent and parses `scale` as an integer byte.
        #expect(try extent(scale: 3) == [133, 66])
        #expect(try extent(scale: 2.5) == [200, 100])
        // Keep zero scale safe instead of reproducing the native divide-by-zero path.
        #expect(try extent(scale: 0.5) == [400, 200])
        // Native longest-edge fit truncates its float aspect result, then scale still applies.
        #expect(try extent(scale: 2, fit: 64) == [32, 16])
        #expect(try extent(scale: 1, fit: 75) == [75, 37])
        #expect(try extent(scale: 1, fit: 1000) == [400, 200])
    }

    @Test func relayoutReusesTheOriginalSizeRuleInsteadOfScalingRoundedAllocations() throws {
        let scaled = try #require(D.converted(D.fbo("f", scale: 3)).first)
        let resized = scaled.resized(layerWidth: 1001, layerHeight: 500)
        #expect([resized.width, resized.height] == [333, 166])
        let fitted = try #require(D.converted(D.fbo("f", scale: 3, fit: 75)).first)
        let refitted = fitted.resized(layerWidth: 500, layerHeight: 1000)
        #expect([refitted.width, refitted.height] == [12, 25])
    }

    @Test func explicitDimensionsPrecedeFitAndScaleAndAllocationIsAtLeastTwo() throws {
        var declaration = D.fbo("f", scale: 2, fit: 75)
        declaration["width"] = 120
        declaration["height"] = 40
        let fitted = try #require(D.converted(declaration).first)
        #expect([fitted.width, fitted.height] == [37, 12])
        declaration["fit"] = 0
        let tiny = try #require(D.converted(declaration).first)
        #expect([tiny.width, tiny.height] == [2, 2])
        declaration.removeValue(forKey: "fit")
        declaration["width"] = 5000
        let defaultWidth = try #require(D.converted(declaration).first)
        #expect([defaultWidth.width, defaultWidth.height] == [200, 20])
    }

    @Test func authoredClearIsStringOnlyAndTravelsToResourceInitialization() throws {
        let variants: [(Any, WPEClearColor?)] = [
            ("0.25 0.5 0.75 1", WPEClearColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)),
            ("", WPEClearColor(red: 0, green: 0, blue: 0, alpha: 0)),
            ("1 0 0", nil), ([1, 0, 0, 1], nil),
            ("1 0 0 ", WPEClearColor(red: 1, green: 0, blue: 0, alpha: 0)),
        ]
        for (authored, expected) in variants {
            var declaration = D.fbo("history")
            declaration["clear"] = authored
            let description = try D.convert([D.layer(effects: [D.effect(fbos: [declaration],
                                                                        passes: [D.pass("read", binds: [1: "history"])])])])
            let frame = WPEParitySceneFrameBuilder.build(description)
            let resource = try #require(frame.resources.first { $0.id == "history_400_200_1" })
            #expect(resource.initialClear == expected)
            #expect(!frame.operations.contains { operation in
                if case let .clearColor(view, _) = operation.kind {
                    return view.resource == resource.id
                }
                return false
            }, "authored clear belongs to allocation/resize, not every frame")
        }
    }

    @Test func fboRepeatUsesTheNativeUVSFieldAndEntersTheFrameSamplerTable() throws {
        var declaration = D.fbo("history")
        declaration["uvs"] = "repeat"
        let description = try D.convert([D.layer(effects: [D.effect(fbos: [declaration],
                                                                    passes: [D.pass("read", binds: [1: "history"])])])])
        let frame = WPEParitySceneFrameBuilder.build(description)
        #expect(frame.samplers["history_400_200_1"] == WPEParitySceneSampler(filter: .linear, address: .wrap))
    }

    @Test func fboAndPassConditionsUseTopLevelEffectCombosAndNativeComparisons() throws {
        let comparisons: [(String, Bool)] = [("ge", true), ("gt", false), ("le", true), ("lt", false), ("unknown", true)]
        var fbos: [[String: Any]] = []
        var passes: [[String: Any]] = []
        for (index, comparison) in comparisons.enumerated() {
            let name = "f\(index)"
            let condition: [[String: Any]] = [["ENABLED": 1], ["QUALITY": ["op": comparison.0, "value": 3]]]
            var declaration = D.fbo(name)
            declaration["conditions"] = condition
            fbos.append(declaration)
            passes.append(D.pass(name, target: name, extra: ["conditions": condition]))
        }
        let description = try D.convert([D.layer(effects: [D.effect(fbos: fbos, passes: passes,
                                                                    combos: ["ENABLED": 1, "QUALITY": 3])])])
        #expect(description.objects[0].effects[0].fbos.map(\.name) == ["f0", "f2", "f4"])
        #expect(description.objects[0].effects[0].passes.map(\.shader) == ["f0", "f2", "f4"])
        let disabled = try D.convert([D.layer(effects: [D.effect(fbos: fbos, passes: passes,
                                                                 combos: ["ENABLED": 0, "QUALITY": 3])])])
        #expect(disabled.objects[0].effects[0].fbos.isEmpty && disabled.objects[0].effects[0].passes.isEmpty)
    }
}

struct ParitySceneEffectCommandTests {
    @Test func copyCommandIsConvertedInPassOrder() throws {
        let layer = D.layer(effects: [D.effect(fbos: [D.fbo("history")], passes: [
            D.command("copy", source: "previous", target: "history"),
            D.pass("trail", binds: [1: "history"]),
        ])])
        let effect = try D.convert([layer]).objects[0].effects[0]
        #expect(effect.passes == [
            WPEParityScenePass(shader: "commands/copy", target: "history", kind: .copy(source: nil)),
            WPEParityScenePass(shader: "trail", binds: ["history"], blend: .translucent,
                               source: WPEParitySceneMaterialSource(materialPath: "materials/trail.json",
                                                                    effectFile: "effects/7_1.json", effectPass: 1)),
        ])
        #expect(effect.fbos.map(\.name) == ["history"])
    }

    @Test func copyCommandEmitsACopyOperation() throws {
        let effect = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "commands/copy", target: "history", kind: .copy(source: nil)),
            WPEParityScenePass(shader: "trail", binds: ["history"]),
        ], fbos: [WPEParitySceneFBO(name: "history", width: 512, height: 256)])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [effect])]))
        #expect(Array(F.lines(frame).dropFirst(3)) == [
            "bind \(F.bc0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "copy \(F.bc0)->history_512_256_1",
            F.sceneBind,
            "draw trail [\(F.bc0),history_512_256_1] translucent rgb mesh",
        ])
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    @Test func swapPartnerIsConverted() throws {
        let layer = D.layer(effects: [D.effect(fbos: [D.fbo("a"), D.fbo("b")], passes: [
            D.pass("step", target: "a", binds: [1: "b"]),
            D.command("swap", source: "a", target: "b"),
        ])])
        let effect = try D.convert([layer]).objects[0].effects[0]
        let fbos = effect.fbos
        #expect(fbos.map(\.swapPartner) == ["b", "a"])
        #expect(effect.passes.map(\.kind) == [.draw, .swap(first: "a", second: "b")])
    }

    @Test func swapKeepsItsCommandPosition() throws {
        let effect = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "step", target: "a", binds: ["b"]),
            WPEParityScenePass(shader: "commands/swap", kind: .swap(first: "a", second: "b")),
            WPEParityScenePass(shader: "show", binds: ["a"]),
        ], fbos: [
            WPEParitySceneFBO(name: "a", width: 512, height: 256, swapPartner: "b"),
            WPEParitySceneFBO(name: "b", width: 512, height: 256, swapPartner: "a"),
        ])
        let scene = F.scene([F.layer(effects: [effect])])
        let pair: [WPEResourceID] = ["a_512_256_1", "b_512_256_1"]
        let frame = WPEParitySceneFrameBuilder.build(scene)
        #expect(frame.draws["L/e/0"]?.target == pair[0])
        #expect(frame.draws["L/e/0"]?.reads == [WPEResourceID(F.bc0), pair[1]])
        #expect(frame.draws["L/e/2"]?.reads == [WPEResourceID(F.bc0), pair[0]])
        let relevant = frame.operations.filter { $0.pass.rawValue.hasPrefix("L/e/") }.map(\.kind)
        let command = try #require(relevant.firstIndex(of: .swapResources(first: pair[0], second: pair[1])))
        #expect(relevant[..<command].contains {
            if case .draw = $0 {
                true
            } else {
                false
            }
        })
        #expect(relevant[(command + 1)...].contains {
            if case .draw = $0 {
                true
            } else {
                false
            }
        })
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        for id in pair {
            #expect(graph.resources[id]?.lifetime == .persistent, "\(id)")
            #expect(graph.storage[id] == .dedicated, "\(id)")
        }
    }
}

struct ParitySceneCrossLayerFBOTests {
    @Test func readOfAnotherLayersFBOResolvesToOneSharedResource() throws {
        let writer = D.layer("7", width: 800, height: 400,
                             effects: [D.effect(fbos: [D.fbo("glow", scale: 2)],
                                                passes: [D.pass("emit", target: "glow")])])
        let reader = D.layer("8", effects: [D.effect(passes: [D.pass("use", binds: [1: "glow"])])])
        let description = try D.convert([writer, reader])
        let shared = WPEParitySceneFBO(name: "glow", width: 400, height: 200, shared: true,
                                       unscaledSize: SIMD2(800, 400), scale: 2,
                                       sizing: .init(scale: 2, layerSize: SIMD2(800, 400)))
        #expect(description.objects[0].effects[0].fbos == [shared])
        #expect(description.objects[1].effects[0].fbos == [shared])
        #expect(description.objects[1].effects[0].passes.map(\.binds) == [["glow"]])

        let frame = WPEParitySceneFrameBuilder.build(description)
        #expect(frame.draws["7/1/0"]?.target == WPEParitySceneResource.sharedFBO("glow"))
        #expect(frame.draws["8/1/0"]?.reads.contains(WPEParitySceneResource.sharedFBO("glow")) == true)
        #expect(frame.resources.count(where: { $0.id.rawValue.hasSuffix("glow") }) == 1)
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)

        let program = try D.programScene([writer, reader])
        let resized = program.scene(effectVisible: { _, _ in true }, textSizes: ["7": SIMD2(300, 100)])
        for object in resized.objects {
            let fbo = try #require(object.effects[0].fbos.first)
            #expect([fbo.width, fbo.height] == [150, 50], "shared size still comes from declaring layer 7")
        }
    }

    @Test func readOfAnFBOWrittenByAnEarlierEffectOfTheLayerResolvesToItsResource() throws {
        let layer = D.layer(effects: [
            D.effect("1", fbos: [D.fbo("half", scale: 2)], passes: [D.pass("write", target: "half")]),
            D.effect("2", passes: [D.pass("read", binds: [1: "half"])]),
        ])
        let frame = try WPEParitySceneFrameBuilder.build(D.convert([layer]))
        #expect(frame.draws["7/1/0"]?.target == "half_400_200_2")
        #expect(frame.draws["7/2/0"]?.reads.last == "half_400_200_2")
        #expect(frame.resources.count(where: { $0.id.rawValue.hasPrefix("half") }) == 1)
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }
}

struct ParitySceneLayerFieldConversionTests {
    @Test func samplerFieldsComeFromTheLayerJSON() throws {
        let effect = D.effect(passes: [D.pass("p")])
        let defaults = try D.convert([D.layer(effects: [effect])]).objects[0]
        #expect(!defaults.noInterpolation && defaults.clampUVs)
        let authored = D.layer(json: ["nointerpolation": true, "clampuvs": false], effects: [effect])
        let object = try D.convert([authored]).objects[0]
        #expect(object.noInterpolation && !object.clampUVs)
    }

    @Test func fullscreenLayerSizesItsFBOsFromTheScene() throws {
        // catsout WPSceneParser.cpp binds a fullscreen layer's FBO to the screen at 1 / scale.
        var layer = D.layer(image: "models/util/fullscreenlayer.json",
                            effects: [D.effect(fbos: [D.fbo("half", scale: 2)],
                                               passes: [D.pass("p", target: "half")])])
        layer.model = ["material": "materials/passthrough.json", "fullscreen": true, "passthrough": true]
        let fbos = try D.convert([layer]).objects[0].effects[0].fbos
        #expect(fbos.map { [$0.width, $0.height] } == [[960, 540]])
    }
}
