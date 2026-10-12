import simd

/// Canvas pixels the camera alignment crops off each side (C+0x110..0x11c), written in orthographic scenes only
/// (140183a70.c:136-164).
public struct WPEParityTextCropMargins: Equatable, Sendable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float

    public init(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// The model matrices and translations of a text layer's draws (1401e8aa0.c:177-720, 140258050, 140257d70).
public enum WPEParityTextMatrices {
    /// FUN_1402585c0; a perspective scene never moves.
    public static func anchorOffset(_ anchor: WPEParityTextAnchor, margins: WPEParityTextCropMargins,
                                    orthographic: Bool) -> SIMD2<Float> {
        guard orthographic else { return .zero }
        let centerX = (margins.left - margins.right) * 0.5
        let centerY = (margins.bottom - margins.top) * 0.5
        return switch anchor {
        case .none: .zero
        case .center: SIMD2(centerX, centerY)
        case .top: SIMD2(centerX, -margins.top)
        case .topRight: SIMD2(-margins.right, -margins.top)
        case .right: SIMD2(-margins.right, centerY)
        case .bottomRight: SIMD2(-margins.right, margins.bottom)
        case .bottom: SIMD2(centerX, margins.bottom)
        case .bottomLeft: SIMD2(margins.left, margins.bottom)
        case .left: SIMD2(margins.left, centerY)
        case .topLeft: SIMD2(margins.left, -margins.top)
        }
    }

    /// slot16: the anchor moves the stack before the layer model multiplies in, then T(blockOffset)
    /// (1401e8aa0.c:272-313). The final composite of the FBO path uses the same model (:951-955).
    public static func layerModel(_ model: simd_float4x4, anchorOffset: SIMD2<Float>,
                                  blockOffset: SIMD2<Float>) -> simd_float4x4 {
        WPEParityCamera.translation(SIMD3(anchorOffset, 0)) * model
            * WPEParityCamera.translation(SIMD3(blockOffset, 0))
    }

    /// Direct glyphs: (−W/2 − min(minX, 0), H/2 − top) (140258050.c:145-179).
    public static func glyphTranslation(_ mesh: WPEParityTextMesh) -> SIMD2<Float> {
        let (width, height) = (mesh.maxX - mesh.minX, mesh.top - mesh.bottom)
        var x = width * -0.5
        if mesh.minX < 0 {
            x -= mesh.minX
        }
        return SIMD2(x, height * 0.5 - mesh.top)
    }

    /// The opaquebackground quad: (−W/2 − p, −H/2 − p) (140258050.c:52-105).
    public static func backgroundTranslation(_ mesh: WPEParityTextMesh, padding: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2((mesh.maxX - mesh.minX) * -0.5 - padding.x, (mesh.top - mesh.bottom) * -0.5 - padding.y)
    }

    /// Glyphs into the text FBO: (p − min(minX, 0), p − bottom) (140257d70.c:41-88).
    public static func fboGlyphTranslation(_ mesh: WPEParityTextMesh, padding: SIMD2<Float>) -> SIMD2<Float> {
        var x = padding.x
        if mesh.minX < 0 {
            x -= mesh.minX
        }
        return SIMD2(x, padding.y - mesh.bottom)
    }

    /// Direct draws: the background quad or the glyphs at their translation under the slot16 model.
    public static func direct(layerModel: simd_float4x4, translation: SIMD2<Float>) -> simd_float4x4 {
        layerModel * WPEParityCamera.translation(SIMD3(translation, 0))
    }

    /// FBO glyphs: M = T(translation), V = I, P = the composite fill ortho over the FBO (1401e8aa0.c:568-611).
    public static func fbo(size: SIMD2<Int>, translation: SIMD2<Float>) -> WPEParityUniformMatrices {
        var matrices = WPEParityLayerTransform.compositeFillMatrices(size: SIMD2(Float(size.x), Float(size.y)))
        matrices.model = WPEParityCamera.translation(SIMD3(translation, 0))
        return matrices
    }
}

public extension WPEParityCamera {
    /// L, b, c, d of the alignment crop, before the fliph mirror.
    var cropMargins: WPEParityTextCropMargins {
        let crop = alignmentCrop
        return WPEParityTextCropMargins(left: crop.x, top: crop.w, right: crop.y, bottom: crop.z)
    }
}
