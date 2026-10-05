#if !LITE_BUILD
import Foundation
import Metal

/// Shader alpha transforms are independent of texture RGB transfer and target blend state.
struct WPEShaderAlphaContract: Equatable, Sendable {
    let unpremultipliedInputSlots: Set<Int>
    let premultipliedOutput: Bool
}

/// Format facts describe hardware operations, never the authored color encoding or shader intent.
struct WPEPixelColorContract: Codable, Equatable, Sendable {
    enum Storage: String, Codable, Sendable { case normalized, floatingPoint, unknown }
    enum RGBTransfer: String, Codable, Sendable { case identity, sRGB, unknown }

    let pixelFormat: UInt
    let storage: Storage
    let hardwareRGBTransfer: RGBTransfer
    let alphaTransfer: String

    init(_ format: MTLPixelFormat) {
        pixelFormat = format.rawValue
        switch format {
        case .rgba8Unorm_srgb, .bgra8Unorm_srgb, .bc1_rgba_srgb, .bc2_rgba_srgb, .bc3_rgba_srgb, .bc7_rgbaUnorm_srgb:
            storage = .normalized
            hardwareRGBTransfer = .sRGB
        case .r8Unorm, .rg8Unorm, .rgba8Unorm, .bgra8Unorm, .rgb10a2Unorm,
             .bc1_rgba, .bc2_rgba, .bc3_rgba, .bc7_rgbaUnorm:
            storage = .normalized
            hardwareRGBTransfer = .identity
        case .r16Float, .rg16Float, .rgba16Float, .r32Float, .rg32Float, .rgba32Float:
            storage = .floatingPoint
            hardwareRGBTransfer = .identity
        default:
            storage = .unknown
            hardwareRGBTransfer = .unknown
        }
        alphaTransfer = hardwareRGBTransfer == .unknown ? "unverified" : "identity"
    }

    func jsonObject() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
}

#if DEBUG
struct WPEPassColorContract: Codable {
    struct Input: Codable {
        let authoredSlot: Int
        let metalSlot: Int
        let name: String?
        let view: WPEPixelColorContract?
        let shaderAlphaOperation: String
        let resourceSemantics: WPEResourceSemantics?
        let declaredSemantics: WPEResourceSemantics?
        let contractOrigin: WPEContractOrigin?
    }

    struct Blend: Codable {
        let api: String
        let enabled: Bool
        let sourceRGB: UInt
        let destinationRGB: UInt
        let sourceAlpha: UInt
        let destinationAlpha: UInt
        let rgbOperation: UInt
        let alphaOperation: UInt
        let metalWriteMask: UInt
    }

    let emittedSemantics: WPEResourceSemantics?
    let storedSemantics: WPEResourceSemantics?
    let nativeAlpha: WPENativeAlphaPolicy?
    let clearAlpha: Double?
    let diagnostics: [String]
    let schema: String
    let inputs: [Input]
    /// Alpha association the attachment receives, independent of how the shader produced it.
    let shaderOutputRepresentation: String
    let shaderOutputAlphaOperation: String
    let attachmentSourceRangeOperation: String
    let attachment: WPEPixelColorContract
    let blend: Blend
    /// No texture format proves the source asset encoding, explicit shader transfer or display transfer.
    let authoredRGBEncoding: String
    let shaderRGBArithmetic: String
    let finalDisplayTransfer: String

    init(
        textureBindings: [WPECanonicalTraceRecorder.TextureBindingInput], alpha: WPEShaderAlphaContract?,
        target: MTLTexture, nativeState: WPECanonicalTraceRecorder.NativeRenderState,
        resolved: WPEPassRenderContract? = nil, builtin: Bool = false
    ) {
        schema = "wpe.pass-color-contract.v2"
        emittedSemantics = resolved?.emitted
        storedSemantics = resolved?.stored
        nativeAlpha = builtin ? resolved?.nativeAlpha : nil
        clearAlpha = resolved?.attachment.clearAlpha
        diagnostics = resolved?.diagnostics ?? []
        inputs = textureBindings.sorted { $0.slot < $1.slot }.map { binding in
            let authored = binding.slot
            let operation: String = if builtin, let resolved {
                authored == 0 ? resolved.nativeAlpha.input.rawValue == 0 ? "none"
                    : resolved.nativeAlpha.input == .premultiply ? "premultiply-after-sampling" : "unpremultiply-after-sampling" : "none"
            } else if let alpha {
                alpha.unpremultipliedInputSlots.contains(authored) ? "unpremultiply-after-sampling" : "no-injected-unpremultiply"
            } else {
                "unverified"
            }
            return Input(authoredSlot: authored, metalSlot: binding.slot, name: binding.name,
                         view: binding.texture.map { WPEPixelColorContract($0.pixelFormat) }, shaderAlphaOperation: operation,
                         resourceSemantics: binding.texture.map { WPEMetalTextureMetadataRegistry.shared.semantics(for: $0) },
                         declaredSemantics: resolved?.inputs[authored]?.semantics, contractOrigin: resolved?.inputs[authored]?.origin)
        }
        shaderOutputRepresentation = if builtin, let resolved {
            resolved.emitted.alpha.rawValue
        } else {
            alpha.map { $0.premultipliedOutput ? "premultiplied" : "straight" } ?? "unverified"
        }
        // No per-builtin metadata proves what a native kernel does to its output; only translated injection is known.
        shaderOutputAlphaOperation = if builtin {
            "unverified"
        } else {
            alpha.map { $0.premultipliedOutput ? "premultiply-before-attachment" : "no-injected-premultiply" } ?? "unverified"
        }
        attachment = WPEPixelColorContract(target.pixelFormat)
        attachmentSourceRangeOperation = switch attachment.storage {
        case .normalized: "clamp-source-rgba-before-blend"
        case .floatingPoint: "retain-source-range-before-blend"
        case .unknown: "unverified"
        }
        let state = nativeState.attachment
        blend = Blend(api: "metal", enabled: state.isBlendingEnabled, sourceRGB: state.sourceRGBBlendFactor.rawValue,
                      destinationRGB: state.destinationRGBBlendFactor.rawValue, sourceAlpha: state.sourceAlphaBlendFactor.rawValue,
                      destinationAlpha: state.destinationAlphaBlendFactor.rawValue, rgbOperation: state.rgbBlendOperation.rawValue,
                      alphaOperation: state.alphaBlendOperation.rawValue, metalWriteMask: state.writeMask.rawValue)
        authoredRGBEncoding = "unverified"
        shaderRGBArithmetic = "authored-sample-numbers-with-explicit-shader-transfers"
        finalDisplayTransfer = "outside-pass-contract"
    }

    func jsonObject() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
}
#endif
#endif
