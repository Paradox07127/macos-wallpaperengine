import CoreGraphics
import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures

struct ParitySceneFrameStructureTests {
    @Test func reportSequenceAWithFullFrameRead() {
        let scene = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2", readsFullFrameBuffer: true)])])
        #expect(F.lines(scene) == [F.sceneBind] + F.sceneClear + [
            "bind \(F.br1)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.br0)",
            "draw e1 [\(F.br1)] normal rgba quad",
            F.sceneBind,
            "copy backbuffer->_rt_FullFrameBuffer",
            "draw e2 [\(F.br0),_rt_FullFrameBuffer] translucent rgb mesh",
        ])
    }

    @Test func fullFrameCopyOnlyWhenAnEffectReadsIt() {
        let scene = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2")])])
        let lines = F.lines(scene)
        #expect(!lines.contains("copy backbuffer->_rt_FullFrameBuffer"))
        #expect(lines.last == "draw e2 [\(F.br0)] translucent rgb mesh")
    }

    @Test func clearDisabledEmitsNoClear() {
        let objects = [F.layer(effects: [F.effect("e1")])]
        let disabled = F.lines(F.scene(objects, clearEnabled: false))
        #expect(disabled.first == F.sceneBind)
        #expect(!disabled.contains { $0.hasPrefix("clear") })
        #expect(F.lines(F.scene(objects)) == [F.sceneBind] + F.sceneClear + disabled.dropFirst())
    }

    @Test func multisampledSceneDrawsIntoMSAATargetAndResolves() {
        let objects = [F.layer(effects: [F.effect("e1", readsFullFrameBuffer: true)])]
        let ms = "_rt_FullFrameBufferMultiSampled"
        let lines = F.lines(F.scene(objects, msaaSamples: 4))
        #expect(lines == [
            "bind \(ms)|\(ms)Depth",
            "clear \(ms) 0.1,0.2,0.3,1.0",
            "clearDepth \(ms)Depth 0.0",
            "bind \(F.br0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(ms)|\(ms)Depth",
            "resolve \(ms)->_rt_FullFrameBuffer",
            "draw e1 [\(F.br0),_rt_FullFrameBuffer] translucent rgb mesh",
            "resolve \(ms)->backbuffer",
        ])
        let single = F.lines(F.scene(objects))
        #expect(!single.contains { $0.contains(ms) || $0.hasPrefix("resolve") })
    }

    @Test func invisibleObjectEmitsNothing() {
        let empty = F.lines(F.scene([]))
        #expect(F.lines(F.scene([F.layer(visible: false, effects: [F.effect("e1")])])) == empty)
        let hiddenParent = F.scene([
            F.layer("P", visible: false, effects: [F.effect("pe")]),
            F.layer("C", parentID: "P"),
        ])
        #expect(F.lines(hiddenParent) == empty)
        #expect(F.lines(F.scene([F.layer(effects: [F.effect("e1")])])).count > empty.count)
    }

    @Test func objectsFollowStableSortKey() {
        let scene = F.scene([F.layer("B", sortKey: 2), F.layer("A1", sortKey: 1), F.layer("A2", sortKey: 1)])
        let order = WPEParitySceneFrameBuilder.build(scene).operations.compactMap { operation -> String? in
            guard case .draw = operation.kind else { return nil }
            return operation.pass.rawValue
        }
        #expect(order == ["A1/albedo", "A2/albedo", "B/albedo"])
    }

    @Test func layerWithoutEffectsDrawsDirectlyIntoScene() {
        #expect(F.lines(F.scene([F.layer()])) == [F.sceneBind] + F.sceneClear + [
            F.sceneBind, "draw genericimage2 [L/image] translucent rgb mesh",
        ])
    }
}

