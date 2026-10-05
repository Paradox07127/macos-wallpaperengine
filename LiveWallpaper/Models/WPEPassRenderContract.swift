#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

enum WPEAttachmentCoverageContract: Equatable, Sendable {
    case opaqueScene, transparentIntermediate

    init(_ target: WPEMetalTargetID) {
        self = target == .scene ? .opaqueScene : .transparentIntermediate
    }

    var alphaWritePolicy: WPEMetalAlphaWritePolicy {
        self == .opaqueScene ? .rgbOnly : .all
    }

    var clearAlpha: Double {
        self == .opaqueScene ? 1 : 0
    }
}

struct WPEPassContractIdentity: Equatable, Sendable {
    let shader: String
    let builtin: Bool
    let blending: String
    let target: WPERenderTarget
    let references: [Int: WPETextureReference]
    let alphaOverride: WPEShaderAlphaContract?
}

struct WPEPassRenderContract: Equatable, Sendable {
    let identity: WPEPassContractIdentity
    let inputs: [Int: WPEPassInputContract]
    let shaderAlpha: WPEShaderAlphaContract
    let nativeAlpha: WPENativeAlphaPolicy
    let blend: WPEBlendContract
    let attachment: WPEAttachmentCoverageContract
    let emitted: WPEResourceSemantics
    let stored: WPEResourceSemantics
    let diagnostics: [String]
    let outputDeclaration: WPEResourceSemantics?

    static func resolve(
        pass: WPERenderPass, shader: WPEShaderProgram?, bindings: [Int: WPETextureReference],
        alphaOverride: WPEShaderAlphaContract?, inputDeclarations: [Int: WPEPassInputContract] = [:],
        outputDeclaration: WPEResourceSemantics? = nil
    ) -> Self {
        var references = pass.textures
        references.merge(pass.binds) { _, override in override }
        references.merge(bindings) { _, override in override }
        if references[0] == nil {
            references[0] = pass.source
        }
        var diagnostics: [String] = []
        let blend = WPEBlendContract(pass.blending)
        if !blend.recognized {
            diagnostics.append("unrecognized-blend:" + pass.blending)
        }
        let attachment = WPEAttachmentCoverageContract(WPEMetalTargetID(target: pass.target))
        let inputs = references.mapValues { _ in WPEResourceSemantics.unknown }
        var resolved: [Int: WPEPassInputContract] = [:]
        for slot in inputs.keys.sorted() {
            guard let reference = references[slot] else { continue }
            if let declaration = inputDeclarations[slot], declaration.reference == reference {
                resolved[slot] = declaration
            } else {
                switch reference {
                case .image, .asset:
                    resolved[slot] = .init(reference: reference, semantics: .straightColor, origin: .externalImage)
                case .previous where pass.target == .scene:
                    resolved[slot] = .init(reference: reference, semantics: .opaqueColor, origin: .producer)
                case .fbo, .previous:
                    resolved[slot] = .init(reference: reference, semantics: .unknown, origin: .compatibility)
                }
            }
            let usage = textureUsage(shader: pass.shader, slot: slot, program: shader)
            if usage.isData, let input = resolved[slot] {
                resolved[slot] = .init(reference: reference, semantics: .data(usage), origin: .declaration)
            }
            if resolved[slot]?.semantics.alpha == .unknown {
                diagnostics.append("unverified-input:\(slot):\(reference.contractKey)")
            }
        }
        var pmaInputs = Set<Int>()
        for (slot, input) in resolved where slot < WPEShaderTranspiler.customTextureSlotLimit {
            switch input.semantics.alpha {
            case .premultiplied: pmaInputs.insert(slot)
            case .unknown:
                if case .fbo = input.reference {
                    pmaInputs.insert(slot)
                }
                if case .previous = input.reference {
                    pmaInputs.insert(slot)
                }
            default: break
            }
        }
        let native = shader?.isBuiltin != false
        let kind = WPEBuiltinShaderKind(normalizing: pass.shader)
        let isImage = kind == .genericImage2 || kind == .genericImage4
        let isCopy = kind == .copy
        var pmaOutput = alphaOverride?.premultipliedOutput ?? (native ? kind != .solidColor && !isCopy : blend.shaderPremultiplication)
        if let outputDeclaration, outputDeclaration.alpha == .data || outputDeclaration.alpha == .independent {
            pmaOutput = false
        }
        if let alphaOverride {
            if !native, resolved.contains(where: { slot, input in
                input.semantics.alpha == .premultiplied && !alphaOverride.unpremultipliedInputSlots.contains(slot)
                    || input.semantics.alpha == .straight && alphaOverride.unpremultipliedInputSlots.contains(slot)
            }) {
                diagnostics.append("input-alpha-override-requires-verification")
            }
            pmaInputs = alphaOverride.unpremultipliedInputSlots
        }
        // An explicit data declaration cannot be reinterpreted as coverage by a compatibility rule.
        for (slot, input) in resolved where input.semantics.alpha == .data || input.semantics.alpha == .independent {
            pmaInputs.remove(slot)
        }
        let primary = resolved[0]?.semantics ?? .unknown
        var emitted = outputDeclaration ?? (pmaOutput ? .premultipliedColor : .straightColor)
        var operation = WPENativeInputAlphaOperation.none
        if native {
            if isCopy {
                emitted = primary
                let requiresCopyPremultiplication = primary.alpha == .straight || primary == .textEffectCarrier
                if requiresCopyPremultiplication, blend.enabled, blend.shaderPremultiplication {
                    operation = .premultiply
                    emitted = .premultipliedColor
                } else if primary.alpha == .premultiplied, blend.enabled, blend.sourceRGB == .sourceAlpha {
                    operation = .unpremultiply
                    emitted = .straightColor
                }
                pmaOutput = false
            } else if isImage, primary.alpha == .premultiplied {
                operation = .unpremultiply
            } else if let kind, kind.rawValue.hasPrefix("effect_"), primary.alpha == .straight,
                      outputDeclaration?.alpha != .data, outputDeclaration?.alpha != .independent {
                operation = .premultiply
            }
            if !isImage, !isCopy, alphaOverride?.premultipliedOutput == false, kind != .solidLayer, kind != .solidColor {
                diagnostics.append("native-output-override-requires-verification")
            }
        }
        if native, kind == nil, outputDeclaration == nil {
            emitted = .unknown
            diagnostics.append("unverified-native-output")
        }
        let shaderAlpha = WPEShaderAlphaContract(unpremultipliedInputSlots: pmaInputs, premultipliedOutput: pmaOutput)
        let stored: WPEResourceSemantics
        if attachment == .opaqueScene {
            stored = .opaqueColor
        } else if emitted.alpha == .unknown {
            stored = .unknown
            diagnostics.append("unverified-output-representation")
        } else if emitted.alpha == .data || emitted.alpha == .independent || !blend.enabled {
            stored = emitted
        } else if blend.destinationRGB == .one && emitted.usage == .additive {
            stored = emitted
        } else if blend.sourceRGB == .sourceAlpha || blend.shaderPremultiplication {
            stored = .premultipliedColor
        } else {
            stored = .unknown
            diagnostics.append("unverified-blended-output")
        }
        if emitted.alpha == .premultiplied, blend.enabled, blend.sourceRGB == .sourceAlpha {
            diagnostics.append("premultiplied-output-with-source-alpha-blend")
        }
        return Self(identity: .init(shader: pass.shader, builtin: native, blending: pass.blending,
                                    target: pass.target, references: references, alphaOverride: alphaOverride), inputs: resolved, shaderAlpha: shaderAlpha,
                    nativeAlpha: .init(input: operation, straightOutput: !pmaOutput && isImage),
                    blend: blend, attachment: attachment, emitted: emitted, stored: stored,
                    diagnostics: diagnostics, outputDeclaration: outputDeclaration)
    }

