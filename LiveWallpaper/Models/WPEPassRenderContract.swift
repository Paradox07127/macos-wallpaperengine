#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import os

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
        let key = WPEPassContractMemo.Key(
            shader: pass.shader, blending: pass.blending, target: pass.target, references: references,
            customSource: shader?.isBuiltin == false ? shader?.sourceFingerprint : nil, alphaOverride: alphaOverride,
            inputDeclarations: inputDeclarations, outputDeclaration: outputDeclaration
        )
        return WPEPassContractMemo.current.contract(for: key) {
            uncached(pass: pass, shader: shader, references: references, alphaOverride: alphaOverride,
                     inputDeclarations: inputDeclarations, outputDeclaration: outputDeclaration)
        }
    }

    private static func uncached(
        pass: WPERenderPass, shader: WPEShaderProgram?, references: [Int: WPETextureReference],
        alphaOverride: WPEShaderAlphaContract?, inputDeclarations: [Int: WPEPassInputContract],
        outputDeclaration: WPEResourceSemantics?
    ) -> Self {
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
                let isDataOutput = outputDeclaration?.alpha == .data
                emitted = outputDeclaration ?? primary
                let requiresCopyPremultiplication = primary.alpha == .straight || primary == .textEffectCarrier
                if !isDataOutput, requiresCopyPremultiplication, blend.enabled, blend.shaderPremultiplication {
                    operation = .premultiply
                    emitted = .premultipliedColor
                } else if !isDataOutput, primary.alpha == .premultiplied, blend.enabled, blend.sourceRGB == .sourceAlpha {
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
        let straightOutput = !pmaOutput && (isImage || kind == .effectOpacity && primary == .textEffectCarrier)
        return Self(identity: .init(shader: pass.shader, builtin: native, blending: pass.blending,
                                    target: pass.target, references: references, alphaOverride: alphaOverride), inputs: resolved, shaderAlpha: shaderAlpha,
                    nativeAlpha: .init(input: operation, straightOutput: straightOutput,
                                       independentCoverageInput: native && kind == .effectOpacity && primary == .textEffectCarrier),
                    blend: blend, attachment: attachment, emitted: emitted, stored: stored,
                    diagnostics: diagnostics, outputDeclaration: outputDeclaration)
    }

    static func textureUsage(shader: String, slot: Int, program: WPEShaderProgram? = nil) -> WPETextureUsage {
        if let program, !program.isBuiltin {
            let roles = WPEPassContractMemo.current.roles(for: program)
            if roles.decodedNormals.contains(slot) {
                return .normal
            }
            // Custom `effects/*` sources share builtin names, so their own annotation outranks the name table.
            if let annotated = roles.annotated[slot] {
                return annotated
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

    func appendingDiagnostic(_ diagnostic: String) -> Self {
        Self(identity: identity, inputs: inputs, shaderAlpha: shaderAlpha, nativeAlpha: nativeAlpha, blend: blend,
             attachment: attachment, emitted: emitted, stored: stored, diagnostics: diagnostics + [diagnostic],
             outputDeclaration: outputDeclaration)
    }
}

/// Sampler roles a custom fragment program proves or declares in its active source.
struct WPEShaderSourceRoles: Sendable {
    let decodedNormals: Set<Int>
    /// Slots whose sampler carries a parseable JSON annotation; `.unknown` when it names no data role.
    let annotated: [Int: WPETextureUsage]

    init(fragmentSource: String) {
        let active = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: fragmentSource)
        let code = WPEShaderTranspiler.maskComments(active)
        let decoder = #/\bDecompressNormal\s*\(\s*(?:texture|texture2D|textureLod|textureGrad|texelFetch|texSample2D)\s*\(\s*g_Texture(\d+)\b/#
        decodedNormals = Set(code.matches(of: decoder).compactMap { Int($0.output.1) })
        let declaration = #/\s*uniform\s+sampler2D\s+g_Texture(\d+)\s*;/#
        var annotated: [Int: WPETextureUsage] = [:]
        for (line, masked) in zip(active.components(separatedBy: "\n"), code.components(separatedBy: "\n")) {
            guard masked.prefixMatch(of: declaration) != nil, let match = line.prefixMatch(of: declaration),
                  let slot = Int(match.output.1) else { continue }
            let comment = line[match.range.upperBound...]
            guard let start = comment.firstIndex(of: "{"), let end = comment.lastIndex(of: "}"),
                  let object = try? JSONSerialization.jsonObject(with: Data(comment[start ... end].utf8)),
                  let metadata = object as? [String: Any] else { continue }
            annotated[slot] = switch (metadata["mode"] as? String, metadata["format"] as? String) {
            case ("opacitymask", _): .mask
            case ("flowmask", _): .flow
            case (_, "normalmap"): .normal
            default: .unknown
            }
        }
        self.annotated = annotated
    }
}

/// Process-wide memo of pure contract inputs; render threads share it and `state`'s lock orders every access.
final class WPEPassContractMemo: Sendable {
    @TaskLocal static var current = WPEPassContractMemo()

    struct Key: Hashable, Sendable {
        let shader: String
        let blending: String
        let target: WPERenderTarget
        let references: [Int: WPETextureReference]
        /// Fragment/vertex fingerprint of a custom program; nil for builtin or absent programs.
        let customSource: String?
        let alphaOverride: WPEShaderAlphaContract?
        let inputDeclarations: [Int: WPEPassInputContract]
        let outputDeclaration: WPEResourceSemantics?

        func hash(into hasher: inout Hasher) {
            hasher.combine(shader)
            hasher.combine(blending)
            hasher.combine(target.textureReference?.contractKey)
            hasher.combine(customSource)
            hasher.combine(outputDeclaration)
            for slot in references.keys.sorted() {
                hasher.combine(slot)
                hasher.combine(references[slot]?.contractKey)
            }
        }
    }

    private struct State {
        var contracts: [Key: WPEPassRenderContract] = [:]
        var roles: [String: WPEShaderSourceRoles] = [:]
        var resolutions = 0
    }

    private static let limit = 4096
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Contracts computed rather than served from the memo.
    var resolutions: Int {
        state.withLock { $0.resolutions }
    }

    func contract(for key: Key, resolve: () -> WPEPassRenderContract) -> WPEPassRenderContract {
        if let cached = state.withLock({ $0.contracts[key] }) {
            return cached
        }
        let contract = resolve()
        state.withLock { state in
            if state.contracts.count >= Self.limit {
                state.contracts.removeAll(keepingCapacity: true)
            }
            state.contracts[key] = contract
            state.resolutions += 1
        }
        return contract
    }

    func roles(for program: WPEShaderProgram) -> WPEShaderSourceRoles {
        guard let fingerprint = program.sourceFingerprint else {
            return WPEShaderSourceRoles(fragmentSource: program.fragmentSource)
        }
        if let cached = state.withLock({ $0.roles[fingerprint] }) {
            return cached
        }
        let roles = WPEShaderSourceRoles(fragmentSource: program.fragmentSource)
        state.withLock { state in
            if state.roles.count >= Self.limit {
                state.roles.removeAll(keepingCapacity: true)
            }
            state.roles[fingerprint] = roles
        }
        return roles
    }
}
#endif
