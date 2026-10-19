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
                        consumerDisposition: .noRuntimeTextureProviderConsumer,
                        metadataKind: "usertextures",
                        metadataSources: ["effect-override"]
                    )
                }
            }
        }
    }
}
#endif
