// D3D11 state enums with their `d3d11.h` numeric values as raw values.

public enum D3D11Blend: UInt32, Sendable, Hashable, CaseIterable {
    case zero = 1
    case one = 2
    case srcColor = 3
    case invSrcColor = 4
    case srcAlpha = 5
    case invSrcAlpha = 6
    case destAlpha = 7
    case invDestAlpha = 8
    case destColor = 9
    case invDestColor = 10
    case srcAlphaSat = 11
    case blendFactor = 14
    case invBlendFactor = 15
    case src1Color = 16
    case invSrc1Color = 17
    case src1Alpha = 18
    case invSrc1Alpha = 19
}

public enum D3D11BlendOp: UInt32, Sendable, Hashable, CaseIterable {
    case add = 1
    case subtract = 2
    case revSubtract = 3
    case min = 4
    case max = 5
}

public struct D3D11ColorWriteMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let red = D3D11ColorWriteMask(rawValue: 1)
    public static let green = D3D11ColorWriteMask(rawValue: 2)
    public static let blue = D3D11ColorWriteMask(rawValue: 4)
    public static let alpha = D3D11ColorWriteMask(rawValue: 8)
    public static let rgb: D3D11ColorWriteMask = [.red, .green, .blue]
    public static let all: D3D11ColorWriteMask = [.red, .green, .blue, .alpha]
}

public enum D3D11ComparisonFunc: UInt32, Sendable, Hashable, CaseIterable {
    case never = 1
    case less = 2
    case equal = 3
    case lessEqual = 4
    case greater = 5
    case notEqual = 6
    case greaterEqual = 7
    case always = 8
}

public enum D3D11DepthWriteMask: UInt32, Sendable, Hashable, CaseIterable {
    case zero = 0
    case all = 1
}

public enum D3D11StencilOp: UInt32, Sendable, Hashable, CaseIterable {
    case keep = 1
    case zero = 2
    case replace = 3
    case incrSat = 4
    case decrSat = 5
    case invert = 6
    case incr = 7
    case decr = 8
}

public enum D3D11FillMode: UInt32, Sendable, Hashable, CaseIterable {
    case wireframe = 2
    case solid = 3
}

public enum D3D11CullMode: UInt32, Sendable, Hashable, CaseIterable {
    case none = 1
    case front = 2
    case back = 3
}

/// Bit layout: 0x01 mip linear, 0x04 mag linear, 0x10 min linear, 0x40 anisotropic, 0x80 comparison.
public enum D3D11Filter: UInt32, Sendable, Hashable, CaseIterable {
    case minMagMipPoint = 0x00
    case minMagPointMipLinear = 0x01
    case minPointMagLinearMipPoint = 0x04
    case minPointMagMipLinear = 0x05
    case minLinearMagMipPoint = 0x10
    case minLinearMagPointMipLinear = 0x11
    case minMagLinearMipPoint = 0x14
    case minMagMipLinear = 0x15
    case anisotropic = 0x55
    case comparisonMinMagMipPoint = 0x80
    case comparisonMinMagPointMipLinear = 0x81
    case comparisonMinPointMagLinearMipPoint = 0x84
    case comparisonMinPointMagMipLinear = 0x85
    case comparisonMinLinearMagMipPoint = 0x90
    case comparisonMinLinearMagPointMipLinear = 0x91
    case comparisonMinMagLinearMipPoint = 0x94
    case comparisonMinMagMipLinear = 0x95
    case comparisonAnisotropic = 0xD5
}

public enum D3D11TextureAddressMode: UInt32, Sendable, Hashable, CaseIterable {
    case wrap = 1
    case mirror = 2
    case clamp = 3
    case border = 4
    case mirrorOnce = 5
}
