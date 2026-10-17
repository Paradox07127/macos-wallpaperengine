public struct WPEParityPostProcessDraw: Hashable, Sendable {
    public enum Blend: Hashable, Sendable {
        case normal, additive, translucent
    }

    /// Names the draw; the program comes from `material`.
    public let shader: String
    public let material: String
    public let reads: [WPEResourceID]
    public let blend: Blend
    /// Uniforms the engine writes for this pass; they win over material and engine values.
    public let constants: [String: [Float]]
    /// One texel's UV extent, in the same order as `reads`.
    public let texelSizes: [SIMD2<Float>]
    /// Combos the engine sets on the material.
    public let combos: [String: Int32]
    /// Asset textures in slots that `reads` leaves free, named like a material's textures.
    public let textures: [Int32: String]
}

/// Appended after the object loop. `_rt_FullFrameBuffer`, `_rt_MipMappedFrameBuffer` and the HDR pyramid are
/// pooled; the LDR bloom targets are transient, overwritten by full-screen downsampling before any read.
public struct WPEParityPostProcessFrame: Sendable {
    public let resources: [WPELogicalResource]
    public let operations: [WPERenderOperation]
    /// Ordered exactly like the draw operations; also used as each draw's state key.
    public let draws: [WPEParityPostProcessDraw]
    /// See `WPEParitySceneFrame.logicalSizes`.
    public var logicalSizes: [WPEResourceID: SIMD2<Int>] = [:]
}
