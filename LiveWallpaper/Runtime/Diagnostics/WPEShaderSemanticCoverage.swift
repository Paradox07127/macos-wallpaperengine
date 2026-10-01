#if !LITE_BUILD && DEBUG
import Foundation

/// Deliberately scoped to observed custom draws. These counts are not whole-scene fidelity percentages.
struct WPEShaderSemanticCoverage: Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case supported, limited, approximate, missing, unverified
    }

    enum Feature: String, Codable, CaseIterable {
        case fragmentCompilation, authoredVertexExecution, stageLinkDefinition
        case varyingExecution, uniformSupply, textureDeclaration, visualFidelity
    }

    struct Entry: Codable, Equatable {
        let feature: Feature
        let stage: WPEShaderStage?
        let name: String?
        let status: Status
        let reason: String
    }

    let passID: String
    let authoredEffectID: String?
    let shaderName: String
    let sourceClassification: String?
    let sourceFingerprint: String?
    let shaderInterface: WPEShaderInterface?
    let entries: [Entry]

    static func observedCustomDraw(
        passID: String, authoredEffectID: String? = nil, shaderName: String,
        sourceClassification: String?, sourceFingerprint: String?,
        interface: WPEShaderInterface?, layout: [WPEUniformSlot], sources: [WPEUniformValueSource]?,
        vertexLayout: [WPEUniformSlot] = [], vertexSources: [WPEUniformValueSource]? = nil,
        authoredVertexExecuted: Bool = false, authoredVertexFallback: String? = nil, authoredObjectQuadExecuted: Bool = false
    ) -> Self {
        var entries: [Entry] = [
            .init(feature: .fragmentCompilation, stage: .fragment, name: nil, status: .supported,
                  reason: "metal-library-compiled"),
            .init(feature: .authoredVertexExecution, stage: .vertex, name: nil,
                  status: authoredVertexExecuted ? .limited : (interface?.hasVertexSource == true ? .missing : .unverified),
                  reason: authoredVertexExecuted ? (authoredObjectQuadExecuted ? "authored-model-pixel-quad-stage-executed" : "authored-fullscreen-stage-executed") : (authoredVertexFallback ?? (interface?.hasVertexSource == true ? "builtin-vertex-with-fragment-reconstruction" : "authored-vertex-source-unavailable"))),
            .init(feature: .visualFidelity, stage: nil, name: nil, status: .unverified,
                  reason: "compilation-and-source-selection-do-not-prove-image-equivalence"),
        ]
        if let interface {
            entries.append(.init(feature: .stageLinkDefinition, stage: nil, name: nil,
                                 status: interface.issues.isEmpty ? .supported : .limited,
                                 reason: interface.issues.isEmpty ? "declarations-linked" : "authored-interface-has-issues"))
            for variable in interface.variables {
                switch variable.kind {
                case .varyingInput:
                    let unreferenced = interface.unreferencedFragmentInputs?.contains(variable.key.name) == true
                    entries.append(.init(feature: .varyingExecution, stage: .fragment, name: variable.key.name,
                                         status: unreferenced ? .unverified : (authoredVertexExecuted ? .supported : .approximate),
                                         reason: unreferenced ? "declaration-only-no-active-reference" : (authoredVertexExecuted ? "authored-vertex-raster-interpolation" : "fragment-reconstruction-not-authored-vertex-interpolation")))
                case .uniform where variable.key.stage == .vertex && !authoredVertexExecuted:
                    entries.append(.init(feature: .uniformSupply, stage: .vertex, name: variable.key.name,
                                         status: .unverified, reason: "authored-stage-not-executed-declaration-is-not-a-read"))
                case .texture:
                    entries.append(.init(feature: .textureDeclaration, stage: variable.key.stage, name: variable.key.name,
                                         status: .unverified, reason: "declaration-is-not-optimized-resource-consumption"))
                default: break
                }
            }
        } else {
            entries.append(.init(feature: .stageLinkDefinition, stage: nil, name: nil,
                                 status: .unverified, reason: "authored-interface-unavailable"))
        }
        let stages: [(WPEShaderStage, [WPEUniformSlot], [WPEUniformValueSource]?)] = [(.fragment, layout, sources)]
            + (authoredVertexExecuted ? [(.vertex, vertexLayout, vertexSources)] : [])
        for (stage, stageLayout, stageSources) in stages {
            for (index, uniform) in stageLayout.enumerated() {
                let status: Status
                let reason: String
                if let sources = stageSources, sources.count == stageLayout.count {
                    switch sources[index] {
                    case .missing:
                        // Only known engine inputs require a host producer. An unknown material field
                        // without an authored default remains unspecified, rather than a claimed defect.
                        let required = uniform.materialName == nil && requiresHostProducer(uniform.name)
                        status = required ? .missing : .unverified
                        reason = required ? "required-host-producer-missing" : "no-authored-default-or-recorded-value"
                    case .fullscreenVertexMVP:
                        status = .limited
                        reason = "native-fullscreen-XY-position-only-depth-disabled"
                    case .effectModelViewProjectionXYW:
                        status = .limited
                        reason = "normalized-effect-position-XYW-2D-only"
                    case .unreferencedEngineDeclaration:
                        status = .unverified
                        reason = "declaration-only-no-admitted-read"
                    case .authoredDefault:
                        status = .supported
                        reason = "authored-default-supplied"
                    default:
                        status = .supported
                        reason = "runtime-source-recorded"
                    }
                } else {
                    status = .unverified
                    reason = "uniform-provenance-unrecorded"
                }
                entries.append(.init(feature: .uniformSupply, stage: stage, name: uniform.name, status: status, reason: reason))
            }
        }
        return Self(passID: passID, authoredEffectID: authoredEffectID, shaderName: shaderName,
                    sourceClassification: sourceClassification, sourceFingerprint: sourceFingerprint,
                    shaderInterface: interface, entries: entries)
    }

    private static func requiresHostProducer(_ name: String) -> Bool {
        if WPEFrameUniformContext.canonicalNames.contains(name) {
            return true
        }
        if ["g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse",
            "g_EffectModelMatrix", "g_EffectModelMatrixInverse", "g_EffectModelViewProjectionMatrix", "g_TexelSize", "g_TexelSizeHalf", "g_Screen"].contains(name) {
            return true
        }
        return name.range(of: #"^g_Texture[0-9]+(?:Resolution|Rotation|Translation)$"#, options: .regularExpression) != nil
    }

    struct Summary: Codable, Equatable {
        struct Count: Codable, Equatable {
            let feature: Feature
            let status: Status
            let entries: Int
            let affectedPasses: Int
        }

        let scope: String
        let observedDraws: Int
        let uniquePasses: Int
        let observedEntries: Int
        let counts: [Count]

        init(_ draws: [WPEShaderSemanticCoverage]) {
            scope = "observed-custom-draws-only"
            observedDraws = draws.count
            uniquePasses = Set(draws.map(\.passID)).count
            observedEntries = draws.reduce(0) { $0 + $1.entries.count }
            counts = Feature.allCases.flatMap { feature in
                Status.allCases.compactMap { status in
                    let matched = draws.map { draw in
                        (draw.passID, draw.entries.filter { $0.feature == feature && $0.status == status }.count)
                    }.filter { $0.1 > 0 }
                    guard !matched.isEmpty else { return nil }
                    return Count(feature: feature, status: status, entries: matched.reduce(0) { $0 + $1.1 },
                                 affectedPasses: Set(matched.map(\.0)).count)
                }
            }
        }
    }

    func jsonObject() -> [String: Any] {
        Self.jsonObject(self)
    }

    static func jsonObject(_ value: some Encodable) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var versioned = object
        versioned["schema"] = "wpe.semantic-coverage.v1"
        versioned["interfaceVersion"] = WPEShaderInterface.version
        return versioned
    }
}
#endif
