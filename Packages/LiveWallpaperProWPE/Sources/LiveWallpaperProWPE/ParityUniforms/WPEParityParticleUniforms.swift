import simd

/// g_ModelMatrix, g_ViewMatrix and g_ProjectionMatrix of one particle renderer draw (R16 Q3, R22 Q1/Q5).
public enum WPEParityParticleMatrices {
    /// `modelMatrix` is the walker's final D, including its native world/composite resets.
    public static func draw(_ transforms: WPEParityLayerTransformSet, objectID: String, modelMatrix: simd_float4x4,
                            perspective: Bool, compositeOwnerID: String?,
                            parallax: SIMD2<Float>) -> WPEParityUniformMatrices {
        var matrices = WPEParityUniformMatrices(model: modelMatrix, view: transforms.view(objectID, parallax: parallax),
                                                projection: transforms.projection(objectID))
        if let ownerID = compositeOwnerID, let owner = transforms.layers[ownerID] {
            matrices.view = matrix_identity_float4x4
            matrices.projection = WPEParityUniformMatrices.ortho(halfWidth: owner.size.x / 2,
                                                                 halfHeight: owner.size.y / 2, depth: 1000)
        }
        if perspective {
            (matrices.view, matrices.projection) = transforms.camera.pushPerspective(view: matrices.view,
                                                                                     projection: matrices.projection)
        }
        return matrices
    }
}

/// g_OrientationForward/Right/Up of one renderer draw (D/1402298b0.c:43-174).
public enum WPEParityParticleOrientation {
    /// `modelRotation` is the 3×3 of the draw's g_ModelMatrix; `sceneView` is the frame's scene camera V,
    /// never a composite or perspective push.
    public static func vectors(renderer: WPEParityParticleRenderer, modelRotation: simd_float3x3,
                               sceneView: simd_float4x4)
        -> (forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        func row(_ index: Int) -> SIMD3<Float> {
            SIMD3(sceneView.columns.0[index], sceneView.columns.1[index], sceneView.columns.2[index])
        }
        let viewForward = -row(2)
        let yAxis = SIMD3<Float>(0, 1, 0)
        var forward: SIMD3<Float>
        var up: SIMD3<Float>
        switch renderer.orientation {
        case 1:
            up = renderer.worldAxes ? yAxis : modelRotation * renderer.axis
            forward = simd_cross(simd_cross(viewForward, up), up)
        case 2:
            forward = renderer.worldAxes ? renderer.axis : modelRotation * renderer.axis
            up = renderer.worldAxes ? renderer.fixedUp : modelRotation * renderer.fixedUp
        default:
            forward = -viewForward
            up = renderer.worldAxes ? row(1) : modelRotation * yAxis
            up -= forward * simd_dot(forward, up)
        }
        // Transpose, not inverse: non-uniform scale skews the result exactly as WPE does.
        forward = modelRotation.transpose * forward
        up = modelRotation.transpose * up
        return (simd_normalize(forward), simd_normalize(simd_cross(up, forward)), simd_normalize(up))
    }
}

/// g_RenderVar0/1: one scene-wide store shared with the bloom, combine_hdr and text draws, zero at load and
/// never reset per frame (R22 Q3).
public struct WPEParityRenderVarState: Equatable, Sendable {
    public var rv0: SIMD4<Float> = .zero
    public var rv1: SIMD4<Float> = .zero

    public init() {}

    public mutating func apply(_ rv0: WPEParityRenderVar0) {
        self.rv0 = SIMD4(rv0.x ?? self.rv0.x, rv0.y ?? self.rv0.y, rv0.z ?? self.rv0.z, rv0.w ?? self.rv0.w)
    }

    public mutating func setRV1(_ rv1: SIMD4<Float>) {
        self.rv1 = rv1
    }

    /// SPRITESHEET draws: (frame 0 width UV, frame 0 height UV, frame count, frame 0 pixel height/width)
    /// (D/1402366f0.c:81-91); `texture.spriteFrame` is frame 0. Nil without TEXS frames.
    public static func spriteSheetRV1(texture: WPEParityUniformTexture, frameCount: Int) -> SIMD4<Float>? {
        guard let uv = texture.spriteFrame?.rotation else { return nil }
        let aspect = Float(texture.textureHeight) / Float(texture.textureWidth) * (uv.w / uv.x)
        return SIMD4(uv.x, uv.w, Float(frameCount), aspect)
    }
}
