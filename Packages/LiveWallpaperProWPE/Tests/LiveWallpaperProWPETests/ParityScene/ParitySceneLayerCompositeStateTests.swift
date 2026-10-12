import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures
private typealias D = ParitySceneDocuments

struct ParitySceneBit4TriggerTests {
    @Test func ledsourceAndSceneFogSetBit4() throws {
        let plain = try D.convert([D.layer()])
        #expect(!plain.objects[0].ledSource && !plain.objects[0].requiresLayerComposite)
        #expect(!plain.forcesLayerComposite)
        let led = try D.convert([D.layer(json: ["ledsource": true])]).objects[0]
        #expect(led.ledSource && led.requiresLayerComposite)
        for key in ["fogdistance", "fogheight"] {
            let scene = try D.programScene([D.layer()], general: [key: true])
            #expect(scene.scene.forcesLayerComposite, "\(key)")
            #expect(scene.engineFlags.fogDistance == (key == "fogdistance"), "\(key)")
            #expect(scene.engineFlags.fogHeight == (key == "fogheight"), "\(key)")
        }
    }
}

struct ParitySceneLayerCompositeDrawTests {
    private static func compositeDraw(colorBlendMode: Int, fog: Bool,
                                      blend: WPEParitySceneBlend = .translucent) -> WPEParitySceneDraw? {
        var layer = F.layer(colorBlendMode: colorBlendMode)
        layer.ledSource = true
        layer.materialFog = fog
        layer.blend = blend
        layer.materialState = WPEParitySceneMaterialState(depthTest: true, depthWrite: false)
        return WPEParitySceneFrameBuilder.build(F.scene([layer])).draws["L/passthrough4"]
    }

    @Test func compositeDrawAddsEngineCombosAndCopiesLayerDepthState() {
        let fogged = Self.compositeDraw(colorBlendMode: 0, fog: true)
        #expect(fogged?.source == WPEParitySceneMaterialSource(materialPath: "materials/util/effectpassthrough_4.json",
                                                               combos: ["BLENDMODE": 0, "FOG_COMPUTED": 1]))
        #expect(fogged?.depthTest == true && fogged?.depthWrite == false)
        #expect(fogged?.blend == .translucent)
        // A layer program without FOG drops FOG and FOG_COMPUTED.
        #expect(Self.compositeDraw(colorBlendMode: 23, fog: false)?.source?.combos == ["BLENDMODE": 23])
    }

    @Test func colorBlendModeThirtyOneCompositesAdditivelyWithBlendModeZero() {
        let additive = Self.compositeDraw(colorBlendMode: 31, fog: true)
        #expect(additive?.source?.combos == ["BLENDMODE": 0, "FOG_COMPUTED": 1])
        #expect(additive?.blend == .additive)
    }

    @Test func layerMaterialFogAndStateComeFromItsProgram() throws {
        var fogged = D.layer("7")
        fogged.model = ["material": "materials/fogged.json"]
        var plain = D.layer("8")
        plain.model = ["material": "materials/plain.json"]
        var fogOff = D.layer("9")
        fogOff.model = ["material": "materials/fogoff.json"]
        let files = [
            "shaders/fogimage.vert": "void main() {}\n",
            "shaders/fogimage.frag": """
            // [COMBO] {"material":"fog","combo":"FOG","default":1}
            void main() {}

            """,
            "materials/fogged.json": """
            {"passes":[{"shader":"fogimage","depthtest":"disabled","depthwrite":"disabled","cullmode":"nocull",
            "alphawriting":"enabled"}]}
            """,
            "materials/plain.json": #"{"passes":[{"shader":"plain","alphawriting":"disabled"}]}"#,
            "materials/fogoff.json": #"{"passes":[{"shader":"fogimage","combos":{"fog":0}}]}"#,
        ]
        let objects = try D.convert([fogged, plain, fogOff], files: files).objects
        #expect(objects.map(\.materialFog) == [true, false, false])
        #expect(objects[0].materialState == WPEParitySceneMaterialState(depthTest: false, depthWrite: false,
                                                                        cullsBackFaces: false,
                                                                        alphaWriting: .enabled))
        #expect(objects[1].materialState == WPEParitySceneMaterialState(alphaWriting: .disabled))
        #expect(objects[2].materialState == WPEParitySceneMaterialState())
    }
}

struct ParitySceneModelDrawStateTests {
    private static func modelDraw(_ blend: WPEParitySceneBlend, _ state: WPEParitySceneMaterialState,
                                  inParentComposite: Bool = false) -> (WPEParitySceneDraw?, WPEDrawOperation?) {
        let model = WPEParitySceneObject(id: "M", kind: .model, width: 512, height: 256, materialShader: "generic4",
                                         blend: blend, materialState: state, parentID: inParentComposite ? "P" : nil)
        let parent = F.layer("P", sortKey: 1, passthrough: true, copyBackground: false, effects: [F.effect("pe")])
        let frame = WPEParitySceneFrameBuilder.build(F.scene(inParentComposite ? [model, parent] : [model]))
        let operation = frame.operations.lazy.compactMap { operation -> WPEDrawOperation? in
            guard operation.pass == "M/albedo", case let .draw(draw) = operation.kind else { return nil }
            return draw
        }.first
        return (frame.draws["M/albedo"], operation)
    }

    @Test func depthAndCullComeFromTheMaterial() {
        let (opaque, operation) = Self.modelDraw(.normal, WPEParitySceneMaterialState())
        #expect(opaque?.depthTest == true && opaque?.depthWrite == true && opaque?.cullsBackFaces == true)
        #expect(operation?.depthTest == true && operation?.depthWrite == true)
        let disabled = WPEParitySceneMaterialState(depthTest: false, depthWrite: false, cullsBackFaces: false)
        let (custom, _) = Self.modelDraw(.normal, disabled)
        #expect(custom?.depthTest == false && custom?.depthWrite == false && custom?.cullsBackFaces == false)
    }

    @Test func blendingOtherThanOpaqueTurnsDepthWriteOff() {
        for blend in [WPEParitySceneBlend.translucent, .additive] {
            let (draw, _) = Self.modelDraw(blend, WPEParitySceneMaterialState())
            #expect(draw?.depthTest == true && draw?.depthWrite == false, "\(blend)")
            #expect(draw?.blend == blend)
        }
    }

    @Test func defaultAlphaWritingInheritsTheDestinationMask() {
        #expect(Self.modelDraw(.normal, WPEParitySceneMaterialState()).0?.writeMask == .rgb)
        #expect(Self.modelDraw(.normal, WPEParitySceneMaterialState(), inParentComposite: true).0?.writeMask == .rgba)
        #expect(Self.modelDraw(.normal, WPEParitySceneMaterialState(alphaWriting: .enabled)).0?.writeMask == .rgba)
        let disabled = WPEParitySceneMaterialState(alphaWriting: .disabled)
        #expect(Self.modelDraw(.normal, disabled, inParentComposite: true).0?.writeMask == .rgb)
    }
}
