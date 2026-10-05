#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

enum WPEAlphaAssociation: String, Hashable, Codable, Sendable {
    case unknown, straight, premultiplied, opaque, data, independent
}

enum WPETextureUsage: String, Hashable, Codable, Sendable {
    case unknown, color, mask, normal, flow, lut, additive, glyphDistance

    var isData: Bool {
        switch self {
        case .mask, .normal, .flow, .lut, .glyphDistance: true
        default: false
        }
    }
}

struct WPEResourceSemantics: Equatable, Hashable, Codable, Sendable {
    let alpha: WPEAlphaAssociation
    let usage: WPETextureUsage

    static let unknown = Self(alpha: .unknown, usage: .unknown)
    static let straightColor = Self(alpha: .straight, usage: .color)
    static let premultipliedColor = Self(alpha: .premultiplied, usage: .color)
    static let opaqueColor = Self(alpha: .opaque, usage: .color)
    /// Native effected-text surfaces retain sampled backdrop RGB independently of glyph coverage alpha.
    static let textEffectCarrier = Self(alpha: .independent, usage: .color)
    static let emission = Self(alpha: .independent, usage: .additive)

    static func data(_ usage: WPETextureUsage) -> Self {
        Self(alpha: .data, usage: usage)
    }

    static func tex(_ info: WPETexInfo, usage: WPETextureUsage, luminanceAlpha: Bool) -> Self {
        if usage == .additive {
            return .emission
        }
        if usage.isData {
            return .data(usage)
        }
        switch info.format {
        case .r8: return .data(.mask)
        case .rg88 where !luminanceAlpha: return .data(usage == .unknown ? .flow : usage)
        case .rgba8888, .dxt1, .dxt3, .dxt5, .bc7, .rg88:
            return Self(alpha: .straight, usage: usage == .unknown ? .color : usage)
        default: return .unknown
        }
    }
}

enum WPEContractOrigin: String, Codable, Sendable {
    case producer, declaration, externalImage, compatibility
}

struct WPEPassInputContract: Equatable, Sendable {
    let reference: WPETextureReference
    let semantics: WPEResourceSemantics
    let origin: WPEContractOrigin
}

enum WPENativeInputAlphaOperation: UInt, Hashable, Codable, Sendable {
    case none, premultiply, unpremultiply
}

struct WPENativeAlphaPolicy: Equatable, Hashable, Codable, Sendable {
    let input: WPENativeInputAlphaOperation
    let straightOutput: Bool
    static let compatibility = Self(input: .none, straightOutput: false)
}

extension WPETextureReference {
    var contractKey: String {
        switch self {
        case let .image(name): "image:" + name
        case let .asset(name): "asset:" + name
        case let .fbo(name): "fbo:" + name
        case .previous: "previous"
        }
    }
}
#endif
