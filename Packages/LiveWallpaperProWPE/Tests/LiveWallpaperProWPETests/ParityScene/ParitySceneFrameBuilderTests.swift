import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures
private typealias D = ParitySceneDocuments

struct ParityScenePuppetClipContractTests {
    private let parts = (0 ..< 3).map { WPEPuppetMeshPart(id: UInt32($0), start: $0 * 3, count: 3) }

    @Test func laterParentMaskUsesItsOwnAllocatedSegment() throws {
        let puppet = WPEParityScenePuppet(vertices: [], indices: Array(0 ... 8), boneCount: 1, skinned: true,
                                          parts: parts, clipGroups: [
                                              .init(clipped: [0], mask: [1], maskTexture: "child", parent: 1),
                                              .init(clipped: [1], mask: [2], maskTexture: "parent"),
                                          ])
        try #require(puppet.clipOperations.count == 3)
        #expect(puppet.clipOperations[0] == .segment(0))
        #expect(puppet.clipOperations[2] == .clip(group: 1, ancestors: [], segment: 3))
        guard case let .clip(group, ancestors, segment) = puppet.clipOperations[1] else {
            Issue.record("Child clipping operation is absent")
            return
        }
        #expect(group == 0)
        #expect(segment == 1)
        #expect(ancestors.count == 1)
        #expect(ancestors.first?.group == 1)
        #expect(ancestors.first?.segment == 3)
        #expect(puppet.clipIndices == [6, 7, 8, 3, 4, 5, 0, 1, 2, 6, 7, 8, 3, 4, 5])
    }

    @Test func unchangedPartOrderKeepsClipGenerationAndStableSegments() {
        var puppet = WPEParityScenePuppet(vertices: [], indices: Array(0 ... 8), boneCount: 1, skinned: true,
                                          parts: parts, clipGroups: [.init(clipped: [1], mask: [0], maskTexture: "mask")])
        let unchanged = puppet.setPartOrder([0, 1, 2])
        #expect(!unchanged)
        #expect(puppet.clipGeneration == 0)
        let reordered = puppet.setPartOrder([2, 0, 1])
        #expect(reordered)
        #expect(puppet.clipGeneration == 1)
        #expect(puppet.clipIndices == [6, 7, 8, 0, 1, 2, 0, 1, 2, 3, 4, 5])
        let segments = puppet.clipSegments
        let normalizedUnchanged = puppet.setPartOrder([2, 2, -1, 0])
        #expect(!normalizedUnchanged)
        #expect(puppet.partOrder == [2, 0, 1])
        #expect(puppet.clipSegments == segments)
        #expect(puppet.clipGeneration == 1)
    }

    @Test func clipTargetInheritsDirectOrCompositePublishColorRole() throws {
        for composite in [false, true] {
            for clipped in [false, true] {
                var object = F.layer(effects: composite ? [F.effect("fx")] : [])
                object.material = .init(materialPath: "materials/shared.json")
                object.puppetForcesComposite = composite
                object.puppet = WPEParityScenePuppet(vertices: [], indices: [0, 1, 2, 3, 4, 5],
                                                     boneCount: 1, skinned: true, parts: Array(parts.prefix(2)),
                                                     clipGroups: clipped ? [.init(clipped: [1], mask: [0], flags: 3,
                                                                                  maskTexture: "mask")] : [])
                let frame = WPEParitySceneFrameBuilder.build(F.scene([object]))
                let pass = clipped ? "L/clip1/target" : composite ? "L/passthrough4" : "L/albedo"
                let target = try #require(frame.draws[WPEPassIdentity(pass)])
                #expect(target.colorRole == (composite ? .compositePublish : .albedo))
                #expect(target.colorRole.usesLayerColor == !composite)
                if composite {
                    #expect(frame.draws["L/albedo"]?.colorRole == .compositeFill)
                }
                if clipped {
                    #expect(target.blend == .additive)
                    #expect(frame.draws["L/clip1/mask0"]?.colorRole == .mask)
                    #expect(frame.draws["L/clip1/mask0"]?.clipMaskInverted == true)
                    #expect(frame.operations.contains { operation in
                        if case let .clearColor(view, color) = operation.kind,
                           view.resource == WPEParitySceneResource.fullAlphaMask {
                            return color == WPEClearColor(red: 1, green: 1, blue: 1, alpha: 1)
                        }
                        return false
                    })
                }
            }
        }
    }
}

