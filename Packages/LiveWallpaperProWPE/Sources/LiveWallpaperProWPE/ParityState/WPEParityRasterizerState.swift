/// `D3D11_RASTERIZER_DESC`.
public struct WPEParityRasterizerState: Sendable, Hashable {
    public var fillMode: D3D11FillMode
    public var cullMode: D3D11CullMode
    public var frontCounterClockwise: Bool
    public var depthBias: Int32
    public var depthBiasClamp: Float
    public var slopeScaledDepthBias: Float
    public var depthClipEnable: Bool
    public var scissorEnable: Bool
    public var multisampleEnable: Bool
    public var antialiasedLineEnable: Bool
}

public extension WPEParityRasterizerState {
    /// `multisample` mirrors the user's MSAA setting, not the bound render target.
    static func wpe(
        flipFrontFace: Bool,
        cullingDisabled: Bool,
        slopeDepthBias: Bool,
        multisample: Bool
    ) -> Self {
        let cull: D3D11CullMode = if cullingDisabled {
            .none
        } else if slopeDepthBias, !flipFrontFace {
            // The engine writes only the bias for this slot, so CullMode stays NONE from the slot before.
            .none
        } else {
            flipFrontFace ? .front : .back
        }
        return WPEParityRasterizerState(
            fillMode: .solid,
            cullMode: cull,
            frontCounterClockwise: true,
            depthBias: 0,
            depthBiasClamp: 0,
            slopeScaledDepthBias: slopeDepthBias ? -4 : 0,
            depthClipEnable: true,
            scissorEnable: false,
            multisampleEnable: multisample,
            antialiasedLineEnable: false
        )
    }
}
