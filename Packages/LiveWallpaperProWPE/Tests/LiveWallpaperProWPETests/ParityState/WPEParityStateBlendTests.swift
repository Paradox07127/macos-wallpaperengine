@testable import LiveWallpaperProWPE
import Testing

@Suite("WPE parity D3D11 blend states")
struct WPEParityStateBlendTests {
    private func rt(
        _ enable: Bool,
        _ src: D3D11Blend, _ dst: D3D11Blend, _ op: D3D11BlendOp,
        _ srcA: D3D11Blend, _ dstA: D3D11Blend, _ opA: D3D11BlendOp,
        mask: UInt8
    ) -> WPEParityRenderTargetBlendDesc {
        WPEParityRenderTargetBlendDesc(
            blendEnable: enable,
            srcBlend: src, destBlend: dst, blendOp: op,
            srcBlendAlpha: srcA, destBlendAlpha: dstA, blendOpAlpha: opA,
            renderTargetWriteMask: D3D11ColorWriteMask(rawValue: mask)
        )
    }

    private func desc(a2c: Bool = false, _ rt0: WPEParityRenderTargetBlendDesc) -> WPEParityBlendState {
        WPEParityBlendState(alphaToCoverageEnable: a2c, independentBlendEnable: false, renderTarget0: rt0)
    }

    @Test("Observed blend descriptors")
    func observed() {
        #expect(WPEParityBlendState.wpe(.normal)
            == desc(rt(false, .one, .zero, .add, .one, .zero, .add, mask: 0x7)))
        #expect(WPEParityBlendState.wpe(.normal, modifiers: .writeAlpha)
            == desc(rt(false, .one, .zero, .add, .one, .zero, .add, mask: 0xF)))
        #expect(WPEParityBlendState.wpe(.translucent)
            == desc(rt(true, .srcAlpha, .invSrcAlpha, .add, .srcAlpha, .invSrcAlpha, .add, mask: 0x7)))
        #expect(WPEParityBlendState.wpe(.translucent, modifiers: .writeAlpha)
            == desc(rt(true, .srcAlpha, .invSrcAlpha, .add, .srcAlpha, .invSrcAlpha, .add, mask: 0xF)))
        #expect(WPEParityBlendState.wpe(.additive)
            == desc(rt(true, .srcAlpha, .one, .add, .srcAlpha, .one, .add, mask: 0x7)))
    }

    @Test("Alpha-to-coverage keeps mode 0 factors with blending off")
    func alphaToCoverage() {
        #expect(WPEParityBlendState.wpe(.alphaToCoverage)
            == desc(a2c: true, rt(false, .one, .zero, .add, .one, .zero, .add, mask: 0x7)))
    }

    @Test("Premultiplied: ONE / INV_SRC_ALPHA, alpha ONE / ONE")
    func premultiplied() {
        #expect(WPEParityBlendState.wpe(.translucent, modifiers: .premultiplied)
            == desc(rt(true, .one, .invSrcAlpha, .add, .one, .one, .add, mask: 0x7)))
    }

    @Test("0x10 writes alpha and blends it with MAX over ONE / ONE")
    func alphaMax() {
        #expect(WPEParityBlendState.wpe(.translucent, modifiers: .alphaMax)
            == desc(rt(true, .srcAlpha, .invSrcAlpha, .add, .one, .one, .max, mask: 0xF)))
    }

    @Test("0x20 and 0x40 change the colour op and set alpha ONE / ONE")
    func minMax() {
        #expect(WPEParityBlendState.wpe(.additive, modifiers: .max)
            == desc(rt(true, .srcAlpha, .one, .max, .one, .one, .add, mask: 0x7)))
        #expect(WPEParityBlendState.wpe(.additive, modifiers: .min)
            == desc(rt(true, .srcAlpha, .one, .min, .one, .one, .add, mask: 0x7)))
    }

    @Test("Multiply sets RGB source DEST_COLOR and alpha ONE / ONE")
    func multiply() {
        #expect(WPEParityBlendState.wpe(.translucent, modifiers: .multiply)
            == desc(rt(true, .destColor, .invSrcAlpha, .add, .one, .one, .add, mask: 0x7)))
    }

    @Test("Original sequential modifier writes retain MIN, DEST_COLOR and alpha MAX when combined")
    func combinedModifiers() {
        // FUN_140099f60: PMA, alphaMax, max, min, multiply; later writes affect only their named fields.
        #expect(WPEParityBlendState.wpe(.translucent, modifiers: [.premultiplied, .alphaMax, .max, .min, .multiply])
            == desc(rt(true, .destColor, .invSrcAlpha, .min, .one, .one, .max, mask: 0xF)))
    }

    @Test("A2C material mode survives model and particle frame production without claiming full coverage")
    func materialDepthAndCoverage() throws {
        #expect(WPEParitySceneBlend(material: "alphatocoverage") == .alphaToCoverage)
        for (mode, writesDepth, authoredDepth) in [(WPEParityBlendMode.normal, true, true),
                                                   (.alphaToCoverage, true, true), (.alphaToCoverage, false, false),
                                                   (.translucent, false, true)] {
            let blend = WPEParitySceneBlend(mode)
            let state = WPEParitySceneMaterialState(depthWrite: authoredDepth)
            let model = WPEParitySceneModel(meshes: [.init(material: nil, shader: "flat", blend: blend, materialState: state)])
            let particleKey = WPEParityParticleDrawKey(objectID: "particle", renderer: 0)
            let particle = WPEParitySceneParticle(draws: [.init(
                key: particleKey, shader: "flat", source: .flatTexture,
                blend: blend, materialState: state
            )])
            let frame = WPEParitySceneFrameBuilder.build(.init(width: 4, height: 4, msaaSamples: 4, objects: [
                .init(id: "model", kind: .model(model), width: 4, height: 4),
                .init(id: "particle", kind: .particle(particle), width: 4, height: 4),
            ]))
            for pass in [WPEParitySceneModel.pass(objectID: "model", mesh: 0), particleKey.passIdentity] {
                let draw = try #require(frame.draws[pass])
                #expect(draw.blend == blend)
                #expect(draw.depthTest)
                #expect(draw.depthWrite == writesDepth)
                if mode == .alphaToCoverage {
                    let operation = try #require(frame.operations.first { operation in
                        guard operation.pass == pass else { return false }
                        if case .draw = operation.kind {
                            return true
                        }
                        return false
                    })
                    guard case let .draw(coverage) = operation.kind else {
                        Issue.record("Expected the model or particle draw operation")
                        return
                    }
                    #expect(coverage.readsDestination)
                    #expect(!coverage.overwritesTargets)
                }
            }
        }
    }

    @Test("Modifier and enum raw values match the engine and d3d11.h")
    func rawValues() {
        #expect(WPEParityBlendModifiers.writeAlpha.rawValue == 0x08)
        #expect(WPEParityBlendModifiers.alphaMax.rawValue == 0x10)
        #expect(WPEParityBlendModifiers.max.rawValue == 0x20)
        #expect(WPEParityBlendModifiers.min.rawValue == 0x40)
        #expect(WPEParityBlendModifiers.premultiplied.rawValue == 0x80)
        #expect(WPEParityBlendModifiers.multiply.rawValue == 0x100)
        #expect(D3D11Blend.invSrcAlpha.rawValue == 6)
        #expect(D3D11Blend.destColor.rawValue == 9)
        #expect(D3D11BlendOp.max.rawValue == 5)
    }
}
