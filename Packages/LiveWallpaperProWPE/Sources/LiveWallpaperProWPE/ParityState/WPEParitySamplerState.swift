/// `D3D11_SAMPLER_DESC`; `borderColor` is RGBA.
public struct WPEParitySamplerState: Sendable, Hashable {
    public var filter: D3D11Filter
    public var addressU: D3D11TextureAddressMode
    public var addressV: D3D11TextureAddressMode
    public var addressW: D3D11TextureAddressMode
    public var mipLODBias: Float
    public var maxAnisotropy: UInt32
    public var comparisonFunc: D3D11ComparisonFunc
    public var borderColor: SIMD4<Float>
    public var minLOD: Float
    public var maxLOD: Float
}

public enum WPEParitySamplerFilter: Sendable, Hashable, CaseIterable {
    case point
    case linear
    case anisotropic
}

public enum WPEParitySamplerAddress: Sendable, Hashable, CaseIterable {
    case wrap
    case clamp
    case border
}

public extension WPEParitySamplerState {
    /// `point` + `clamp` 未实测。
    static func wpe(filter: WPEParitySamplerFilter, address: WPEParitySamplerAddress) -> Self {
        let d3dFilter: D3D11Filter = switch filter {
        case .point: .minMagMipPoint
        case .linear: .minMagMipLinear
        case .anisotropic: .anisotropic
        }
        let mode: D3D11TextureAddressMode = switch address {
        case .wrap: .wrap
        case .clamp: .clamp
        case .border: .border
        }
        return make(filter: d3dFilter, address: mode,
                    maxAnisotropy: filter == .anisotropic ? 8 : 1, comparisonFunc: .always)
    }

    /// Native 140099980:63–94: point, noncomparison TEX sampling. Border overrides clamp on all axes.
    /// The native producer consumes TEXI flags after decoding, so encoded 2D and raw textures use this same leaf.
    /// Other filter/comparison branches return nil rather than guessing their additional producer inputs.
    static func wpePointTexture(flags: UInt32) -> Self? {
        guard flags & 1 != 0, flags & 0x0800_0000 == 0 else { return nil }
        let address: D3D11TextureAddressMode = if flags & 0x0400_0000 != 0 {
            .border
        } else if flags & 2 != 0 {
            .clamp
        } else {
            .wrap
        }
        return make(filter: .minMagMipPoint, address: address, maxAnisotropy: 1, comparisonFunc: .always)
    }

    /// Shadow-atlas comparison sampler. 未实测。
    static func wpeComparison() -> Self {
        make(filter: .comparisonMinMagMipLinear, address: .border, maxAnisotropy: 1, comparisonFunc: .greater)
    }

    private static func make(
        filter: D3D11Filter,
        address: D3D11TextureAddressMode,
        maxAnisotropy: UInt32,
        comparisonFunc: D3D11ComparisonFunc
    ) -> Self {
        WPEParitySamplerState(
            filter: filter,
            addressU: address, addressV: address, addressW: address,
            mipLODBias: 0,
            maxAnisotropy: maxAnisotropy,
            comparisonFunc: comparisonFunc,
            borderColor: SIMD4<Float>(0, 0, 0, 0),
            minLOD: 0,
            maxLOD: .greatestFiniteMagnitude
        )
    }
}