struct ParitySceneLayerCompositeTests {
    @Test func bit4VariantGoesThroughCompositeA() {
        let a = "_rt_imageLayerComposite_L_a"
        let scene = F.scene([F.layer(colorBlendMode: 5, effects: [F.effect("e1"), F.effect("e2")])])
        #expect(F.lines(scene) == [F.sceneBind] + F.sceneClear + [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(a)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.br1)",
            "draw e1 [\(a)] normal rgba quad",
            "bind \(a)",
            "draw e2 [\(F.br1)] normal rgba quad",
            F.sceneBind,
            "draw effectpassthrough_4 [\(a),_rt_FullFrameBuffer] translucent rgb mesh",
        ])
    }

    @Test func colorBlendModesZeroAndThirtyOneAreNotBit4() {
        for mode in [0, 31] {
            let lines = F.lines(F.scene([F.layer(colorBlendMode: mode, effects: [F.effect("e1"), F.effect("e2")])]))
            #expect(!lines.contains { $0.contains("_a") || $0.contains("effectpassthrough_4") })
            #expect(!lines.contains("copy backbuffer->_rt_FullFrameBuffer"))
        }
        let additive = WPEParitySceneObject(id: "L", width: 512, height: 256, blend: .additive, colorBlendMode: 31,
                                            effects: [F.effect("e1")])
        #expect(F.lines(F.scene([additive])).last == "draw e1 [\(F.br0)] additive rgb mesh")
    }

    @Test func ledSourceAndGlobalFlagForceBit4() {
        var led = F.layer(effects: [F.effect("e1")])
        led.ledSource = true
        #expect(F.lines(F.scene([led])).last?.hasPrefix("draw effectpassthrough_4") == true)
        var scene = F.scene([F.layer(effects: [F.effect("e1")])])
        #expect(F.lines(scene).last?.hasPrefix("draw effectpassthrough_4") == false)
        scene.forcesLayerComposite = true
        #expect(F.lines(scene).last?.hasPrefix("draw effectpassthrough_4") == true)
    }

    @Test func startingCompositeFollowsParityOfN() {
        let a: WPEResourceID = "_rt_imageLayerComposite_L_a"
        for count in 1 ... 4 {
            let effects = (1 ... count).map { F.effect("e\($0)") }
            let normal = F.albedoTarget(F.scene([F.layer(effects: effects)]))
            #expect(normal == WPEResourceID(count % 2 == 1 ? F.br0 : F.br1), "N=\(count)")
            let bit4 = F.albedoTarget(F.scene([F.layer(colorBlendMode: 5, effects: effects)]))
            #expect(bit4 == (count % 2 == 0 ? a : WPEResourceID(F.br1)), "bit4 N=\(count)")
            // The last effect of a plain layer always samples composites[0].
            let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: effects)]))
            #expect(frame.draws[WPEPassIdentity("L/e\(count)/0")]?.reads == [WPEResourceID(F.br0)])
        }
    }

    @Test func composePassAddsAFlip() {
        func scene(compose: Bool) -> WPEParitySceneDescription {
            let first = WPEParitySceneEffect(id: "e1", passes: [
                WPEParityScenePass(shader: "p0", compose: compose), WPEParityScenePass(shader: "p1"),
            ])
            return F.scene([F.layer(effects: [first, F.effect("e2")])])
        }
        let lines = F.lines(scene(compose: true))
        #expect(Array(lines.dropFirst(3)) == [
            "bind \(F.br0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.br1)",
            "draw p0 [\(F.br0)] normal rgba quad",
            "bind \(F.br0)",
            "draw p1 [\(F.br1)] normal rgba quad",
            F.sceneBind,
            "draw e2 [\(F.br0)] translucent rgb mesh",
        ])
        #expect(Array(F.lines(scene(compose: false)).dropFirst(3)) == [
            "bind \(F.br1)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.br0)",
            "draw p0 [\(F.br1)] normal rgba quad",
            "bind \(F.br0)",
            "draw p1 [\(F.br1)] normal rgba quad",
            F.sceneBind,
            "draw e2 [\(F.br0)] translucent rgb mesh",
        ])
    }

    @Test func disabledEffectIsNotCounted() {
        let withDisabled = F.scene([F.layer(effects: [F.effect("e1"), F.effect("x", enabled: false), F.effect("e2")])])
        let without = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2")])])
        #expect(F.lines(withDisabled) == F.lines(without))
        let enabled = F.scene([F.layer(effects: [F.effect("e1"), F.effect("x"), F.effect("e2")])])
        #expect(F.albedoTarget(enabled) == WPEResourceID(F.br0))
        #expect(F.albedoTarget(without) == WPEResourceID(F.br1))
    }

    @Test func effectFBOTargetsDoNotFlip() {
        let blur = WPEParitySceneEffect(id: "blur", passes: [
            WPEParityScenePass(shader: "down", target: "half"),
            WPEParityScenePass(shader: "up", binds: ["half"]),
        ], fbos: [WPEParitySceneFBO(name: "half", width: 256, height: 128)])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [blur])]))
        #expect(Array(F.lines(frame).dropFirst(3)) == [
            "bind \(F.br0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind L/blur/half",
            "draw down [\(F.br0)] normal rgba quad",
            F.sceneBind,
            "draw up [\(F.br0),L/blur/half] translucent rgb mesh",
        ])
        #expect(frame.resources.first { $0.id == "L/blur/half" }?.lifetime == .pooled)
    }
}

