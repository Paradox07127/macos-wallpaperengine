public struct WPEParityPostProcessDraw: Hashable, Sendable {
    public enum Blend: Hashable, Sendable {
        case normal, additive, translucent
    }

    public enum Geometry: Hashable, Sendable {
        case fullScreenQuad
    }

    /// Names the draw; the program comes from `material`.
    public let shader: String
    public let material: String
    public let reads: [WPEResourceID]
    public let blend: Blend
    public let geometry: Geometry
    public let bloomParameters: [String: SIMD4<Float>]
    /// One texel's UV extent, in the same order as `reads`.
    public let texelSizes: [SIMD2<Float>]
    /// The LDR combine writes alpha 1.
    public let outputAlpha: Float?
}

/// Appended after the object loop; present is a marker after the last operation.
/// `_rt_FullFrameBuffer` and `_rt_MipMappedFrameBuffer` retain contents across frames. Bloom and
/// pyramid targets are transient: full-screen downsampling overwrites them before
/// any read or additive upsample. Later sampling requires heap storage, not memoryless.
public struct WPEParityPostProcessFrame: Sendable {
    public struct Present: Hashable, Sendable {
        public let backbuffer: WPEResourceID
    }

    public let resources: [WPELogicalResource]
    public let operations: [WPERenderOperation]
    /// Ordered exactly like the draw operations; also used as each draw's state key.
    public let draws: [WPEParityPostProcessDraw]
    public let present: Present
}
