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
        #expect(WPEParitySamplerState.wpe(filter: .point, address: .border) == samp(.minMagMipPoint, .border, aniso: 1))
    }

    @Test("Native point TEX flags give border priority over clamp, independent of volume dimension")
    func pointTextureFlags() {
        // Independent native descriptors from 140099980. Includes U/V/W, zero border and LOD defaults.
        let cases: [(UInt32, D3D11TextureAddressMode)] = [
            (0x0000_0001, .wrap), (0x0000_0003, .clamp),
            (0x0400_0001, .border), (0x0400_0003, .border),
        ]
        for (flags, address) in cases {
            for dimension: UInt32 in [0, 0x40] {
                #expect(WPEParitySamplerState.wpeFileTexture(flags: flags | dimension)
                    == samp(.minMagMipPoint, address, aniso: 1))
            }
        }
    }

    @Test("Native ordinary file textures select anisotropic 8 with the same address priority")
    func anisotropicFileTextureFlags() {
        // 14015eb90 clears internal byte +0x10; 14009aa20 only ORs 8 before calling 1400ec220.
        // That file path passes third argument zero to 140099980: filter 0x55, MaxAnisotropy 8.
        let cases: [(UInt32, D3D11TextureAddressMode)] = [
            (0x0000_0000, .wrap), (0x0000_0002, .clamp),
            (0x0400_0000, .border), (0x0400_0002, .border),
        ]
        for (flags, address) in cases {
            for dimension: UInt32 in [0, 0x40] {
                #expect(WPEParitySamplerState.wpeFileTexture(flags: flags | dimension)
                    == samp(.anisotropic, address, aniso: 8))
            }
        }
    }

    @Test("File texture comparison flags require a proven comparison consumer")
    func fileTextureComparisonFlags() {
        // Reject both filter branches and every address combination; never fall back to a color sampler.
        for flags: UInt32 in [0x0800_0000, 0x0800_0001, 0x0800_0002, 0x0800_0003,
                              0x0C00_0000, 0x0C00_0001, 0x0C00_0002, 0x0C00_0003] {
            for dimension: UInt32 in [0, 0x40] {
                #expect(WPEParitySamplerState.wpeFileTexture(flags: flags | dimension) == nil)
            }
        }
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
