#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

enum WPEShaderConsumerDisposition: String, Equatable, Sendable {
    case noRuntimeTextureProviderConsumer = "no-runtime-texture-provider-consumer"
}

struct WPEShaderImplementationInventoryEntry: Equatable, Sendable {
    let stableEffectID: String
    let stablePassID: String
    let authoredOverrideID: Int?
    let renderPassID: String?
    let authoredEffectPath: String
    let authoredShaderPath: String?
    let classification: WPEShaderExecutionClassification
    let consumerDisposition: WPEShaderConsumerDisposition
    let metadataKind: String
    let metadataSources: [String]

    var stableKey: String {
        [stableEffectID, stablePassID, renderPassID ?? "", metadataKind]
            .joined(separator: "|")
    }
}

enum WPEShaderImplementationInventory {
    /// `$mediaThumbnail`, `$mediaPreviousThumbnail` and `type: usershortcut` have a runtime consumer; only declarations without one go in the unsupported-metadata inventory.
    static func containsUnsupportedUserTexture(
        _ bindings: [WPESceneUserTextureBinding]
    ) -> Bool {
        bindings.contains {
            WPEMediaSystemTexture(bindingName: $0.name) == nil && $0.type?.lowercased() != "usershortcut"
        }
    }

    static func merging(
        _ current: [WPEShaderImplementationInventoryEntry],
        with resolved: [WPEShaderImplementationInventoryEntry]
    ) -> [WPEShaderImplementationInventoryEntry] {
        guard !resolved.isEmpty else { return current }
        let resolvedLoci = Set(resolved.map {
            [$0.stableEffectID, $0.stablePassID, $0.metadataKind].joined(separator: "|")
        })
        var result = current.filter { entry in
            !(entry.renderPassID == nil && resolvedLoci.contains(
                [entry.stableEffectID, entry.stablePassID, entry.metadataKind].joined(separator: "|")
            ))
        }
        var seen = Set(result.map(\.stableKey))
        result.append(contentsOf: resolved.filter { seen.insert($0.stableKey).inserted })
        return result
    }

    static func preflightEntries(
        document: WPESceneDocument
    ) -> [WPEShaderImplementationInventoryEntry] {
        document.imageObjects.flatMap { object in
            object.effects.flatMap { effect in
                effect.passOverrides.enumerated().compactMap { index, override in
                    guard containsUnsupportedUserTexture(override.userTextures) else { return nil }
                    let identity = WPERenderEffectPassIdentity(
                        objectID: object.id,
                        authoredEffectID: effect.id,
                        authoredEffectPath: effect.fileRelativePath,
                        effectPassIndex: index,
                        authoredOverrideID: override.id
                    )
                    return WPEShaderImplementationInventoryEntry(
                        stableEffectID: identity.stableEffectID,
                        stablePassID: identity.stablePassID,
                        authoredOverrideID: identity.authoredOverrideID,
                        renderPassID: nil,
                        authoredEffectPath: identity.authoredEffectPath,
                        // The scene document names the effect asset, not the nested material shader; graph resolution fills this.
                        authoredShaderPath: nil,
                        classification: .unsupportedMetadataOnly,
                        consumerDisposition: .noRuntimeTextureProviderConsumer,
                        metadataKind: "usertextures",
                        metadataSources: ["effect-override"]
                    )
                }
            }
        }
    }

    /// `substitutesMedia(shader)`: whether the runtime route for that shader name swaps `$media*` slots.
    /// Both route predicates live in Runtime, which Infrastructure must not name, so they are passed in.
    static func graphEntries(
        graph: WPERenderGraph,
        substitutesMedia: (String) -> Bool,
        substitutesUserShortcutIcon: (WPERenderPass, WPERenderLayer, Int) -> Bool
    ) -> [WPEShaderImplementationInventoryEntry] {
        graph.layers.flatMap { layer in
            layer.passes.compactMap { pass in
                let identity = pass.authoredJSON.effectIdentity
                guard !pass.userTextureBindings.isEmpty,
                      identity != nil || pass.phase == .material else {
                    return nil
                }
                let mediaConsumed = substitutesMedia(pass.shader)
                func unconsumed(_ bindings: [WPESceneUserTextureBinding]) -> Bool {
                    bindings.contains { binding in
                        if WPEMediaSystemTexture(bindingName: binding.name) != nil {
                            return !mediaConsumed
                        }
                        // The runtime icon demand skips slot-less bindings, so they never get an icon.
                        guard binding.type?.lowercased() == "usershortcut", let slot = binding.slot else { return true }
                        return !substitutesUserShortcutIcon(pass, layer, slot)
                    }
                }
                var sources: [String] = []
                if unconsumed(pass.userTextureBindings.material) {
                    sources.append("effect-material")
                }
                if unconsumed(pass.userTextureBindings.pass) {
                    sources.append("material-pass")
                }
                if unconsumed(pass.userTextureBindings.override) {
                    sources.append("effect-override")
                }
                guard !sources.isEmpty else { return nil }
                return WPEShaderImplementationInventoryEntry(
                    stableEffectID: identity?.stableEffectID ?? "\(layer.objectID):material",
                    stablePassID: identity?.stablePassID ?? "\(layer.objectID):material:\(pass.id)",
                    authoredOverrideID: identity?.authoredOverrideID,
                    renderPassID: pass.id,
                    authoredEffectPath: identity?.authoredEffectPath ?? layer.materialPath ?? layer.imagePath,
                    authoredShaderPath: pass.shader,
                    classification: .unsupportedMetadataOnly,
                    consumerDisposition: .noRuntimeTextureProviderConsumer,
                    metadataKind: "usertextures",
                    metadataSources: sources
                )
            }
        }
    }
}

#endif
