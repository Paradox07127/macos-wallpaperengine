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

    @Test("0x20 and 0x40 replace only the colour op")
    func minMax() {
        #expect(WPEParityBlendState.wpe(.additive, modifiers: .max)
            == desc(rt(true, .srcAlpha, .one, .max, .srcAlpha, .one, .add, mask: 0x7)))
        #expect(WPEParityBlendState.wpe(.additive, modifiers: .min)
            == desc(rt(true, .srcAlpha, .one, .min, .srcAlpha, .one, .add, mask: 0x7)))
    }

    @Test("Multiply sets SrcBlend to DEST_COLOR")
    func multiply() {
        #expect(WPEParityBlendState.wpe(.translucent, modifiers: .multiply)
            == desc(rt(true, .destColor, .invSrcAlpha, .add, .srcAlpha, .invSrcAlpha, .add, mask: 0x7)))
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
