#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

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

        // Capability derives from typed parser output, never localized/logging prose.
        if !document.particleObjects.isEmpty {
            flags.insert(.particleObject)
        }
        if !document.textObjects.isEmpty {
            flags.insert(.textObject)
        }
        if !document.soundObjects.isEmpty {
            flags.insert(.soundObject)
        }
        if !document.lightObjects.isEmpty {
            flags.insert(.lightObject)
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
        if flags.contains(.windowsPlugin) {
            return .unsupported
        }
        if !hasImageObjects, flags.isDisjoint(with: [.particleObject, .textObject]) {
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

#endif
