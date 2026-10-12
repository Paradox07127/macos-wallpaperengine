@testable import LiveWallpaperProWPE
import Testing

@Suite("WPE parity D3D11 sampler states")
struct WPEParityStateSamplerTests {
    private func samp(
        _ filter: D3D11Filter,
        _ address: D3D11TextureAddressMode,
        aniso: UInt32,
        cmp: D3D11ComparisonFunc = .always
    ) -> WPEParitySamplerState {
        WPEParitySamplerState(
            filter: filter, addressU: address, addressV: address, addressW: address,
            mipLODBias: 0, maxAnisotropy: aniso, comparisonFunc: cmp,
            borderColor: SIMD4<Float>(0, 0, 0, 0),
            // The capture prints FLT_MAX in %g form as 3.40282e+38.
            minLOD: 0, maxLOD: .greatestFiniteMagnitude
        )
    }

    @Test("Observed sampler descriptors")
    func observed() {
        #expect(WPEParitySamplerState.wpe(filter: .anisotropic, address: .clamp) == samp(.anisotropic, .clamp, aniso: 8))
        #expect(WPEParitySamplerState.wpe(filter: .anisotropic, address: .wrap) == samp(.anisotropic, .wrap, aniso: 8))
        #expect(WPEParitySamplerState.wpe(filter: .linear, address: .clamp) == samp(.minMagMipLinear, .clamp, aniso: 1))
        #expect(WPEParitySamplerState.wpe(filter: .linear, address: .wrap) == samp(.minMagMipLinear, .wrap, aniso: 1))
        #expect(WPEParitySamplerState.wpe(filter: .point, address: .wrap) == samp(.minMagMipPoint, .wrap, aniso: 1))
    }

    @Test("Point clamp follows the same table")
    func pointClamp() {
        #expect(WPEParitySamplerState.wpe(filter: .point, address: .clamp) == samp(.minMagMipPoint, .clamp, aniso: 1))
    }

    @Test("Comparison sampler: linear comparison filter, BORDER, GREATER")
    func comparison() {
        #expect(WPEParitySamplerState.wpeComparison() == samp(.comparisonMinMagMipLinear, .border, aniso: 1, cmp: .greater))
    }

    @Test("Filter and address raw values match d3d11.h")
    func rawValues() {
        #expect(D3D11Filter.minMagMipPoint.rawValue == 0x00)
        #expect(D3D11Filter.minMagMipLinear.rawValue == 0x15)
        #expect(D3D11Filter.anisotropic.rawValue == 0x55)
        #expect(D3D11Filter.comparisonMinMagMipLinear.rawValue == 0x95)
        #expect(D3D11TextureAddressMode.wrap.rawValue == 1)
        #expect(D3D11TextureAddressMode.clamp.rawValue == 3)
        #expect(D3D11TextureAddressMode.border.rawValue == 4)
        #expect(D3D11ComparisonFunc.always.rawValue == 8)
    }
}