struct ParitySceneFrameStructureTests {
    @Test func reportSequenceAWithFullFrameRead() {
        let scene = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2", readsFullFrameBuffer: true)])])
        #expect(F.lines(scene) == [F.sceneBind] + F.sceneClear + [
            "bind \(F.bc1)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.bc0)",
            "draw e1 [\(F.bc1)] normal rgba quad",
            F.sceneBind,
            "copy backbuffer->_rt_FullFrameBuffer",
            "draw e2 [\(F.bc0),_rt_FullFrameBuffer] translucent rgb mesh",
        ])
    }

    @Test func fullFrameCopyOnlyWhenAnEffectReadsIt() {
        let scene = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2")])])
        let lines = F.lines(scene)
        #expect(!lines.contains("copy backbuffer->_rt_FullFrameBuffer"))
        #expect(lines.last == "draw e2 [\(F.bc0)] translucent rgb mesh")
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
            "bind \(F.bc0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(ms)|\(ms)Depth",
            "resolve \(ms)->_rt_FullFrameBuffer",
            "draw e1 [\(F.bc0),_rt_FullFrameBuffer] translucent rgb mesh",
            "resolve \(ms)->backbuffer",
        ])
        let single = F.lines(F.scene(objects))
        #expect(!single.contains { $0.contains(ms) || $0.hasPrefix("resolve") })
    }

    @Test func invisibleObjectEmitsNothing() {
        let empty = F.lines(F.scene([]))
        #expect(F.lines(F.scene([F.layer(visible: false, effects: [F.effect("e1")])])) == empty)
        let hiddenParent = F.scene([
            F.layer("P", visible: false, passthrough: true, effects: [F.effect("pe")]),
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
            "bind \(F.bc1)",
            "draw e1 [\(a)] normal rgba quad",
            "bind \(a)",
            "draw e2 [\(F.bc1)] normal rgba quad",
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
        #expect(F.lines(F.scene([additive])).last == "draw e1 [\(F.bc0)] additive rgb mesh")
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
            #expect(normal == WPEResourceID(count % 2 == 1 ? F.bc0 : F.bc1), "N=\(count)")
            let bit4 = F.albedoTarget(F.scene([F.layer(colorBlendMode: 5, effects: effects)]))
            #expect(bit4 == (count % 2 == 0 ? a : WPEResourceID(F.bc1)), "bit4 N=\(count)")
            // The last effect of a plain layer always samples composites[0].
            let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: effects)]))
            #expect(frame.draws[WPEPassIdentity("L/e\(count)/0")]?.reads == [WPEResourceID(F.bc0)])
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
            "bind \(F.bc0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.bc1)",
            "draw p0 [\(F.bc0)] normal rgba quad",
            "bind \(F.bc0)",
            "draw p1 [\(F.bc1)] normal rgba quad",
            F.sceneBind,
            "draw e2 [\(F.bc0)] translucent rgb mesh",
        ])
        #expect(Array(F.lines(scene(compose: false)).dropFirst(3)) == [
            "bind \(F.bc1)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.bc0)",
            "draw p0 [\(F.bc1)] normal rgba quad",
            "bind \(F.bc0)",
            "draw p1 [\(F.bc1)] normal rgba quad",
            F.sceneBind,
            "draw e2 [\(F.bc0)] translucent rgb mesh",
        ])
    }

    @Test func disabledEffectIsNotCounted() {
        let withDisabled = F.scene([F.layer(effects: [F.effect("e1"), F.effect("x", enabled: false), F.effect("e2")])])
        let without = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2")])])
        #expect(F.lines(withDisabled) == F.lines(without))
        let enabled = F.scene([F.layer(effects: [F.effect("e1"), F.effect("x"), F.effect("e2")])])
        #expect(F.albedoTarget(enabled) == WPEResourceID(F.bc0))
        #expect(F.albedoTarget(without) == WPEResourceID(F.bc1))
    }

    @Test func effectFBOTargetsDoNotFlip() {
        let blur = WPEParitySceneEffect(id: "blur", passes: [
            WPEParityScenePass(shader: "down", target: "half"),
            WPEParityScenePass(shader: "up", binds: ["half"]),
        ], fbos: [WPEParitySceneFBO(name: "half", width: 256, height: 128)])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [blur])]))
        #expect(Array(F.lines(frame).dropFirst(3)) == [
            "bind \(F.bc0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind half_256_128_1",
            "draw down [\(F.bc0)] normal rgba quad",
            F.sceneBind,
            "draw up [\(F.bc0),half_256_128_1] translucent rgb mesh",
        ])
        #expect(frame.resources.first { $0.id == "half_256_128_1" }?.lifetime == .pooled)
    }
}

