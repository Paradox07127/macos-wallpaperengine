#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Prepared, logical dependencies. A revision is a potential write in authored order,
/// not proof that a hidden/gated/failed draw executed. Physical initialization remains
/// a runtime fact; alias lifetimes retain their conservative raw-reference union.
struct WPEAttachmentPlan: Equatable, Sendable {
    struct Version: Equatable, Sendable {
        let target: WPEMetalTargetID
        let revision: Int
        let producer: PassIdentity?
    }

    struct PassIdentity: Equatable, Sendable {
        let objectID: String
        let passID: String
        let stableEffectID: String?
    }

    enum Source: Equatable, Sendable {
        case external(WPETextureReference)
        case clearedBootstrap(WPEMetalTargetID)
        case privateHistory(String)
        case previousSceneFrame
        case unresolvedNamed(String)
        case current(Version)
        case conditionalPrivateHistory(Version, String)
        case sceneSnapshot(Version)
    }

    struct Input: Equatable, Sendable {
        let slot: Int
        let reference: WPETextureReference
        let source: Source
    }

    enum ClosedGate: Equatable, Sendable {
        case noWrite
        case keepTarget
        case copy(Source)
    }

    struct Pass: Equatable, Sendable {
        let identity: PassIdentity
        let inputs: [Input]
        let output: Version
        let readsCurrentTarget: Bool
        let closedGate: ClosedGate?
    }

    let passes: [Pass]
    let historyFBONames: Set<String>
    let targetDeclarations: [WPERenderFBO]

    init(layers: [WPEPreparedRenderLayer]) {
        // Match the pool's last declaration wins policy, including duplicate names.
        var declarations: [String: WPERenderFBO] = [:]
        for layer in layers {
            for fbo in layer.graphLayer.localFBOs {
                declarations[fbo.name] = fbo
            }
        }
        targetDeclarations = declarations.values.sorted { $0.name < $1.name }
        let privateNames = Set(declarations.values.filter {
            $0.unique && !WPETextureReference.isSceneAliasName($0.name)
        }.map(\.name))
        let producedNames = Set(layers.flatMap(\.passes).compactMap { pass -> String? in
            if case let .named(name) = WPEMetalTargetID(target: pass.pass.target) {
                return name
            }
            return nil
        })
        var versions: [WPEMetalTargetID: Version] = [:]
        var definitelyWritten: Set<String> = []
        var planned: [Pass] = []
        var histories: Set<String> = []

        func source(_ reference: WPETextureReference, target: WPEMetalTargetID) -> Source {
            switch reference {
            case .image, .asset: return .external(reference)
            case .previous:
                // This token denotes target/chain input, not implicit temporal carry.
                if let version = versions[target] {
                    return .current(version)
                }
                if case .scene = target {
                    return .previousSceneFrame
                }
                return .clearedBootstrap(target)
            case let .fbo(name):
                let id = WPEMetalTargetID.named(name)
                if let current = versions[id] {
                    if privateNames.contains(name), !definitelyWritten.contains(name) {
                        histories.insert(name)
                        return .conditionalPrivateHistory(current, name)
                    }
                    return .current(current)
                }
                if WPETextureReference.isSceneAliasName(name) {
                    return .sceneSnapshot(versions[.scene] ?? Version(target: .scene, revision: 0, producer: nil))
                }
                if privateNames.contains(name) {
                    return .privateHistory(name)
                }
                return declarations[name] != nil || producedNames.contains(name) ? .clearedBootstrap(id) : .unresolvedNamed(name)
            }
        }

        for layer in layers {
            for pass in layer.passes {
                let target = WPEMetalTargetID(target: pass.pass.target)
                let identity = PassIdentity(objectID: layer.graphLayer.objectID, passID: pass.pass.id,
                                            stableEffectID: pass.pass.authoredJSON.effectIdentity?.stableEffectID)
                let inputs = pass.access.resolvedBindings.sorted { $0.key < $1.key }.map { slot, reference in
                    Input(slot: slot, reference: reference, source: source(reference, target: target))
                }
                let gate: ClosedGate? = if pass.pass.visibilityGate != nil {
                    if case .layerComposite = pass.pass.target {
                        pass.pass.source == .previous ? .keepTarget : .copy(source(pass.pass.source, target: target))
                    } else {
                        .noWrite
                    }
                } else {
                    nil
                }
                for input in inputs {
                    if case let .privateHistory(name) = input.source {
                        histories.insert(name)
                    }
                }
                if case let .copy(.privateHistory(name)) = gate {
                    histories.insert(name)
                }
                let output = Version(target: target, revision: (versions[target]?.revision ?? 0) + 1, producer: identity)
                planned.append(Pass(identity: identity, inputs: inputs, output: output,
                                    readsCurrentTarget: pass.access.readsCurrentTarget, closedGate: gate))
                versions[target] = output
                if case let .named(name) = target, pass.pass.visibilityGate == nil,
                   !WPERenderTargetNames.LayerGroup.matches(name) {
                    definitelyWritten.insert(name)
                }
            }
        }
        passes = planned
        historyFBONames = histories
    }
}

