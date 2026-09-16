#if !LITE_BUILD
import LiveWallpaperProWPE

/// Immutable, conservative access facts shared by value-only pass updates.
/// Raw and prepared references deliberately coexist: lowering a bind's `previous`
/// to the chain input must not erase its authored origin or weaken existing guards.
/// These are references, not a proof that a shader samples every listed slot.
final class WPEPreparedPassAccess: Equatable, Sendable {
    enum ReferenceGroup {
        case source, rawTextures, rawBinds, preparedBindings
    }

    let target: WPERenderTarget
    let source: WPETextureReference
    let rawTextures: [Int: WPETextureReference]
    let rawBinds: [Int: WPETextureReference]
    let preparedBindings: [Int: WPETextureReference]

    /// Same group order and multiplicity as the original textureReferences API.
    /// Arrays/dictionaries share their CoW storage when the pass is copied.
    let textureReferences: [WPETextureReference]
    let fboNames: [String]
    let hasPreviousReference: Bool
    let hasSceneAliasReference: Bool
    let hasNamedFBOReference: Bool

    init(pass: WPERenderPass, textureBindings: [Int: WPETextureReference]) {
        target = pass.target
        source = pass.source
        rawTextures = pass.textures
        rawBinds = pass.binds
        preparedBindings = textureBindings

        var references: [WPETextureReference] = []
        references.reserveCapacity(1 + rawTextures.count + rawBinds.count + textureBindings.count)
        references.append(source)
        references.append(contentsOf: rawTextures.values)
        references.append(contentsOf: rawBinds.values)
        references.append(contentsOf: textureBindings.values)
        textureReferences = references

        var names: [String] = []
        var previous = false
        var sceneAlias = false
        var namedFBO = false
        for reference in references {
            switch reference {
            case .previous:
                previous = true
            case let .fbo(name):
                names.append(name)
                if WPETextureReference.isSceneAliasName(name) {
                    sceneAlias = true
                } else {
                    namedFBO = true
                }
            case .image, .asset:
                break
            }
        }
        fboNames = names
        hasPreviousReference = previous
        hasSceneAliasReference = sceneAlias
        hasNamedFBOReference = namedFBO
    }

    /// Preserves consumers' diagnostic priority without rebuilding reference arrays.
    func references(in group: ReferenceGroup) -> ArraySlice<WPETextureReference> {
        let texturesEnd = 1 + rawTextures.count
        let bindsEnd = texturesEnd + rawBinds.count
        switch group {
        case .source: return textureReferences[0 ..< 1]
        case .rawTextures: return textureReferences[1 ..< texturesEnd]
        case .rawBinds: return textureReferences[texturesEnd ..< bindsEnd]
        case .preparedBindings: return textureReferences[bindsEnd...]
        }
    }

    /// No hash-only validation: changed bindings/target must invalidate the facts,
    /// even if a caller accidentally supplies a cache from an unrelated pass.
    func matches(pass: WPERenderPass, textureBindings: [Int: WPETextureReference]) -> Bool {
        target == pass.target && source == pass.source
            && rawTextures == pass.textures && rawBinds == pass.binds
            && preparedBindings == textureBindings
    }

    static func == (lhs: WPEPreparedPassAccess, rhs: WPEPreparedPassAccess) -> Bool {
        // Do not compare cached array order: equal dictionaries can enumerate in
        // different orders, and pass equality must retain its existing semantics.
        lhs === rhs || (lhs.target == rhs.target && lhs.source == rhs.source
            && lhs.rawTextures == rhs.rawTextures && lhs.rawBinds == rhs.rawBinds
            && lhs.preparedBindings == rhs.preparedBindings)
    }
}
#endif