struct ParitySceneCompositionTests {
    @Test func passthroughWithCopyBackgroundDrawsComposeLayerOverSnapshot() {
        let lines = F.lines(F.scene([F.layer(passthrough: true, copyBackground: true, effects: [F.effect("e1")])]))
        #expect(Array(lines.dropFirst(3)) == [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(F.br0)",
            "draw composelayer [_rt_FullFrameBuffer] normal rgba quad",
            F.sceneBind,
            "draw e1 [\(F.br0)] translucent rgb mesh",
        ])
    }

    @Test func passthroughWithoutCopyBackgroundClearsComposite() {
        let lines = F.lines(F.scene([F.layer(passthrough: true, copyBackground: false, effects: [F.effect("e1")])]))
        #expect(Array(lines.dropFirst(3)) == [
            "bind \(F.br0)",
            "clear \(F.br0) 0.0,0.0,0.0,0.0",
            F.sceneBind,
            "draw e1 [\(F.br0)] translucent rgb mesh",
        ])
    }

    @Test func childDrawsIntoParentCompositeWithAlphaMax() {
        func scene(copyBackground: Bool) -> WPEParitySceneDescription {
            F.scene([
                F.layer("C", sortKey: 0, parentID: "P"),
                F.layer("P", sortKey: 1, passthrough: true, copyBackground: copyBackground,
                        effects: [F.effect("pe")]),
            ])
        }
        #expect(Array(F.lines(scene(copyBackground: false)).dropFirst(3)) == [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(F.br0)",
            "clear \(F.br0) 0.0,0.0,0.0,0.0",
            "bind \(F.br0)",
            "draw genericimage2 [C/image] translucent+max rgba mesh",
            F.sceneBind,
            "draw pe [\(F.br0)] translucent rgb mesh",
        ])
        #expect(Array(F.lines(scene(copyBackground: true)).dropFirst(3)) == [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(F.br0)",
            "draw composelayer [_rt_FullFrameBuffer] normal rgba quad",
            "bind \(F.br0)",
            "draw genericimage2 [C/image] translucent rgb mesh",
            F.sceneBind,
            "draw pe [\(F.br0)] translucent rgb mesh",
        ])
    }

    @Test func nestedChildWithEffectsUsesItsOwnPooledPair() {
        let scene = F.scene([
            F.layer("P", passthrough: true, copyBackground: false, effects: [F.effect("pe")]),
            F.layer("C", parentID: "P", effects: [F.effect("ce")]),
        ])
        let frame = WPEParitySceneFrameBuilder.build(scene)
        #expect(frame.draws["C/albedo"]?.target == "sc.512.256.br2")
        #expect(frame.draws["C/ce/0"]?.reads == ["sc.512.256.br2"])
        #expect(frame.draws["C/ce/0"]?.target == WPEResourceID(F.br0))
        #expect(frame.draws["C/ce/0"]?.alphaMax == true)
        #expect(frame.draws["C/ce/0"]?.writeMask == .rgba)
    }
}

struct ParitySceneCompileTests {
    @Test func reportSequenceACompilesWithPooledTargets() throws {
        let scene = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2", readsFullFrameBuffer: true)])])
        let frame = WPEParitySceneFrameBuilder.build(scene)
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        for id in [WPEParitySceneResource.fullFrameBuffer, WPEResourceID(F.br0), WPEResourceID(F.br1)] {
            #expect(graph.resources[id]?.lifetime == .pooled, "\(id)")
        }
        ParityGraphStream.expectPooledStorage(graph)
        #expect(graph.storage[WPEResourceID(F.br0)] != .dedicated)
        #expect(graph.storage[WPEResourceID(F.br1)] != .dedicated)
        #expect(graph.storage[WPEParitySceneResource.backbuffer] == .dedicated)
    }

    @Test func otherVariantsCompile() throws {
        let scenes = [
            F.scene([F.layer(colorBlendMode: 5, effects: [F.effect("e1"), F.effect("e2")])], msaaSamples: 4),
            F.scene([
                F.layer("P", passthrough: true, copyBackground: false, effects: [F.effect("pe")]),
                F.layer("C", parentID: "P", effects: [F.effect("ce", readsFullFrameBuffer: true)]),
            ]),
        ]
        for scene in scenes {
            let frame = WPEParitySceneFrameBuilder.build(scene)
            _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        }
    }
}

