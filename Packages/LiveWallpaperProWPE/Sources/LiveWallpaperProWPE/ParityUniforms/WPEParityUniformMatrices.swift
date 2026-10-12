import simd

public extension WPECBufferValue {
    /// WPE uploads every matrix transposed (1400d8300.c case 9): register i holds row i of the matrix.
    static func wpeTransposed(_ matrix: simd_float4x4) -> Self {
        let rows = matrix.transpose
        return .matrix(WPEFloatMatrix(columns: [rows.columns.0, rows.columns.1, rows.columns.2, rows.columns.3]))
    }

    static func wpeTransposed(_ matrix: simd_float3x3) -> Self {
        let rows = matrix.transpose
        return .matrix(WPEFloatMatrix(columns: [rows.columns.0, rows.columns.1, rows.columns.2]))
    }
}

/// Per-draw object matrices (1400d8300.c:134-241).
public struct WPEParityUniformMatrices: Sendable {
    public var model: simd_float4x4
    public var view: simd_float4x4
    public var projection: simd_float4x4

    public init(model: simd_float4x4, view: simd_float4x4, projection: simd_float4x4) {
        self.model = model
        self.view = view
        self.projection = projection
    }

    /// Effect passes draw with M = V = I and P = ortho(±1, ±1000) (1401e8aa0.c:738-780).
    public static let effectPass = Self(model: matrix_identity_float4x4, view: matrix_identity_float4x4,
                                        projection: ortho(halfWidth: 1, halfHeight: 1, depth: 1000))

    /// FUN_14009a630 with l = -w, r = w, b = -h, t = h, n = -d, f = d: z in [-d, d] maps to [0, 1].
    public static func ortho(halfWidth: Float, halfHeight: Float, depth: Float) -> simd_float4x4 {
        var matrix = simd_float4x4(diagonal: SIMD4(1 / halfWidth, 1 / halfHeight, 1 / (2 * depth), 1))
        matrix.columns.3.z = 0.5
        return matrix
    }

    public var viewProjection: simd_float4x4 {
        projection * view
    }

    public var modelViewProjection: simd_float4x4 {
        projection * view * model
    }

    /// Columns of mat3(M) normalized one by one with WPE's one-step fast inverse square root.
    public var normalModel: simd_float3x3 {
        func normalized(_ column: SIMD4<Float>) -> SIMD3<Float> {
            let xyz = SIMD3(column.x, column.y, column.z)
            return xyz * Self.fastInverseSquareRoot(simd_length_squared(xyz))
        }
        return simd_float3x3(normalized(model.columns.0), normalized(model.columns.1), normalized(model.columns.2))
    }

    public var values: [String: WPECBufferValue] {
        let mvp = modelViewProjection
        return [
            "g_ModelMatrix": .wpeTransposed(model),
            "g_ModelMatrixInverse": .wpeTransposed(model.inverse),
            "g_ViewProjectionMatrix": .wpeTransposed(viewProjection),
            "g_ModelViewProjectionMatrix": .wpeTransposed(mvp),
            "g_ModelViewProjectionMatrixInverse": .wpeTransposed(mvp.inverse),
            "g_NormalModelMatrix": .wpeTransposed(normalModel),
        ]
    }

    static func fastInverseSquareRoot(_ value: Float) -> Float {
        let guess = Float(bitPattern: 0x5F37_5A86 &- (value.bitPattern >> 1))
        return (1.5 - value * 0.5 * guess * guess) * guess
    }
}

/// Effect-pass matrices; WPE writes them only for passes whose flag bit 0 is set (1401ebf60.c:185-333).
public struct WPEParityUniformEffectPass: Sendable {
    public var layerModel: simd_float4x4
    public var layerModelViewProjection: simd_float4x4
    public var size: SIMD2<Float>
    public var isLastPass: Bool

    public init(layerModel: simd_float4x4, layerModelViewProjection: simd_float4x4, size: SIMD2<Float>,
                isLastPass: Bool) {
        self.layerModel = layerModel
        self.layerModelViewProjection = layerModelViewProjection
        self.size = size
        self.isLastPass = isLastPass
    }

    public var halfSizeScale: simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(size.x / 2, size.y / 2, 1, 1))
    }

    public var effectModel: simd_float4x4 {
        isLastPass ? layerModel : layerModel * halfSizeScale
    }

    public var effectModelViewProjection: simd_float4x4 {
        isLastPass ? layerModelViewProjection : layerModelViewProjection * halfSizeScale
    }

    public var effectTextureProjection: simd_float4x4 {
        isLastPass ? layerModelViewProjection * halfSizeScale : effectModelViewProjection
    }

    public var values: [String: WPECBufferValue] {
        [
            "g_EffectModelMatrix": .wpeTransposed(effectModel),
            "g_EffectModelViewProjectionMatrix": .wpeTransposed(effectModelViewProjection),
            "g_EffectModelViewProjectionMatrixInverse": .wpeTransposed(effectModelViewProjection.inverse),
            "g_EffectTextureProjectionMatrix": .wpeTransposed(effectTextureProjection),
            "g_EffectTextureProjectionMatrixInverse": .wpeTransposed(effectTextureProjection.inverse),
            "g_LayerModelMatrix": .wpeTransposed(layerModel),
        ]
    }
}