#if DEBUG
extension WPEAttachmentPlan {
    func traceRecord() -> [String: Any] {
        func target(_ id: WPEMetalTargetID) -> String {
            switch id {
            case .scene: "scene"
            case let .named(name): "named:" + name
            }
        }
        func identity(_ value: PassIdentity) -> [String: Any] {
            ["objectID": value.objectID, "passID": value.passID, "stableEffectID": value.stableEffectID ?? NSNull()]
        }
        func version(_ value: Version) -> [String: Any] {
            ["target": target(value.target), "potentialRevision": value.revision, "producer": value.producer.map(identity) ?? NSNull()]
        }
        func source(_ value: Source) -> [String: Any] {
            switch value {
            case let .external(reference): ["kind": "external", "reference": String(describing: reference)]
            case let .clearedBootstrap(id): ["kind": "bootstrap", "target": target(id)]
            case let .privateHistory(name): ["kind": "privateHistory", "name": name, "firstFrame": "cleared-bootstrap"]
            case .previousSceneFrame: ["kind": "previousSceneFrame", "firstFrame": "cleared-bootstrap"]
            case let .unresolvedNamed(name): ["kind": "unresolvedNamed", "name": name]
            case let .current(value): ["kind": "potentialCurrent", "version": version(value)]
            case let .conditionalPrivateHistory(value, name):
                ["kind": "conditionalCurrent", "version": version(value), "fallback": ["kind": "privateHistory", "name": name]]
            case let .sceneSnapshot(value): ["kind": "sceneSnapshot", "version": version(value)]
            }
        }
        return [
            "schema": "wpe.attachment-plan.v1", "scope": "prepared-layer-passes",
            "execution": "potential-dependencies-not-observed-writes", "historyFBONames": historyFBONames.sorted(),
            "targetDeclarations": targetDeclarations.map { fbo -> [String: Any] in
                ["name": fbo.name, "authoredFormat": fbo.format, "scaleDivisor": fbo.scale,
                 "fit": fbo.fit.map { $0 as Any } ?? NSNull(), "unique": fbo.unique,
                 "pixelSize": fbo.pixelSize.map { [$0.width, $0.height] as Any } ?? NSNull(),
                 "allocationPolicy": historyFBONames.contains(fbo.name) ? "outside-frame-alias-plan" : "existing-alias-planner",
                 "resolvedExtentAndFormat": "physical-operation-resources"]
            },
            "passes": passes.map { pass -> [String: Any] in
                var record: [String: Any] = [
                    "identity": identity(pass.identity), "output": version(pass.output), "readsCurrentTarget": pass.readsCurrentTarget,
                    "inputs": pass.inputs.map { ["slot": $0.slot, "reference": String(describing: $0.reference), "source": source($0.source)] },
                ]
                if let gate = pass.closedGate {
                    record["closedGate"] = switch gate {
                    case .noWrite: ["kind": "noWrite"]
                    case .keepTarget: ["kind": "keepTarget"]
                    case let .copy(input): ["kind": "copy", "input": source(input)]
                    }
                }
                return record
            },
        ]
    }
}
#endif
#endif
