import simd

/// One `renderer` entry; WPE draws each entry once per frame in JSON order (R16 Q3).
public struct WPEParityParticleRenderer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case sprite, spriteTrail, rope, ropeTrail }

    public let kind: Kind
    /// spritetrail: seconds of velocity stretch; ropetrail: seconds of history.
    public let length: Float
    public let maxLength: Float
    public let minLength: Float
    /// ropetrail vertices per particle.
    public let segments: Int
    public let subdivision: Int
    /// screen 0, upright 1, fixed 2 (D/1401c22e0.c:159-182).
    public let orientation: Int
    /// `axis` normalised, (0, 1, 0) when absent or zero (D/1401c22e0.c:185-245).
    public let axis: SIMD3<Float>
    /// normalize(axis × (Y × axis)), (0, 0, −1) when axis ∥ Y (D/1401c22e0.c:246-288).
    public let fixedUp: SIMD3<Float>
    /// `flags` bit0: orientation axes are taken as world axes instead of being rotated by the model (R22 Q2).
    public let worldAxes: Bool
    public let uvScrolling: Bool
    public let uvScale: Float
    public let fadeAlpha: Bool
    public let fadeSize: Bool

    init?(name: String, json: WPESceneJSONValue) {
        typealias JSON = WPEParityParticleJSON
        switch name {
        case "sprite": kind = .sprite
        case "spritetrail": kind = .spriteTrail
        case "rope": kind = .rope
        case "ropetrail": kind = .ropeTrail
        default: return nil
        }
        length = JSON.number(json["length"]) ?? 0.05
        maxLength = JSON.number(json["maxlength"]) ?? 10
        minLength = JSON.number(json["minlength"]) ?? 0
        segments = max(1, Int(JSON.number(json["segments"]) ?? 3))
        // D/1401c0c90.c:21-28 (rope, 0–32, default 4); D/1401c1070.c:84-95 (ropetrail, default 1).
        let subdivision = Int(JSON.number(json["subdivision"]) ?? (kind == .rope ? 4 : 1))
        self.subdivision = kind == .rope ? min(max(subdivision, 0), 32) : subdivision
        orientation = switch JSON.string(json["orientation"])?.lowercased() {
        case "upright": 1
        case "fixed": 2
        case "screen": 0
        default: Int(JSON.number(json["orientation"]) ?? 0)
        }
        let axis = JSON.vector(json["axis"]) ?? .zero
        self.axis = axis == .zero ? SIMD3(0, 1, 0) : simd_normalize(axis)
        fixedUp = self.axis.x == 0 && self.axis.z == 0
            ? SIMD3(0, 0, -1)
            : simd_normalize(simd_cross(self.axis, simd_cross(SIMD3(0, 1, 0), self.axis)))
        worldAxes = Int(JSON.number(json["flags"]) ?? 0) & 1 != 0
        uvScrolling = JSON.flag(json["uvscrolling"])
        uvScale = JSON.number(json["uvscale"]) ?? 1
        fadeAlpha = JSON.flag(json["fadealpha"])
        fadeSize = JSON.flag(json["fadesize"])
    }
}

/// Texture facts the combos depend on; they come from the entry's material, not the particle JSON.
public struct WPEParityParticleMaterial: Equatable, Sendable {
    /// texture0 texFlags bit 2 (B/1401c5490.c:10129-10138).
    public var spriteSheet: Bool
    public var spriteSheetNPOT: Bool
    public var texture0Format: Int?

    public init(spriteSheet: Bool = false, spriteSheetNPOT: Bool = false, texture0Format: Int? = nil) {
        self.spriteSheet = spriteSheet
        self.spriteSheetNPOT = spriteSheetNPOT
        self.texture0Format = texture0Format
    }
}

/// g_RenderVar0 components a draw writes; nil keeps the previous draw's value (R16 Q3).
public struct WPEParityRenderVar0: Equatable, Sendable {
    public var x: Float?
    public var y: Float?
    public var z: Float?
    public var w: Float?

    public init(x: Float? = nil, y: Float? = nil, z: Float? = nil, w: Float? = nil) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

/// GS-path vertex bytes for one renderer entry: `count` POINTLIST vertices of `stride` bytes.
public struct WPEParityParticleVertexBatch: Equatable, Sendable {
    public let bytes: [UInt8]
    public let stride: Int
    public let count: Int
    public let renderVar0: WPEParityRenderVar0
}

/// One actual renderer draw, in recursive instance order, with its final native draw-stack model.
public struct WPEParityParticleDrawBatch: Sendable {
    public let key: WPEParityParticleDrawKey
    public let vertices: WPEParityParticleVertexBatch
    public let modelMatrix: simd_float4x4
}

/// An owner's native snapshot boundary in the unfiltered actual draw order. Zero and `batches.count` are valid:
/// a live system whose base material needs FFB can trigger even when its own rope entry cannot draw.
/// Systems with unavailable base materials are pruned with their descendants before any batch is packed.
public struct WPEParityParticleDrawStream: Sendable {
    public let batches: [WPEParityParticleDrawBatch]
    public let snapshotBoundary: Int?
}

/// One accepted system's real base material, before entry-specific combos. The caller compiles `program` once,
/// intersects its VS/PS reflected texture slots with `textureNames`, and caches the native FFB requirement.
public struct WPEParityParticleMaterialProbe: Sendable {
    public enum Material: Sendable {
        case ready(program: WPEParityProgram, textureNames: [Int32: String])
        /// Missing material or source/rewriter failure. This is not a successfully compiled false FFB fact.
        case unavailable(String)
    }

    public let objectID: String
    public let path: [WPEParityParticlePathElement]
    public let material: Material
}

/// Initialization facts for a renderer prototype; obtaining them does not allocate slots or consume RNG.
public struct WPEParityParticlePrototype: Sendable {
    public let renderers: [WPEParityParticleRenderer]
    public let slotCount: Int
}
