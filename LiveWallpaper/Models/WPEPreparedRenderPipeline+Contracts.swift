#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

extension WPEPreparedRenderPipeline {
    func resolvingRenderContracts(
        externalSemantics: (WPETextureReference) -> WPEResourceSemantics? = { _ in nil }
    ) -> Self {
        var resources: [String: WPEResourceSemantics] = [:]
        var declaredTargets: [String: WPEResourceSemantics] = [:]
        for layer in layers {
            for fbo in layer.graphLayer.localFBOs {
                switch fbo.format.lowercased() {
                case "r8": declaredTargets["fbo:" + fbo.name] = .data(.mask)
                case "rg8", "rg88": declaredTargets["fbo:" + fbo.name] = .data(.flow)
                default: break
                }
            }
        }
        resources = declaredTargets
        // Names with a `resources` entry; aliased reads probe these exactly as runtime binding probes written FBOs.
        var fboNames = Set(declaredTargets.keys.map { String($0.dropFirst("fbo:".count)) })
        let resolvedLayers = layers.map { layer in
            let isEffectText = layer.passes.contains { WPETextLayerSynthesis.isGlyphPassShader($0.pass.shader) }
                && layer.passes.contains {
                    if case .effect = $0.pass.phase {
                        return true
                    }
                    return false
                }
            let passes = layer.passes.map { prepared in
                let targetKey = prepared.pass.target.textureReference?.contractKey ?? "scene"
                var inputs = prepared.renderContract.inputs
                for (slot, input) in inputs {
                    let key = input.reference == .previous ? targetKey : input.reference.contractKey
                    let sceneAlias: WPEResourceSemantics? = if case let .fbo(name) = input.reference,
                                                               WPETextureReference.isSceneAliasName(name) {
                        .opaqueColor
                    } else {
                        nil
                    }
                    let producerKey: String? = if resources[key] != nil {
                        key
                    } else if case let .fbo(name) = input.reference, sceneAlias == nil {
                        WPEMetalShaderInputs.fuzzyFBOAlias(for: name, in: fboNames).map { "fbo:" + $0 }
                    } else {
                        nil
                    }
                    let produced = producerKey.flatMap { resources[$0] }
                    let semantics = produced ?? sceneAlias ?? externalSemantics(input.reference)
                    if let semantics {
                        let role = input.semantics.usage
                        inputs[slot] = WPEPassInputContract(
                            reference: input.reference,
                            semantics: role.isData ? .data(role) : semantics,
                            origin: produced == nil ? .declaration : .producer
                        )
                    }
                }
                let resolved = WPEPassRenderContract.resolve(
                    pass: prepared.pass, shader: prepared.shader, bindings: prepared.textureBindings,
                    alphaOverride: prepared.alphaContract, inputDeclarations: inputs,
                    outputDeclaration: declaredTargets[targetKey] ?? prepared.renderContract.outputDeclaration
                        ?? (isEffectText && prepared.pass.target != .scene ? .textEffectCarrier : nil)
                )
                let mixedDestination = resolved.blend.enabled && resolved.blend.destinationRGB != .zero
                    && resources[targetKey].map { $0.alpha != resolved.stored.alpha && $0.alpha != .opaque } == true
                let contract = mixedDestination ? resolved.appendingDiagnostic("mixed-destination-representation") : resolved
                if case let .fbo(name)? = prepared.pass.target.textureReference {
                    fboNames.insert(name)
                }
                if prepared.pass.visibilityGate != nil,
                   declaredTargets[targetKey] == nil,
                   contract.inputs[0]?.semantics.alpha != contract.stored.alpha,
                   prepared.pass.target != .scene {
                    resources[targetKey] = .unknown
                } else {
                    resources[targetKey] = contract.stored
                }
                return prepared.replacingRenderContract(contract)
            }
            return layer.replacing(passes: passes)
        }
        return Self(layers: resolvedLayers)
    }

    var renderContractDiagnostics: [String: [String]] {
        Dictionary(layers.flatMap(\.passes).compactMap { pass in
            pass.renderContract.diagnostics.isEmpty ? nil : (pass.id, pass.renderContract.diagnostics)
        }, uniquingKeysWith: { first, second in first + second })
    }
}

extension WPEPreparedRenderPass {
    func replacingRenderContract(_ contract: WPEPassRenderContract) -> Self {
        guard contract != renderContract else { return self }
        return Self(pass: pass, shader: shader, textureBindings: textureBindings,
                    comboValues: comboValues, uniformValues: uniformValues,
                    materialUniformNames: materialUniformNames, stageUniformBindings: stageUniformBindings,
                    layerTintOverride: layerTintOverride, alphaContract: alphaContract,
                    renderContract: contract, publicationVertexRole: publicationVertexRole, reusingAccess: access)
    }
}
#endif