struct ParitySceneCompositionTests {
    @Test func passthroughWithCopyBackgroundDrawsComposeLayerOverSnapshot() {
        let lines = F.lines(F.scene([F.layer(passthrough: true, copyBackground: true, effects: [F.effect("e1")])]))
        #expect(Array(lines.dropFirst(3)) == [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(F.bc0)",
            "draw composelayer [_rt_FullFrameBuffer] normal rgba quad",
            F.sceneBind,
            "draw e1 [\(F.bc0)] translucent rgb mesh",
        ])
    }

    @Test func passthroughWithoutCopyBackgroundClearsComposite() {
        let lines = F.lines(F.scene([F.layer(passthrough: true, copyBackground: false, effects: [F.effect("e1")])]))
        #expect(Array(lines.dropFirst(3)) == [
            "bind \(F.bc0)",
            "clear \(F.bc0) 0.0,0.0,0.0,0.0",
            F.sceneBind,
            "draw e1 [\(F.bc0)] translucent rgb mesh",
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
            "bind \(F.bc0)",
            "clear \(F.bc0) 0.0,0.0,0.0,0.0",
            "bind \(F.bc0)",
            "draw genericimage2 [C/image] translucent+max rgba mesh",
            F.sceneBind,
            "draw pe [\(F.bc0)] translucent rgb mesh",
        ])
        #expect(Array(F.lines(scene(copyBackground: true)).dropFirst(3)) == [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(F.bc0)",
            "draw composelayer [_rt_FullFrameBuffer] normal rgba quad",
            "bind \(F.bc0)",
            "draw genericimage2 [C/image] translucent rgb mesh",
            F.sceneBind,
            "draw pe [\(F.bc0)] translucent rgb mesh",
        ])
    }

    @Test func nestedChildWithEffectsUsesItsOwnPooledPair() {
        let scene = F.scene([
            F.layer("P", passthrough: true, copyBackground: false, effects: [F.effect("pe")]),
            F.layer("C", parentID: "P", effects: [F.effect("ce")]),
        ])
        let frame = WPEParitySceneFrameBuilder.build(scene)
        // P draws its child into bc0, so C's bc0 takes the ancestor count as a suffix.
        #expect(frame.draws["C/albedo"]?.target == "sc.512.256.bc01")
        #expect(frame.draws["C/ce/0"]?.reads == ["sc.512.256.bc01"])
        #expect(frame.draws["C/ce/0"]?.target == WPEResourceID(F.bc0))
        #expect(frame.draws["C/ce/0"]?.alphaMax == true)
        #expect(frame.draws["C/ce/0"]?.writeMask == .rgba)
    }

    @Test func onlyDrawsIntoTheParentCompositeAreMarked() {
        let frame = WPEParitySceneFrameBuilder.build(F.scene([
            F.layer("P", passthrough: true, copyBackground: true, effects: [F.effect("pe")]),
            F.layer("C", parentID: "P"),
            F.layer("D", parentID: "P", effects: [F.effect("d1"), F.effect("d2")]),
            F.layer("G", parentID: "C"),
        ]))
        #expect(frame.draws["C/albedo"]?.compositeOwnerID == "P")
        #expect(frame.draws["G/albedo"]?.compositeOwnerID == "P")
        #expect(frame.draws["D/albedo"]?.compositeOwnerID == nil)
        #expect(frame.draws["D/d1/0"]?.compositeOwnerID == nil)
        #expect(frame.draws["D/d2/0"]?.compositeOwnerID == "P")
        #expect(frame.draws["P/pe/0"]?.compositeOwnerID == nil)
    }

    @Test func onlyTheAlbedoIntoTheLayerCompositeFillsIt() {
        let frame = WPEParitySceneFrameBuilder.build(F.scene([
            F.layer("P", passthrough: true, copyBackground: true, effects: [F.effect("pe")]),
            F.layer("C", parentID: "P"),
        ]))
        #expect(frame.draws["P/albedo"]?.fillsComposite == true)
        #expect(frame.draws["P/pe/0"]?.fillsComposite == false)
        #expect(frame.draws["C/albedo"]?.fillsComposite == false)
    }

    @Test func childOfANonPassthroughParentDrawsInTheSceneLoopByItsOwnSortKey() {
        let frame = WPEParitySceneFrameBuilder.build(F.scene([
            F.layer("P", sortKey: 0, effects: [F.effect("pe")]),
            F.layer("X", sortKey: 1),
            F.layer("C", sortKey: 2, parentID: "P"),
        ]))
        #expect(frame.draws["C/albedo"]?.target == "backbuffer")
        #expect(frame.draws["C/albedo"]?.compositeOwnerID == nil)
        #expect(Self.drawOrder(frame) == ["P/albedo", "P/pe/0", "X/albedo", "C/albedo"])
    }

    @Test func nonPassthroughChildInAContainerIsFollowedByItsChildren() {
        let frame = WPEParitySceneFrameBuilder.build(F.scene([
            F.layer("P", passthrough: true, copyBackground: false, effects: [F.effect("pe")]),
            F.layer("C", parentID: "P", effects: [F.effect("ce")]),
            F.layer("G", parentID: "C"),
        ]))
        #expect(frame.draws["G/albedo"]?.target == WPEResourceID(F.bc0))
        #expect(frame.draws["G/albedo"]?.compositeOwnerID == "P")
        let order = Self.drawOrder(frame)
        #expect(order.firstIndex(of: "G/albedo").map { $0 > order.firstIndex(of: "C/ce/0") ?? .max } == true)
    }

    @Test func childOfAShapeDraws() {
        let effect = WPEParitySceneEffect(id: "E", passes: [WPEParityScenePass(shader: "s")])
        let shape = WPEParitySceneObject(id: "S", kind: .shape(WPEParitySceneShape()), width: 512, height: 256,
                                         effects: [effect])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([shape, F.layer("L", parentID: "S")]))
        #expect(frame.draws["L/albedo"] != nil)
    }

    private static func drawOrder(_ frame: WPEParitySceneFrame) -> [String] {
        frame.operations.compactMap { operation in
            guard case .draw = operation.kind else { return nil }
            return operation.pass.rawValue
        }
    }
}

