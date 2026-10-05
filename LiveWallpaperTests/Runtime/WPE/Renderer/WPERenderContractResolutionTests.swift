#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("WPE render contract resolution")
struct WPERenderContractResolutionTests {
    @Test("Texture roles come from active, uncommented shader source", arguments: [false, true])
    func normalRoleFollowsActiveSource(active: Bool) {
        let program = custom("""
        #define NORMALMAP \(active ? 1 : 0)
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        void main() {
            // vec3 n = DecompressNormal(texSample2D(g_Texture1, v_TexCoord));
        #if NORMALMAP
            vec3 n = DecompressNormal(texSample2D(g_Texture1, v_TexCoord));
        #endif
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * texSample2D(g_Texture1, v_TexCoord);
        }
        """)
        let contract = resolve(shader: "custom_normal_probe", program: program)
        #expect(WPEPassRenderContract.textureUsage(shader: "custom_normal_probe", slot: 1, program: program) == (active ? .normal : .unknown))
        #expect(contract.shaderAlpha.unpremultipliedInputSlots.contains(1) == !active)
        #expect(contract.inputs[1]?.semantics == (active ? .data(.normal) : .unknown))
    }

    @Test("A custom program's sampler annotation decides the slot role before the builtin name table")
    func customAnnotationOverridesNameTable() {
        let colorOverlay = custom(sampler1: #"uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_overlay","default":"util/white"}"#)
        let contract = resolve(shader: "effects/opacity", program: colorOverlay)
        #expect(WPEPassRenderContract.textureUsage(shader: "effects/opacity", slot: 1, program: colorOverlay) != .mask)
        #expect(contract.shaderAlpha.unpremultipliedInputSlots.contains(1))
        let cases: [(shader: String, declaration: String, expected: WPETextureUsage)] = [
            ("effects/opacity", #"uniform sampler2D g_Texture1; // {"combo":"MASK","default":"util/white","mode":"opacitymask"}"#, .mask),
            ("effects/shake", #"uniform sampler2D g_Texture1; // {"combo":"FLOWMASK","mode":"flowmask"}"#, .flow),
            ("custom_lit", #"uniform sampler2D g_Texture1; // {"combo":"NORMALMAP","format":"normalmap"}"#, .normal),
            ("effects/opacity", "uniform sampler2D g_Texture1;", .mask),
            ("effects/shake", "uniform sampler2D g_Texture1;", .flow),
        ]
        for item in cases {
            let program = custom(sampler1: item.declaration)
            #expect(WPEPassRenderContract.textureUsage(shader: item.shader, slot: 1, program: program) == item.expected,
                    "\(item.shader) slot 1 lost its role for \(item.declaration)")
            #expect(resolve(shader: item.shader, program: program).inputs[1]?.semantics == .data(item.expected))
        }
    }

    @Test("A blended write over a destination in another representation is diagnosed")
    func mixedDestinationRepresentation() {
        let seed = prepared("seed", shader: "copy", source: .image("seed"), target: .fbo(name: "X"), blending: "premultipliedDisabled")
        let over = prepared("over", shader: "genericimage2", source: .asset("src"), target: .fbo(name: "X"), blending: "premultiplied")
        let fresh = prepared("fresh", shader: "genericimage2", source: .asset("src"), target: .fbo(name: "Y"), blending: "premultiplied")
        let passes = graph([seed, over, fresh]).resolvingRenderContracts().layers[0].passes
        #expect(passes[0].renderContract.stored == .straightColor)
        #expect(passes[1].renderContract.stored == .premultipliedColor)
        #expect(passes[1].renderContract.diagnostics.contains("mixed-destination-representation"))
        #expect(!passes[0].renderContract.diagnostics.contains("mixed-destination-representation"))
        #expect(!passes[2].renderContract.diagnostics.contains("mixed-destination-representation"))
    }

    @Test("An aliased FBO read takes its producer's semantics", arguments: ["_rt_carrier", "CARRIER"], [false, true])
    func aliasedProducerSemantics(alias: String, independent: Bool) {
        let producer = carrierProducer(name: "carrier", independent: independent)
        let consumer = prepared("consumer", shader: "genericimage2", source: .fbo(alias), target: .scene)
        let passes = graph([producer, consumer]).resolvingRenderContracts().layers[0].passes
        let expected: WPEResourceSemantics = independent ? .textEffectCarrier : .straightColor
        #expect(passes[0].renderContract.stored == expected)
        #expect(passes[1].renderContract.inputs[0]?.semantics == expected)
        #expect(passes[1].renderContract.inputs[0]?.origin == .producer)
    }

    @Test("An exact FBO name wins over a case alias")
    func exactProducerWins() {
        let lower = carrierProducer(name: "carrier", independent: false)
        let upper = carrierProducer(name: "CARRIER", independent: true)
        let consumer = prepared("consumer", shader: "genericimage2", source: .fbo("CARRIER"), target: .scene)
        let passes = graph([lower, upper, consumer]).resolvingRenderContracts().layers[0].passes
        #expect(passes[2].renderContract.inputs[0]?.semantics == .textEffectCarrier)
    }

    @Test("Native colour and blend-composite consumers take a text carrier's coverage separately", arguments: [false, true])
    func carrierColourConsumersDeclareIndependentCoverage(carrier: Bool) {
        let semantics: WPEResourceSemantics = carrier ? .textEffectCarrier : .premultipliedColor
        // The blend composite always associates its output, so only colour effects may stay straight.
        let cases: [(shader: String, straightCarrierOutput: Bool)] = [
            ("effects/colorbalance", true), ("effects/color_grading", true), ("wpe_blend_composite", false),
        ]
        for item in cases {
            let pass = WPERenderPass(id: "probe", phase: .material, shader: item.shader, source: .asset("src"),
                                     target: .layerComposite(name: "a"), textures: [0: .asset("src")], binds: [:],
                                     constants: [:], combos: [:], blending: "disabled", cullMode: "nocull",
                                     depthTest: "disabled", depthWrite: "disabled")
            let contract = WPEPassRenderContract.resolve(
                pass: pass, shader: nil, bindings: pass.textures, alphaOverride: nil,
                inputDeclarations: [0: .init(reference: .asset("src"), semantics: semantics, origin: .producer)],
                outputDeclaration: semantics
            )
            #expect(contract.nativeAlpha.independentCoverageInput == carrier, "\(item.shader)")
            #expect(contract.nativeAlpha.straightOutput == (carrier && item.straightCarrierOutput), "\(item.shader)")
        }
    }

    private func carrierProducer(name: String, independent: Bool) -> WPEPreparedRenderPass {
        let raw = prepared("producer-" + name, shader: "genericimage2", source: .asset("src"), target: .fbo(name: name),
                           alpha: .init(unpremultipliedInputSlots: [], premultipliedOutput: false))
        guard independent else { return raw }
        return raw.replacingRenderContract(WPEPassRenderContract.resolve(
            pass: raw.pass, shader: nil, bindings: raw.textureBindings, alphaOverride: raw.alphaContract,
            outputDeclaration: .textEffectCarrier
        ))
    }

    private func custom(sampler1: String) -> WPEShaderProgram {
        custom("""
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        \(sampler1)
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * texSample2D(g_Texture1, v_TexCoord); }
        """)
    }

    private func custom(_ fragment: String) -> WPEShaderProgram {
        WPEShaderProgram(name: "contract_probe", vertexSource: "void main() {}", fragmentSource: fragment, isBuiltin: false)
    }

    private func resolve(shader: String, program: WPEShaderProgram) -> WPEPassRenderContract {
        let pass = WPERenderPass(id: "probe", phase: .material, shader: shader, source: .asset("src"), target: .layerComposite(name: "a"),
                                 textures: [0: .asset("src"), 1: .fbo("c")], binds: [:], constants: [:], combos: [:],
                                 blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        return WPEPassRenderContract.resolve(pass: pass, shader: program, bindings: [:], alphaOverride: nil)
    }

    private func prepared(_ id: String, shader: String, source: WPETextureReference, target: WPERenderTarget,
                          blending: String = "disabled", alpha: WPEShaderAlphaContract? = nil) -> WPEPreparedRenderPass {
        let pass = WPERenderPass(id: id, phase: .material, shader: shader, source: source, target: target,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: blending, cullMode: "nocull",
                                 depthTest: "disabled", depthWrite: "disabled")
        return .init(pass: pass, shader: nil, textureBindings: [0: source], comboValues: [:], uniformValues: [:], alphaContract: alpha)
    }

    private func graph(_ passes: [WPEPreparedRenderPass]) -> WPEPreparedRenderPipeline {
        let layer = WPERenderLayer(objectID: "contract", objectName: "contract", imagePath: "source", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: passes.map(\.pass))
        return .init(layers: [.init(graphLayer: layer, passes: passes)])
    }
}
#endif
