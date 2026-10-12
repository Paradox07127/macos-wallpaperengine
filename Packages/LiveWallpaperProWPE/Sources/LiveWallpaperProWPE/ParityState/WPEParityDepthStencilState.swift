/// `D3D11_DEPTH_STENCILOP_DESC`. `nil` stands for a field left at 0, which is not a valid
/// D3D11 enum value; the runtime accepts it only while StencilEnable is FALSE.
public struct WPEParityDepthStencilOpDesc: Sendable, Hashable {
    public var stencilFailOp: D3D11StencilOp?
    public var stencilDepthFailOp: D3D11StencilOp?
    public var stencilPassOp: D3D11StencilOp?
    public var stencilFunc: D3D11ComparisonFunc?

    public static let zeroed = WPEParityDepthStencilOpDesc(
        stencilFailOp: nil, stencilDepthFailOp: nil, stencilPassOp: nil, stencilFunc: nil
    )
}

/// `D3D11_DEPTH_STENCIL_DESC`.
public struct WPEParityDepthStencilState: Sendable, Hashable {
    public var depthEnable: Bool
    public var depthWriteMask: D3D11DepthWriteMask
    public var depthFunc: D3D11ComparisonFunc
    public var stencilEnable: Bool
    public var stencilReadMask: UInt8
    public var stencilWriteMask: UInt8
    public var frontFace: WPEParityDepthStencilOpDesc
    public var backFace: WPEParityDepthStencilOpDesc
}

public extension WPEParityDepthStencilState {
    /// WPE uses reversed-Z (depth cleared to 0), hence GREATER even when the test is off.
    static func wpe(depthTest: Bool, depthWrite: Bool) -> Self {
        WPEParityDepthStencilState(
            depthEnable: depthTest,
            depthWriteMask: depthTest && depthWrite ? .all : .zero,
            depthFunc: .greater,
            stencilEnable: false,
            stencilReadMask: 0,
            stencilWriteMask: 0,
            frontFace: .zeroed,
            backFace: .zeroed
        )
    }
}