    static func textureUsage(shader: String, slot: Int, program: WPEShaderProgram? = nil) -> WPETextureUsage {
        // A direct invocation of the normal decoder proves data use independently of asset names.
        if let program, !program.isBuiltin {
            let pattern = #"\bDecompressNormal\s*\(\s*(?:texture|texture2D|textureLod|textureGrad|texelFetch|texSample2D)\s*\(\s*g_Texture"# + String(slot) + #"\b"#
            if program.fragmentSource.range(of: pattern, options: .regularExpression) != nil {
                return .normal
            }
        }
        guard slot > 0, let kind = WPEBuiltinShaderKind(normalizing: shader) else { return .unknown }
        return switch (kind, slot) {
        case (.genericImage4, 1), (.effectOpacity, 1): .mask
        case (.effectShake, 1): .flow
        default: .unknown
        }
    }

    func matches(pass: WPERenderPass, shader: WPEShaderProgram?, references: [Int: WPETextureReference],
                 alphaOverride: WPEShaderAlphaContract?) -> Bool {
        identity == .init(shader: pass.shader, builtin: shader?.isBuiltin != false,
                          blending: pass.blending, target: pass.target,
                          references: references, alphaOverride: alphaOverride)
    }

    func inputDeclarations(matching references: [Int: WPETextureReference]) -> [Int: WPEPassInputContract] {
        inputs.filter { references[$0.key] == $0.value.reference }
    }
}
#endif