struct ParitySceneCompileTests {
    @Test func authoredFullscreenEffectKeepsHistoryUntilShaderCoverageIsProven() throws {
        let effect = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "authored-discard-or-displaced-vs", target: "history"),
            WPEParityScenePass(shader: "present", binds: ["history"]),
        ], fbos: [WPEParitySceneFBO(name: "history", width: 512, height: 256)])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [effect])]))
        let first = try #require(frame.draws["L/e/0"])
        #expect(first.geometry == .fullscreenQuad && first.blend == .normal && first.writeMask == .rgba)
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        #expect(graph.encoders.first { $0.attachment(first.target) != nil }?.attachment(first.target)?.load == .load)
        #expect(graph.storage[first.target] == .dedicated)
    }

    @Test func reportSequenceACompilesWithPooledTargets() throws {
        let scene = F.scene([F.layer(effects: [F.effect("e1"), F.effect("e2", readsFullFrameBuffer: true)])])
        let frame = WPEParitySceneFrameBuilder.build(scene)
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        for id in [WPEParitySceneResource.fullFrameBuffer, WPEResourceID(F.bc0), WPEResourceID(F.bc1)] {
            #expect(graph.resources[id]?.lifetime == .pooled, "\(id)")
        }
        ParityGraphStream.expectPooledStorage(graph)
        #expect(graph.storage[WPEResourceID(F.bc0)] == .dedicated)
        #expect(graph.storage[WPEResourceID(F.bc1)] == .dedicated)
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
    @Test func convertsDocumentFields() throws {
        let image = D.layer(json: ["config": ["passthrough": true], "copybackground": false, "colorBlendMode": 5],
                            effects: [
                                D.effect("1", fbos: [D.fbo("half", scale: 2)], passes: [
                                    D.pass("down", target: "half", extra: ["compose": true]),
                                    D.pass("up", binds: [1: "half", 2: WPESceneAliasName.fullFrameBuffer]),
                                ]),
                                D.effect("2", visible: false, passes: [D.pass("hidden")]),
                            ])
        let groups: [[String: Any]] = (1 ... 3).map { ["id": $0, "name": "group \($0)"] }
        let description = try D.convert([image], general: ["clearcolor": "0.5 0.25 0", "clearenabled": false],
                                        objects: groups)
        #expect(description.width == 1920 && description.height == 1080)
        #expect(description.clearColor == SIMD3(0.5, 0.25, 0))
        #expect(!description.clearEnabled)
        #expect(description.msaaSamples == 1)
        let object = description.objects[0]
        #expect(object.kind == .image)
        #expect(object.sortKey == 3 && object.width == 400 && object.height == 200)
        #expect(object.colorBlendMode == 5 && object.requiresLayerComposite)
        #expect(object.passthrough && !object.copyBackground)
        #expect(object.blend == .translucent)
        #expect(object.material == WPEParitySceneMaterialSource(materialPath: "materials/genericimage2.json"))
        #expect(object.effects.map(\.id) == ["1", "2"])
        #expect(object.effects.map(\.enabled) == [true, false])
        func source(_ shader: String, _ pass: Int) -> WPEParitySceneMaterialSource {
            WPEParitySceneMaterialSource(materialPath: "materials/\(shader).json", effectFile: "effects/7_1.json",
                                         effectPass: pass)
        }
        #expect(object.effects[0].passes == [
            WPEParityScenePass(shader: "down", target: "half", compose: true, blend: .translucent,
                               source: source("down", 0)),
            WPEParityScenePass(shader: "up", binds: ["half"], readsFullFrameBuffer: true, blend: .translucent,
                               source: source("up", 1)),
        ])
        #expect(object.effects[0].fbos == [WPEParitySceneFBO(name: "half", width: 200, height: 100,
                                                             unscaledSize: SIMD2(400, 200), scale: 2,
                                                             sizing: .init(scale: 2, layerSize: SIMD2(400, 200)))])
    }

    @Test func drawsNameTheMaterialPassTheyComeFrom() throws {
        let layer = D.layer(json: ["colorBlendMode": 5], effects: [D.effect(passes: [D.pass("p")])])
        let passthrough = D.layer("8", json: ["config": ["passthrough": true]],
                                  effects: [D.effect(passes: [D.pass("q")])])
        let frame = try WPEParitySceneFrameBuilder.build(D.convert([layer, passthrough]))
        #expect(frame.draws["7/albedo"]?.source
            == WPEParitySceneMaterialSource(materialPath: "materials/genericimage2.json"))
        #expect(frame.draws["7/1/0"]?.source
            == WPEParitySceneMaterialSource(materialPath: "materials/p.json", effectFile: "effects/7_1.json",
                                            effectPass: 0))
        #expect(frame.draws["7/passthrough4"]?.source
            == WPEParitySceneMaterialSource(materialPath: "materials/util/effectpassthrough_4.json",
                                            combos: ["BLENDMODE": 5]))
        #expect(frame.draws["8/albedo"]?.source
            == WPEParitySceneMaterialSource(materialPath: "materials/util/composelayer.json"))
    }

    @Test func modelObjectHasItsOwnKindAndNoEffects() throws {
        let model = D.layer("9", image: "models/m.mdl", effects: [D.effect(passes: [D.pass("p")])])
        let object = try D.convert([model]).objects[0]
        guard case .model = object.kind else {
            Issue.record("kind \(object.kind)")
            return
        }
        #expect(object.effects.isEmpty)
    }

    @Test func modelDrawsEachSubMeshStraightIntoTheDestination() {
        let first = WPEParitySceneMaterialSource(materialPath: "materials/models/a.json")
        let second = WPEParitySceneMaterialSource(materialPath: "materials/models/b.json")
        let meshes = [
            WPEParitySceneModelMesh(material: first, shader: "generic4", blend: .translucent),
            WPEParitySceneModelMesh(material: second, shader: "chroma4", blend: .normal,
                                    materialState: WPEParitySceneMaterialState(alphaWriting: .enabled)),
        ]
        let model = WPEParitySceneObject(id: "M", kind: .model(WPEParitySceneModel(meshes: meshes)), width: 512,
                                         height: 256, colorBlendMode: 5, effects: [F.effect("e1")])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([model]))
        #expect(F.lines(frame) == [F.sceneBind] + F.sceneClear + [
            F.sceneBind, "draw generic4 [] translucent rgb model",
            F.sceneBind, "draw chroma4 [] normal rgba model",
        ])
        #expect(frame.draws["M/mesh0"]?.source == first)
        #expect(frame.draws["M/mesh1"]?.source == second)
        #expect(frame.draws["M/mesh0"]?.depthWrite == false)
        #expect(frame.draws["M/mesh1"]?.depthWrite == true)
    }
}
