@testable import LiveWallpaperProWPE
import Testing

@Suite("WPE parity D3D11 depth-stencil states")
struct WPEParityStateDepthStencilTests {
    private func ds(depth: Bool, write: D3D11DepthWriteMask) -> WPEParityDepthStencilState {
        WPEParityDepthStencilState(
            depthEnable: depth, depthWriteMask: write, depthFunc: .greater,
            stencilEnable: false, stencilReadMask: 0, stencilWriteMask: 0,
            frontFace: .zeroed, backFace: .zeroed
        )
    }

    @Test("Observed depth-stencil descriptors")
    func observed() {
        #expect(WPEParityDepthStencilState.wpe(depthTest: false, depthWrite: false) == ds(depth: false, write: .zero))
        #expect(WPEParityDepthStencilState.wpe(depthTest: true, depthWrite: false) == ds(depth: true, write: .zero))
        #expect(WPEParityDepthStencilState.wpe(depthTest: true, depthWrite: true) == ds(depth: true, write: .all))
    }

    @Test("Disabling the test also drops the write, sharing slot 2")
    func offWriteOn() {
        #expect(WPEParityDepthStencilState.wpe(depthTest: false, depthWrite: true) == ds(depth: false, write: .zero))
    }
}

@Suite("WPE parity D3D11 rasterizer states")
struct WPEParityStateRasterizerTests {
    private func rs(_ cull: D3D11CullMode, slope: Float, msaa: Bool) -> WPEParityRasterizerState {
        WPEParityRasterizerState(
            fillMode: .solid, cullMode: cull, frontCounterClockwise: true,
            depthBias: 0, depthBiasClamp: 0, slopeScaledDepthBias: slope,
            depthClipEnable: true, scissorEnable: false,
            multisampleEnable: msaa, antialiasedLineEnable: false
        )
    }

    private func wpe(flip: Bool = false, noCull: Bool = false, bias: Bool = false, msaa: Bool) -> WPEParityRasterizerState {
        .wpe(flipFrontFace: flip, cullingDisabled: noCull, slopeDepthBias: bias, multisample: msaa)
    }

    @Test("Observed rasterizer descriptors")
    func observed() {
        #expect(wpe(msaa: false) == rs(.back, slope: 0, msaa: false))
        #expect(wpe(msaa: true) == rs(.back, slope: 0, msaa: true))
        #expect(wpe(flip: true, bias: true, msaa: false) == rs(.front, slope: -4, msaa: false))
        #expect(wpe(flip: true, bias: true, msaa: true) == rs(.front, slope: -4, msaa: true))
        #expect(wpe(flip: true, msaa: false) == rs(.front, slope: 0, msaa: false))
        #expect(wpe(flip: true, msaa: true) == rs(.front, slope: 0, msaa: true))
        #expect(wpe(noCull: true, bias: true, msaa: false) == rs(.none, slope: -4, msaa: false))
        #expect(wpe(noCull: true, bias: true, msaa: true) == rs(.none, slope: -4, msaa: true))
        #expect(wpe(noCull: true, msaa: false) == rs(.none, slope: 0, msaa: false))
        #expect(wpe(noCull: true, msaa: true) == rs(.none, slope: 0, msaa: true))
    }

    @Test("Slot 4 (bias, culling on, no flip) carries NONE over from slot 2")
    func biasWithoutFlipIsNoCull() {
        #expect(wpe(bias: true, msaa: false) == rs(.none, slope: -4, msaa: false))
    }

    @Test("Flip with culling off is still NONE (slots 3 and 7)")
    func flipNoCull() {
        #expect(wpe(flip: true, noCull: true, msaa: false) == rs(.none, slope: 0, msaa: false))
        #expect(wpe(flip: true, noCull: true, bias: true, msaa: false) == rs(.none, slope: -4, msaa: false))
    }

    @Test("Enum raw values match d3d11.h")
    func rawValues() {
        #expect(D3D11FillMode.solid.rawValue == 3)
        #expect(D3D11CullMode.none.rawValue == 1)
        #expect(D3D11CullMode.back.rawValue == 3)
        #expect(D3D11ComparisonFunc.greater.rawValue == 5)
        #expect(D3D11DepthWriteMask.all.rawValue == 1)
    }
}