struct ParitySceneDocumentConversionTests {
    @Test func convertsDocumentAndGraphFields() {
        let general = WPESceneGeneral(clearColor: SIMD3(0.5, 0.25, 0),
                                      orthogonalProjection: WPESceneOrthogonalProjection(width: 1920, height: 1080,
                                                                                         auto: false),
                                      clearEnabled: WPESceneAuthoredField(seed: false))
        let image = WPESceneImageObject(id: "7", name: "layer", imageRelativePath: "models/a.json",
                                        materialRelativePath: nil, config: WPESceneImageConfig(passthrough: true),
                                        copyBackground: false, origin: .zero, scale: .one, angles: .zero,
                                        visible: true, alpha: 1, color: .one, brightness: 1, blendMode: .normal,
                                        colorBlendMode: 5, alignment: .center, size: CGSize(width: 400, height: 200),
                                        effects: [
                                            WPESceneImageEffect(id: "1", name: "a", fileRelativePath: "a.json",
                                                                visible: true, passOverrides: []),
                                            WPESceneImageEffect(id: "2", name: "b", fileRelativePath: "b.json",
                                                                visible: false, passOverrides: []),
                                        ],
                                        animationLayers: [])
        let document = WPESceneDocument(camera: .defaultCamera, general: general, imageObjects: [image],
                                        diagnostics: [])
        func pass(_ shader: String, phase: WPERenderPassPhase, effect: String? = nil, index: Int = 0,
                  target: WPERenderTarget = .layerComposite(name: "x"), textures: [Int: WPETextureReference] = [:],
                  effectPass: WPESceneJSONValue? = nil) -> WPERenderPass {
            let identity = effect.map {
                WPERenderEffectPassIdentity(objectID: "7", authoredEffectID: $0, authoredEffectPath: "\($0).json",
                                            effectPassIndex: index, authoredOverrideID: nil)
            }
            return WPERenderPass(id: "\(shader)", phase: phase, shader: shader, source: .previous, target: target,
                                 textures: textures, binds: [:], constants: [:], combos: [:],
                                 authoredJSON: WPERenderPassAuthoredJSON(effectPass: effectPass,
                                                                         effectIdentity: identity),
                                 blending: "translucent", cullMode: "nocull", depthTest: "disabled",
                                 depthWrite: "disabled")
        }
        let layer = WPERenderLayer(
            objectID: "7", objectName: "layer", imagePath: "models/a.json", materialPath: nil,
            geometry: WPERenderLayerGeometry(origin: .zero, scale: .one, angles: .zero, alignment: .center,
                                             size: CGSize(width: 400, height: 200), alpha: 1, color: .one,
                                             brightness: 1),
            compositeA: "a", compositeB: "b",
            localFBOs: [WPERenderFBO(name: "half", scale: 2, format: "rgba8888")],
            passes: [
                pass("genericimage2", phase: .material),
                pass("down", phase: .effect(file: "a.json"), effect: "1", target: .fbo(name: "half"),
                     effectPass: .object(["compose": .bool(true)])),
                pass("up", phase: .effect(file: "a.json"), effect: "1", index: 1,
                     textures: [1: .fbo("half"), 2: .fbo(WPESceneAliasName.fullFrameBuffer)]),
                pass("hidden", phase: .effect(file: "b.json"), effect: "2"),
            ],
            sortIndex: 3
        )
        let description = WPEParitySceneDescription(document: document, graph: WPERenderGraph(layers: [layer]))
        #expect(description.width == 1920 && description.height == 1080)
        #expect(description.clearColor == SIMD3(0.5, 0.25, 0))
        #expect(!description.clearEnabled)
        #expect(description.msaaSamples == 1)
        let object = description.objects[0]
        #expect(object.sortKey == 3 && object.width == 400 && object.height == 200)
        #expect(object.colorBlendMode == 5 && object.requiresLayerComposite)
        #expect(object.passthrough && !object.copyBackground)
        #expect(object.blend == .translucent)
        #expect(object.effects.map(\.id) == ["1", "2"])
        #expect(object.effects.map(\.enabled) == [true, false])
        #expect(object.effects[0].passes == [
            WPEParityScenePass(shader: "down", target: "half", compose: true, blend: .translucent),
            WPEParityScenePass(shader: "up", binds: ["half"], readsFullFrameBuffer: true, blend: .translucent),
        ])
        #expect(object.effects[0].fbos == [WPEParitySceneFBO(name: "half", width: 200, height: 100)])
    }
}
