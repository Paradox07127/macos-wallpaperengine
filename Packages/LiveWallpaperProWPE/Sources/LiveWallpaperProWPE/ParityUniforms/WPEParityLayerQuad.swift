import simd

/// FUN_1401ede30: a quad centred on the origin, y up, v = 0 on the top edge, drawn as indexed triangles.
public struct WPEParityLayerQuad: Sendable, Equatable {
    public struct Vertex: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var texcoord: SIMD2<Float>
    }

    public static let indices: [UInt16] = [0, 2, 1, 1, 2, 3]
    /// Bytes per vertex: float3 position, float2 texcoord.
    public static let stride = 20

    /// The 2×2 quad intermediate effect passes draw (obj+0x2e0, flag bit 2).
    public static let effectPass = Self(size: SIMD2(2, 2), flipsV: true)

    /// v0 top-left, v1 top-right, v2 bottom-left, v3 bottom-right.
    public let vertices: [Vertex]

    /// `insetsUV` (flag bit 1) pulls the UVs in by 0.15 texel of a `size`-texel image; `flipsV` (bit 2) puts
    /// v = vMax on the top edge.
    public init(size: SIMD2<Float>, uvMax: SIMD2<Float> = .one, insetsUV: Bool = false, flipsV: Bool = false) {
        let half = size / 2
        let inset = insetsUV ? 0.15 / size : .zero
        var low = inset
        var high = uvMax - inset
        if flipsV {
            swap(&low.y, &high.y)
        }
        vertices = [
            Vertex(position: SIMD3(-half.x, half.y, 0), texcoord: SIMD2(low.x, low.y)),
            Vertex(position: SIMD3(half.x, half.y, 0), texcoord: SIMD2(high.x, low.y)),
            Vertex(position: SIMD3(-half.x, -half.y, 0), texcoord: SIMD2(low.x, high.y)),
            Vertex(position: SIMD3(half.x, -half.y, 0), texcoord: SIMD2(high.x, high.y)),
        ]
    }

    /// The layer-size mesh (obj+0x490 / obj+0x2e8), built from the integer size.
    public static func layer(size: SIMD2<Float>, uvMax: SIMD2<Float> = .one, insetsUV: Bool = false) -> Self {
        Self(size: size.rounded(.towardZero), uvMax: uvMax, insetsUV: insetsUV)
    }

    /// Vertices packed at `stride`.
    public var packed: [Float] {
        vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z, $0.texcoord.x, $0.texcoord.y] }
    }
}
