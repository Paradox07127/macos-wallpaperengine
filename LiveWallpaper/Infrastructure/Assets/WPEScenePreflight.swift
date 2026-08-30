#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Pre-render capability gate for a single scene project.
///
/// The tier reflects what the SCENE asks for, not what the renderer currently
/// supports. The dispatch layer downgrades `nativePlayable` to
/// `degradedPlayable` when a feature hasn't shipped yet, so scenes never need
/// re-classifying as features land.
enum WPEScenePreflight {
    static func classify(
        document: WPESceneDocument,
        project: WallpaperEngineProject,
        scenePackageEntries: [String]
    ) -> WPEScenePreflightResult {
        var flags = Set<WPESceneFeatureFlag>()

        if project.requiresWindowsPlugin {
            flags.insert(.windowsPlugin)
        }
        if scenePackageEntries.contains(where: { entry in
            let lowered = entry.lowercased()
            return lowered.hasSuffix(".vert") || lowered.hasSuffix(".frag")
        }) {
            flags.insert(.customShaderSource)
        }

        for diagnostic in document.diagnostics {
            let lowered = diagnostic.message.lowercased()
            if lowered.contains("particle object") {
                flags.insert(.particleObject)
            } else if lowered.contains("text") && lowered.contains("unsupported") {
                flags.insert(.textObject)
            } else if lowered.contains("sound") && lowered.contains("unsupported") {
                flags.insert(.soundObject)
            } else if lowered.contains("light") && lowered.contains("unsupported") {
                flags.insert(.lightObject)
            } else if lowered.contains("animationlayers") {
                flags.insert(.animationLayer)
            }
        }

        for object in document.imageObjects {
            if !object.effects.isEmpty { flags.insert(.imageEffect) }
            if !object.animationLayers.isEmpty { flags.insert(.animationLayer) }
        }

        let tier = Self.tier(for: flags, hasImageObjects: !document.imageObjects.isEmpty)
        return WPEScenePreflightResult(
            tier: tier,
            featureFlags: flags,
            shaderImplementationInventory: WPEShaderImplementationInventory.preflightEntries(
                document: document
            )
        )
    }

    private static func tier(
        for flags: Set<WPESceneFeatureFlag>,
        hasImageObjects: Bool
    ) -> WPEScenePreflightTier {
        if flags.contains(.windowsPlugin) { return .unsupported }
        if !hasImageObjects && flags.isDisjoint(with: [.particleObject, .textObject, .lightObject]) {
            return .unsupported
        }

        if flags.contains(.lightObject) {
            return .runtimeSystemsRequired
        }
        if flags.contains(.customShaderSource) {
            return .degradedPlayable
        }
        if flags.contains(.animationLayer) {
            return .degradedPlayable
        }
        if flags.contains(.imageEffect) {
            return .degradedPlayable
        }
        return .nativePlayable
    }
}

struct WPEScenePreflightResult: Equatable, Sendable {
    let tier: WPEScenePreflightTier
    let featureFlags: Set<WPESceneFeatureFlag>
    let shaderImplementationInventory: [WPEShaderImplementationInventoryEntry]
}

/// Why authored shader/effect metadata has no runtime consumer. Kept separate
/// from execution classification so a pass may still render while one preserved
/// contract item (currently `usertextures`) is metadata-only.
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
                    guard !override.userTextures.isEmpty else { return nil }
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
                        // The scene document names the effect asset, not the
                        // material shader nested inside it. Graph resolution
                        // fills this without guessing from filenames.
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

    static func graphEntries(
        graph: WPERenderGraph
    ) -> [WPEShaderImplementationInventoryEntry] {
        graph.layers.flatMap { layer in
            layer.passes.compactMap { pass in
                guard !pass.userTextureBindings.isEmpty,
                      let identity = pass.authoredJSON.effectIdentity else {
                    return nil
                }
                var sources: [String] = []
                if !pass.userTextureBindings.material.isEmpty { sources.append("effect-material") }
                if !pass.userTextureBindings.pass.isEmpty { sources.append("material-pass") }
                if !pass.userTextureBindings.override.isEmpty { sources.append("effect-override") }
                return WPEShaderImplementationInventoryEntry(
                    stableEffectID: identity.stableEffectID,
                    stablePassID: identity.stablePassID,
                    authoredOverrideID: identity.authoredOverrideID,
                    renderPassID: pass.id,
                    authoredEffectPath: identity.authoredEffectPath,
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
