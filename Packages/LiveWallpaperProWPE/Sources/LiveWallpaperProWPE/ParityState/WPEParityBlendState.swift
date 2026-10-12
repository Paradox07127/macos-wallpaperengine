/// `D3D11_RENDER_TARGET_BLEND_DESC`.
public struct WPEParityRenderTargetBlendDesc: Sendable, Hashable {
    public var blendEnable: Bool
    public var srcBlend: D3D11Blend
    public var destBlend: D3D11Blend
    public var blendOp: D3D11BlendOp
    public var srcBlendAlpha: D3D11Blend
    public var destBlendAlpha: D3D11Blend
    public var blendOpAlpha: D3D11BlendOp
    public var renderTargetWriteMask: D3D11ColorWriteMask
}

/// `D3D11_BLEND_DESC`; WPE fills only RT0 and binds a single render target.
public struct WPEParityBlendState: Sendable, Hashable {
    public var alphaToCoverageEnable: Bool
    public var independentBlendEnable: Bool
    public var renderTarget0: WPEParityRenderTargetBlendDesc
}

/// Material pass `blending` values.
public enum WPEParityBlendMode: UInt8, Sendable, Hashable, CaseIterable {
    case normal = 0
    case translucent = 1
    case additive = 2
    /// 未实测
    case alphaToCoverage = 3
}

/// WPE blend-key flag bits; raw values are the engine's own bits.
/// 未实测,`writeAlpha` 除外。
public struct WPEParityBlendModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let writeAlpha = WPEParityBlendModifiers(rawValue: 0x08)
    /// Also writes alpha, and blends alpha with MAX over ONE / ONE.
    public static let alphaMax = WPEParityBlendModifiers(rawValue: 0x10)
    public static let max = WPEParityBlendModifiers(rawValue: 0x20)
    public static let min = WPEParityBlendModifiers(rawValue: 0x40)
    public static let premultiplied = WPEParityBlendModifiers(rawValue: 0x80)
    public static let multiply = WPEParityBlendModifiers(rawValue: 0x100)
}

public extension WPEParityBlendState {
    static func wpe(_ mode: WPEParityBlendMode, modifiers: WPEParityBlendModifiers = []) -> Self {
        var rt = WPEParityRenderTargetBlendDesc(
            blendEnable: false,
            srcBlend: .one, destBlend: .zero, blendOp: .add,
            srcBlendAlpha: .one, destBlendAlpha: .zero, blendOpAlpha: .add,
            renderTargetWriteMask: .rgb
        )
        switch mode {
        case .normal, .alphaToCoverage:
            break
        case .translucent:
            rt.blendEnable = true
            (rt.srcBlend, rt.destBlend) = (.srcAlpha, .invSrcAlpha)
            (rt.srcBlendAlpha, rt.destBlendAlpha) = (.srcAlpha, .invSrcAlpha)
        case .additive:
            rt.blendEnable = true
            (rt.srcBlend, rt.destBlend) = (.srcAlpha, .one)
            (rt.srcBlendAlpha, rt.destBlendAlpha) = (.srcAlpha, .one)
        }

        // Which bit wins when combined bits touch the same field is unverified; order follows the RE report.
        if modifiers.contains(.premultiplied) {
            (rt.srcBlend, rt.destBlend) = (.one, .invSrcAlpha)
            (rt.srcBlendAlpha, rt.destBlendAlpha) = (.one, .one)
        }
        if !modifiers.isDisjoint(with: [.writeAlpha, .alphaMax]) {
            rt.renderTargetWriteMask = .all
        }
        if modifiers.contains(.alphaMax) {
            rt.blendOpAlpha = .max
            (rt.srcBlendAlpha, rt.destBlendAlpha) = (.one, .one)
        }
        if modifiers.contains(.max) {
            rt.blendOp = .max
        }
        if modifiers.contains(.min) {
            rt.blendOp = .min
        }
        if modifiers.contains(.multiply) {
            rt.srcBlend = .destColor
        }

        return WPEParityBlendState(
            alphaToCoverageEnable: mode == .alphaToCoverage,
            independentBlendEnable: false,
            renderTarget0: rt
        )
    }
}
