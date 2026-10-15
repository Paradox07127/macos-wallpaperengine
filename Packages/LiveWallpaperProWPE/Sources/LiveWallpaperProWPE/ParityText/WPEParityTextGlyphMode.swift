/// The mode actually admitted by the caller's prepared material/texture transaction.
/// An authored MSDF/effect request alone must not publish a field beneath the ordinary font material.
public enum WPEParityTextGlyphMode: Hashable, Sendable {
    case bitmap
    case distanceField

    /// 1401b3430's original material identity. The caller must prepare this actual variant before publication.
    public func materialPath(atlas: WPEParityGlyphAtlasInstance.Atlas, depth: Bool) -> String {
        let base = atlas == .mono ? "basefont" : "basefontrgba"
        return "materials/fonts/\(base)\(self == .distanceField ? "_msdf" : "")\(depth ? "_depth" : "").json"
    }
}

/// Preparation failures that must leave the previous text's atlas references intact.
public enum WPEParityTextPreparationError: Error, Equatable, Sendable {
    case distanceFieldNotRequested
    case colorRequiresPairedAtlas
    case zeroAreaDistanceGlyph
    case nonfiniteDrawParameters
    case foreignPreparedUpdate
    case stalePreparedUpdate
    case preparedUpdateConsumed
}

/// 140258b80's effective fields and 1401b3b60's draw writes, before the shared scene RV store consumes them.
/// RV3 is deliberately one component: the native write preserves its other three lanes.
public struct WPEParityTextDrawParameters: Hashable, Sendable {
    public let renderVar0: SIMD4<Float>
    public let renderVar1: SIMD4<Float>
    public let renderVar2: SIMD4<Float>
    public let renderVar3X: Float
    public let combos: [String: Int]

    /// Nonfinite authored fields are outside this admitted consumer subset; never substitute guessed constants.
    public init?(object: WPEParityTextObject, pointSize: Float) {
        let values = [pointSize, object.outlineThickness, object.blurSize, object.dropShadowSize,
                      object.dropShadowOpacity, object.dropShadowOffset.x, object.dropShadowOffset.y,
                      object.outlineColor.x, object.outlineColor.y, object.outlineColor.z,
                      object.dropShadowColor.x, object.dropShadowColor.y, object.dropShadowColor.z]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let outline = object.outline ? (object.outlineThickness <= 1 ? 1 : object.outlineThickness) : 0
        let blur = object.blur ? (object.blurSize <= 0.01 ? 0.01 : object.blurSize) : 0
        let shadow = object.dropShadow ? (object.dropShadowSize <= 0.01 ? 0.01 : object.dropShadowSize) : 0
        let offset = object.dropShadow ? object.dropShadowOffset : .zero
        let scale = (Float(32) / WPEParityFontLibrary.clampedPointSize(pointSize)) * 0.24
        // Original 14049285c is 0x40a33334, one ULP above the nearest Float literal 5.1.
        let outlineLimit = Float(bitPattern: 0x40A3_3334)
        var outlineWidth = min(outline * scale, outlineLimit)
        let blurWidth = min(blur * scale, 6)
        if outlineWidth + blurWidth > outlineLimit {
            outlineWidth = max(outlineLimit - blurWidth, 0)
        }
        renderVar0 = SIMD4(24, outlineWidth, blurWidth, min(shadow * scale, 6))
        renderVar1 = SIMD4(object.outlineColor, min(offset.x * scale, 6))
        renderVar2 = SIMD4(object.dropShadowColor, min(offset.y * scale, 6))
        renderVar3X = object.dropShadowOpacity
        var combos: [String: Int] = [:]
        if outline >= 1 {
            combos["OUTLINE_ENABLED"] = 1
        }
        if blur > 0 {
            combos["BLUR_ENABLED"] = 1
        }
        // Effective enabled shadow radius is at least .01, so the native offset-length alternative cannot
        // change the result for the finite authored fields admitted here. Disabled shadow offsets are zero.
        if shadow > 0 {
            combos["DROP_SHADOW_ENABLED"] = 1
        }
        self.combos = combos
    }
}
