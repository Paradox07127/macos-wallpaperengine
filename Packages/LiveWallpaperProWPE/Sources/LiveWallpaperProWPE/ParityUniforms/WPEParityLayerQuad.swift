import simd

/// FUN_1401ede30: a quad centred on the origin, y up, v = 0 on the top edge, drawn as indexed triangles.
public struct WPEParityLayerQuad: Sendable, Equatable {
    public struct Vertex: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var texcoord: SIMD2<Float>
    }

    public static let indices: [UInt16] = [0, 2, 1, 1, 2, 3]

    /// The 2×2 quad intermediate effect passes draw (obj+0x2e0). Main+0x118 bit0 is set on Windows, so flag
    /// bit 2 never flips V.
    public static let effectPass = Self(size: SIMD2(2, 2))

    /// v0 top-left, v1 top-right, v2 bottom-left, v3 bottom-right.
    public let vertices: [Vertex]

    /// `insetsUV` (flag bit 1) pulls the UVs in by 0.15 texel of a `size`-texel image.
    public init(size: SIMD2<Float>, center: SIMD2<Float> = .zero, uvMax: SIMD2<Float> = .one,
                insetsUV: Bool = false) {
        let low = center - size / 2
        let high = center + size / 2
        let inset = insetsUV ? 0.15 / size : .zero
        let uvLow = inset
        let uvHigh = uvMax - inset
        vertices = [
            Vertex(position: SIMD3(low.x, high.y, 0), texcoord: SIMD2(uvLow.x, uvLow.y)),
            Vertex(position: SIMD3(high.x, high.y, 0), texcoord: SIMD2(uvHigh.x, uvLow.y)),
            Vertex(position: SIMD3(low.x, low.y, 0), texcoord: SIMD2(uvLow.x, uvHigh.y)),
            Vertex(position: SIMD3(high.x, low.y, 0), texcoord: SIMD2(uvHigh.x, uvHigh.y)),
        ]
    }

    /// The layer-size mesh (obj+0x490 / obj+0x2e8), built from the integer size.
    public static func layer(size: SIMD2<Float>, uvMax: SIMD2<Float> = .one, insetsUV: Bool = false) -> Self {
        Self(size: size.rounded(.towardZero), uvMax: uvMax, insetsUV: insetsUV)
    }

    /// The albedo mesh into a layer composite (obj+0x2d8): (0, 0) to `size`, v = 0 on the y = size.y edge.
    public static func composite(size: SIMD2<Float>, uvMax: SIMD2<Float> = .one) -> Self {
        Self(size: size, center: size / 2, uvMax: uvMax)
    }
}
