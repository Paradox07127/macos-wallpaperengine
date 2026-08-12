#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// Layout MUST match `WPEParticleInstance` in `WPEMetalBuiltins.metal` exactly.
struct WPEParticleInstance {
    var positionAndSize: SIMD4<Float>   // x, y in centered scene pixels ; z = signed sprite X scale; w = size
    var color: SIMD4<Float>             // rgb 0…1, a = current alpha (base × fade envelope)
    var rotationAndLife: SIMD4<Float>   // x = rotationZ radians ; y = lifetimeFraction [0,1] ; z = spriteFrameIndex; w = signed sprite Y scale
    /// xy = render-space velocity (scene px/s). Only the TRAILRENDERER path
    /// reads it — WPE gates the matching `a_TexCoordVec4C1` on THICKFORMAT.
    var velocity: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
}

/// One ribbon-strip vertex for the rope renderer. Layout MUST match
/// `WPEParticleRopeVertex` in `WPEMetalBuiltins.metal`.
struct WPEParticleRopeVertex {
    var positionUV: SIMD4<Float>        // xy = centered scene pixels (Y-up) ; zw = uv (u across, v along the rope)
    var color: SIMD4<Float>             // rgb 0…1, a = current alpha
}

/// Value-typed RNG for spawn jitter (no existential/heap). Production `.system`; oracle injects `.seeded`.
enum WPEParticleRNG: RandomNumberGenerator {
    case system(SystemRandomNumberGenerator)
    case seeded(SplitMix64)

    mutating func next() -> UInt64 {
        switch self {
        case .system(var generator):
            let value = generator.next()
            self = .system(generator)
            return value
        case .seeded(var generator):
            let value = generator.next()
            self = .seeded(generator)
            return value
        }
    }
}

/// Deterministic, allocation-free 64-bit generator (Vigna's SplitMix64). Used only
/// under the render oracle to make particle spawn jitter reproducible run-to-run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One-shot world-space placement applied when loading a particle system.
/// WPE author space is consistently Y-up; origin, velocity, gravity, and rotation must not be flipped.
struct WPEParticleSceneTransform {
    var renderOrigin: SIMD3<Float>
    var objectScale: SIMD3<Float>
    var objectAngleZ: Float
    /// Scene render height (px); used to cap pathologically large additive
    /// sprites so a hugely-scaled emitter can't saturate the whole frame.
    var sceneHeight: Float

    init(sceneSize: SIMD2<Float>, objectOrigin: SIMD3<Float>, objectScale: SIMD3<Float>, objectAngleZ: Float) {
        self.renderOrigin = SIMD3<Float>(
            objectOrigin.x - sceneSize.x * 0.5,
            objectOrigin.y - sceneSize.y * 0.5,
            objectOrigin.z
        )
        self.objectScale = objectScale
        self.objectAngleZ = objectAngleZ
        self.sceneHeight = max(1, sceneSize.y)
    }

    static let identity = WPEParticleSceneTransform(
        sceneSize: SIMD2<Float>(1, 1),
        objectOrigin: SIMD3<Float>(0, 0, 0),
        objectScale: SIMD3<Float>(1, 1, 1),
        objectAngleZ: 0
    )

    /// Apply `T(renderOrigin)·Rz(+angleZ)·S(scale)` to a Y-up local point.
    func applyModelMatrix(toLocalPoint p: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(p.x * objectScale.x, p.y * objectScale.y, p.z * objectScale.z)
        let cosA = cos(objectAngleZ)
        let sinA = sin(objectAngleZ)
        return renderOrigin + SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    /// Rotate+scale free vectors (no translation, no Y-flip). Oracle 3526278753: velocity Y must stay negative = falling.
    func applyModelDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(v.x * objectScale.x, v.y * objectScale.y, v.z * objectScale.z)
        let cosA = cos(objectAngleZ)
        let sinA = sin(objectAngleZ)
        return SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    func worldSizeMultiplier() -> Float {
        // Object scale enlarges billboards (WPE T·R·S); additive size cap is at spawn.
        let s = (abs(objectScale.x) + abs(objectScale.y)) * 0.5
        return max(0, s)
    }

    func visualScaleSigns() -> SIMD2<Float> {
        SIMD2<Float>(
            objectScale.x < 0 ? -1 : 1,
            objectScale.y < 0 ? -1 : 1
        )
    }

    func visualRotationZ(localRotationZ: Float) -> Float {
        let signs = visualScaleSigns()
        let localRotation = signs.x * signs.y < 0 ? -localRotationZ : localRotationZ
        // `+angleZ` to match the flipped position/velocity chain and the image quad.
        return objectAngleZ + localRotation
    }

    func visualAngularZ(localAngularZ: Float) -> Float {
        let signs = visualScaleSigns()
        return signs.x * signs.y < 0 ? -localAngularZ : localAngularZ
    }
}

/// CPU emitter + GPU instance buffer per particle object. `prewarm` spreads spawn before first present.
final class WPEParticleSystem {
    let definition: WPEParticleDefinition
    let capacity: Int
    let blendMode: WPEParticleBlendMode
    let sceneTransform: WPEParticleSceneTransform
    private let instanceBuffers: [MTLBuffer]
    private var activeFrameSlot = 0
    var instanceBuffer: MTLBuffer { instanceBuffers[activeFrameSlot] }
    /// True for a `renderer: [{name:"rope"}]` ribbon/trail. When set, `tick`
    let isRope: Bool
    /// True for `ropetrail`: every particle drags its OWN position-history ribbon
    /// (as opposed to `isRope`, one ribbon threaded through the whole pool).
    let usesTrailRibbon: Bool
    /// Either ribbon flavour draws through the rope vertex buffer + shader.
    var usesRibbonGeometry: Bool { isRope || usesTrailRibbon }
    /// Ribbon points per particle for `usesTrailRibbon` = `subdivision` segments + 1.
    /// 0 when the system draws sprites.
    private let trailPointCount: Int
    /// Per-tick path samples the ribbon is resampled from — a ring per particle,
    /// `capacity * trailSampleCapacity` entries. Parallel to `particles` rather
    /// than a member of it: `Particle` is already 20 fields and Swift has no
    /// inline fixed-size array.
    private var trailSamples: [SIMD2<Float>] = []
    /// Ring index of each particle's newest sample.
    private var trailSampleHead: [Int] = []
    /// How many of each particle's ring slots hold real samples (a just-spawned
    /// particle has 1, so its ribbon starts collapsed and grows into its length).
    private var trailSampleFill: [Int] = []
    /// Scratch for one particle's resampled ribbon points; reused every particle.
    private var trailRibbonScratch: [SIMD2<Float>] = []
    /// Ring depth. The ribbon spans `size × clamp(speed·length, 1, maxlength)`,
    /// which for the corpus tops out near 290 px; 48 per-tick samples still cover
    /// that at 120 Hz. Running short only shortens the trail, never corrupts it.
    private static let trailSampleCapacity = 48
    /// Triangle-strip ribbon vertices, allocated only for ribbon systems.
    /// `nil` for ordinary sprite systems.
    private let ropeVertexBuffers: [MTLBuffer]
    /// Vertices the ribbon buffer can hold — the bound of every write into it.
    private let ropeVertexCapacity: Int
    var ropeVertexBuffer: MTLBuffer? {
        ropeVertexBuffers.indices.contains(activeFrameSlot)
            ? ropeVertexBuffers[activeFrameSlot]
            : nil
    }
    /// Live ribbon vertex count written by the last `tick`; 0 ⇒ nothing to draw
    /// (fewer than 2 knots). The executor draws `[0, ropeVertexCount)` as a strip.
    private(set) var ropeVertexCount: Int = 0
    /// Atlas slicing metadata for the sprite texture. `nil` ⇒ single-
    let spriteSheet: WPEParticleSpriteSheet?
    /// Per-axis camera-parallax depth (WPE Vec2) of the owning particle object;
    var parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0)
    /// Emitter origin measured from the scene centre (+y up) — the reference's
    /// static `nodePos - camPos` parallax term.
    var parallaxCenter: SIMD2<Double> = SIMD2<Double>(0, 0)

    #if !LITE_BUILD && DEBUG
    /// Scene identity for trace/dump attribution. `particle-def-N` (build order)
    /// and `particle-state-N` (traceIndex over sorted+filtered systems) never
    /// share an index, so dumps pair by THIS, not by filename number.
    var traceObjectID: String?
    var traceParticlePath: String?
    #endif

    /// Set while `prewarm(presimulateDelay: true)` runs: `startDelay` is a
    /// pre-simulation offset, not a wait, so the emission gate must not hold
    /// spawning back during it. Without this the whole presimulation is a no-op —
    /// 3448877775's snowperspective (starttime 15) came out at 124 = rate x T,
    /// exactly the "treat it as a delay" prediction, against WPE's 344.
    private var presimulatingStartDelay = false
    /// Persists after `endPrewarm`: once `starttime` has been consumed as authored
    /// history, a finite emitter duration remains anchored at virtual time zero
    /// instead of starting a second time at the first live frame.
    private var startDelayWasPresimulated = false
    /// Ancestor transform-host origin shift; folded into projection.padding.xy like camera parallax.
    var hostOriginOffset: SIMD2<Float> = SIMD2<Float>(0, 0)
    /// This emitter's ancestor object ids (nearest first), used to look up their
    /// live origins each frame.
    var hostAncestorIDs: [String] = []
    /// Owning particle object's WPE scene paint index — where this system
    /// composites relative to image layers (background behind, character front).
    var sortIndex: Int = 0
    /// Material `ui_editor_properties_overbright` colour multiplier (>1 brighter,
    /// <1 dimmer). Bound into the fragment uniform; defaults to 1 (no change).
    var overbright: Float = 1.0
    /// `genericparticle` REFRACT: draw via the screen-space refraction pipeline
    var isRefract: Bool = false
    /// `g_RefractAmount` — screen-UV refraction offset scale (WPE default 0.05).
    var refractAmount: Float = 0.05
    /// Nested child: sprite size uses child scale (not owner layer); spawn positions still use model matrix.
    var isNestedChildSystem: Bool = false
    /// Parent composelayer opacity mask; fragment multiplies sprite alpha at screen position.
    var groupOpacityMask: MTLTexture?
    /// Colour multiplier baked from the parent composelayer's tint effect
    /// (1,1,1 = no tint). Applied in the particle fragment.
    var groupTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    /// Live cursor in centered Y-up frame (nil if Follow Cursor off); drives pointer-locked control points.
    var pointerCentered: SIMD2<Float>?

    /// eventfollow: parent live particle position injected as control point id 1 each frame.
    weak var followParent: WPEParticleSystem?
    var followControlPointID: Int = 1
    var requiresFollowParent: Bool = false
    var injectedControlPoints: [Int: SIMD3<Float>] = [:]
    /// WPE child `probability`, for event-driven children only: the chance this
    /// system bursts on any ONE parent event. Rolled per event, not per scene —
    /// see `WPEParticleChildReference.probability`. 1 for every other system.
    var spawnProbability: Double = 1
    /// Render-space birth positions of everything spawned during the last
    /// `advance`. An `eventfollow` child bursts once per entry, which is what
    /// makes every meteor get its own glow instead of only the first one.
    /// Cleared at the top of each `advance` so consumers see exactly one tick.
    private(set) var spawnEventsThisTick: [SIMD3<Float>] = []

    private let attractors: [WPEParticleControlPointAttractor]
    private let emitterTracksPointer: Bool
    /// Raw control-point offsets keyed by id; pointer-locked ids resolve against
    /// the live cursor, others against the static scene-object transform.
    private let controlPointRawOffsets: [Int: SIMD3<Float>]
    private let pointerLockedControlPointIDs: Set<Int>

    private var aliveCount: Int = 0
    /// Diagnostic: how many particles a control-point attractor pushed/pulled
    private(set) var lastAttractorAffectedCount = 0
    private var particles: [Particle]
    private var spawnAccumulator: Double = 0
    /// One-shot guard for the emitter's `instantaneous` burst, which fires the
    /// first time `elapsed` reaches `startDelay` (explosions/fireworks/seed).
    private var hasEmittedBurst = false
    private var lastTickTime: Double?
    private var firstTickTime: Double?
    private var rng: WPEParticleRNG
    /// Shared turbulentvelocityrandom sample point per system (WPE initializer closure semantics).
    private var turbulentSamplePoint = SIMD3<Double>.zero
    /// Cached gravity in render space (Y-up). Mirrors the velocity rule:
    private let gravity: SIMD3<Float>
    /// oscillateposition sway mask in render space (rotates/scales with object).
    private let oscillatePositionMask: SIMD3<Float>

    /// Pre-uploaded TEXS UV rect buffer (vb index 4); avoids 4 KB setVertexBytes limit.
    let frameRectsBuffer: MTLBuffer?

    /// Hard ceiling so a single emitter can't blow the GPU memory budget.
    /// 8K particles × 48 bytes = 384 KB per system.
    static let absoluteCap = 8192
    /// Perspective near-depth boost: depthScale(z) = 1 + boost * clamp(z/maxDepth).
    static let perspectiveNearBoost: Float = 1.5

    /// Stable per-system oracle seed (FNV-1a — not salted Hasher). Only when oracle mode enabled.
    static func deterministicSeed(workshopID: String, objectID: String, sortIndex: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a 64-bit offset basis
        let prime: UInt64 = 0x0000_0100_0000_01B3  // FNV-1a 64-bit prime
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            hash ^= 0x5C  // '\' separator so mix("a")+mix("b") ≠ mix("ab")
            hash = hash &* prime
        }
        mix(workshopID)
        mix(objectID)
        return hash ^ UInt64(bitPattern: Int64(sortIndex))
    }

    private struct Particle {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var size: Float
        var color: SIMD3<Float>
        var rotationZ: Float
        var angularVelocityZ: Float
        var alphaBase: Float
        var lifetime: Float
        var age: Float       // Float.greatestFiniteMagnitude when slot is free
        /// Per-particle turbulence inputs sampled once at spawn; the
        /// operator pumps a deterministic noise field every frame.
        var turbulenceSpeed: Float
        var turbulencePhase: Float
        /// Sprite-sheet frame this particle locks onto when the system is
        var staticFrame: Float
        /// Per-particle `oscillateposition` inputs sampled once at spawn
        var oscPosFrequency: Float
        var oscPosScale: Float
        var oscPosPhase: Float
        /// Per-particle `oscillatealpha` draw (WPE randomizes both per particle,
        /// which is what keeps a star field twinkling out of phase).
        var oscAlphaFrequency: Float
        var oscAlphaPhase: Float
        /// Per-particle `oscillatesize` draw — same story, on the sprite quad.
        var oscSizeFrequency: Float
        var oscSizePhase: Float
    }

    init?(
        definition: WPEParticleDefinition,
        device: MTLDevice,
        blendMode: WPEParticleBlendMode = .translucent,
        sceneTransform: WPEParticleSceneTransform = .identity,
        spriteSheet: WPEParticleSpriteSheet? = nil,
        seed: UInt64? = nil
    ) {
        self.definition = definition
        self.blendMode = blendMode
        self.sceneTransform = sceneTransform
        self.spriteSheet = spriteSheet
        let cap = max(1, min(definition.maxCount, Self.absoluteCap))
        self.capacity = cap
        self.particles = .init(repeating: Particle(
            position: .zero,
            velocity: .zero,
            size: 0,
            color: SIMD3(1, 1, 1),
            rotationZ: 0,
            angularVelocityZ: 0,
            alphaBase: 1,
            lifetime: 0,
            age: .greatestFiniteMagnitude,
            turbulenceSpeed: 0,
            turbulencePhase: 0,
            staticFrame: 0,
            oscPosFrequency: 0,
            oscPosScale: 0,
            oscPosPhase: 0,
            oscAlphaFrequency: 0,
            oscAlphaPhase: 0,
            oscSizeFrequency: 0,
            oscSizePhase: 0
        ), count: cap)
        var instanceBuffers: [MTLBuffer] = []
        instanceBuffers.reserveCapacity(WPEMetalRenderExecutor.maxFramesInFlight)
        for slot in 0..<WPEMetalRenderExecutor.maxFramesInFlight {
            guard let buffer = device.makeBuffer(
                length: cap * MemoryLayout<WPEParticleInstance>.stride,
                options: [.storageModeShared]
            ) else {
                return nil
            }
            buffer.label = "WPE particle instances \(slot)"
            instanceBuffers.append(buffer)
        }
        self.instanceBuffers = instanceBuffers
        self.isRope = definition.isRope
        let usesTrailRibbon = definition.usesTrailRibbon
        self.usesTrailRibbon = usesTrailRibbon
        let trailPoints: Int
        if usesTrailRibbon, let trail = definition.trailRenderer {
            // `subdivision` is the SEGMENT count, so points = segments + 1. Clamped:
            // 1 segment can't form a ribbon, and 8 keeps the per-frame shift cheap.
            let segments = max(1, Int(trail.subdivision.rounded()))
            trailPoints = min(max(segments + 1, 2), 8)
        } else {
            trailPoints = 0
        }
        self.trailPointCount = trailPoints
        if definition.isRope || usesTrailRibbon {
            // rope: 2 edge vertices per knot. ropetrail: 2 per history point plus a
            // 2-vertex degenerate bridge joining each particle's ribbon to the next.
            let vertexCapacity = definition.isRope ? cap * 2 : cap * (trailPoints * 2 + 2)
            self.ropeVertexCapacity = vertexCapacity
            // A partial allocation degrades the whole ribbon to "no draw" rather
            // than exposing an unsafe slot.
            var ropeBuffers: [MTLBuffer] = []
            ropeBuffers.reserveCapacity(WPEMetalRenderExecutor.maxFramesInFlight)
            for slot in 0..<WPEMetalRenderExecutor.maxFramesInFlight {
                guard let ropeBuffer = device.makeBuffer(
                    length: vertexCapacity * MemoryLayout<WPEParticleRopeVertex>.stride,
                    options: [.storageModeShared]
                ) else {
                    ropeBuffers.removeAll()
                    break
                }
                ropeBuffer.label = "WPE particle rope strip \(slot)"
                ropeBuffers.append(ropeBuffer)
            }
            self.ropeVertexBuffers = ropeBuffers
        } else {
            self.ropeVertexBuffers = []
            self.ropeVertexCapacity = 0
        }
        if trailPoints > 0 {
            self.trailSamples = .init(repeating: .zero, count: cap * Self.trailSampleCapacity)
            self.trailSampleHead = .init(repeating: 0, count: cap)
            self.trailSampleFill = .init(repeating: 0, count: cap)
            self.trailRibbonScratch = .init(repeating: .zero, count: trailPoints)
        }
        // Production (seed == nil) keeps the system CSPRNG, byte-for-byte the
        if let seed {
            self.rng = .seeded(SplitMix64(seed: seed))
        } else {
            self.rng = .system(SystemRandomNumberGenerator())
        }
        // Y-up author space: gravity is used as authored (no flip), then
        // honored through the scene object's scale/rotation like velocity.
        let localGravity = SIMD3<Float>(
            Float(definition.gravity.x),
            Float(definition.gravity.y),
            Float(definition.gravity.z)
        )
        self.gravity = sceneTransform.applyModelDirection(localGravity)
        if let osc = definition.oscillatePosition {
            // WPE mask gates axes (threshold), does not scale them (snowperspective 1 0.5 0).
            let gate = SIMD3<Float>(
                osc.mask.x < 0.01 ? 0 : 1,
                osc.mask.y < 0.01 ? 0 : 1,
                osc.mask.z < 0.01 ? 0 : 1
            )
            self.oscillatePositionMask = sceneTransform.applyModelDirection(gate)
        } else {
            self.oscillatePositionMask = .zero
        }
        if let rects = spriteSheet?.frameRects, !rects.isEmpty {
            // Upload once; a failed allocation degrades to uniform-grid slicing
            // rather than failing the whole system.
            let buffer = rects.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: [.storageModeShared])
            }
            buffer?.label = "WPE particle frame rects"
            self.frameRectsBuffer = buffer
        } else {
            self.frameRectsBuffer = nil
        }
        self.attractors = definition.attractors
        self.emitterTracksPointer = definition.emitterTracksPointer
        var offsets: [Int: SIMD3<Float>] = [:]
        var pointerIDs: Set<Int> = []
        for cp in definition.controlPoints {
            offsets[cp.id] = SIMD3<Float>(Float(cp.offset.x), Float(cp.offset.y), Float(cp.offset.z))
            if cp.pointerLocked { pointerIDs.insert(cp.id) }
        }
        self.controlPointRawOffsets = offsets
        self.pointerLockedControlPointIDs = pointerIDs
        // Drawn only for systems that actually have the initializer, so every
        // other system's spawn draw sequence stays byte-identical for the oracle.
        if definition.turbulentVelocityInit != nil {
            turbulentSamplePoint = SIMD3<Double>(
                Double.random(in: 0..<10, using: &rng),
                Double.random(in: 0..<10, using: &rng),
                Double.random(in: 0..<10, using: &rng)
            )
        }
    }

    /// Control point in centered frame; injected event-follow wins; pointer-locked follows cursor.
    func controlPointPosition(_ id: Int) -> SIMD3<Float>? {
        if let injected = injectedControlPoints[id] { return injected }
        if requiresFollowParent && id == followControlPointID { return nil }
        let rawOffset = controlPointRawOffsets[id] ?? .zero
        if pointerLockedControlPointIDs.contains(id) {
            guard let p = pointerCentered else { return nil }
            return SIMD3<Float>(p.x, p.y, 0) + sceneTransform.applyModelDirection(rawOffset)
        }
        return sceneTransform.applyModelMatrix(toLocalPoint: rawOffset)
    }

    /// Cursor-reactivity diagnostic snapshot; nil if system has no cursor interaction.
    #if DEBUG
    func cursorDebugSummary() -> String? {
        guard !attractors.isEmpty || !pointerLockedControlPointIDs.isEmpty else { return nil }
        func fmt(_ v: SIMD3<Float>?) -> String {
            v.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil"
        }
        let lockedCPs = pointerLockedControlPointIDs.sorted()
        let resolved = lockedCPs.map { "cp\($0)=\(fmt(controlPointPosition($0)))" }.joined(separator: " ")
        return "alive=\(aliveCount) attractors=\(attractors.count) "
            + "pointerLocked=[\(resolved)] affectedLastTick=\(lastAttractorAffectedCount)"
    }
    #endif

    private func uniform(_ low: Double, _ high: Double) -> Double {
        // WPE range endpoints are unordered; sorting avoids pinning reversed ranges
        // to one endpoint.
        let lo = Swift.min(low, high)
        let hi = Swift.max(low, high)
        guard hi > lo else { return lo }
        let r = Double.random(in: 0...1, using: &rng)
        return lo + (hi - lo) * r
    }

    private func uniformVector(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(uniform(low.x, high.x)),
            Float(uniform(low.y, high.y)),
            Float(uniform(low.z, high.z))
        )
    }

    /// Box–Muller transform over the existing spawn `rng` — matches `std::
    private func gaussian(mean: Double, stddev: Double) -> Double {
        let u1 = Swift.max(Double.leastNormalMagnitude, Double.random(in: 0..<1, using: &rng))
        let u2 = Double.random(in: 0..<1, using: &rng)
        let mag = (-2 * log(u1)).squareRoot()
        return mean + stddev * mag * cos(2 * Double.pi * u2)
    }

    /// colorrandom: single t lerps all channels (WPE Color()) — not per-channel draws.
    private func lerpVector(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> SIMD3<Float> {
        let t = uniform(0, 1)
        return SIMD3<Float>(
            Float(low.x + (high.x - low.x) * t),
            Float(low.y + (high.y - low.y) * t),
            Float(low.z + (high.z - low.z) * t)
        )
    }

    /// Volume-uniform sphere radius: lerp(pow(rand, 1/3), min, max) (WPE ParticleSphereEmitter).
    static func sphereRadius(min: Double, max: Double, uniform01: Double) -> Double {
        let t = pow(Swift.max(0, Swift.min(1, uniform01)), 1.0 / 3.0)
        return min + t * (max - min)
    }

    /// GenSphereSurfaceNormal: N(0, directions.axis) per positive axis, then normalize.
    static func sphereSurfaceDirection(
        directions: SIMD3<Double>,
        gaussian: (_ mean: Double, _ stddev: Double) -> Double
    ) -> SIMD3<Double> {
        let u = directions.x > 0 ? gaussian(0, directions.x) : 0
        let v = directions.y > 0 ? gaussian(0, directions.y) : 0
        let w = directions.z > 0 ? gaussian(0, directions.z) : 0
        let norm = (u * u + v * v + w * w).squareRoot()
        // All axes disabled (or, astronomically unlikely, all three Gaussian
        guard norm > 0 else { return SIMD3<Double>(0, 0, 0) }
        return SIMD3<Double>(u, v, w) / norm
    }

    /// ApplySign: nonzero axis forces abs(value)*sign; zero axis passes sample through.
    static func applyEmitterSign(_ p: SIMD3<Double>, sign: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            sign.x != 0 ? Swift.abs(p.x) * sign.x : p.x,
            sign.y != 0 ? Swift.abs(p.y) * sign.y : p.y,
            sign.z != 0 ? Swift.abs(p.z) * sign.z : p.z
        )
    }

    static func emitterRadialVelocity(dispersal: SIMD3<Float>, speed: Float) -> SIMD3<Float> {
        let length = simd_length(dispersal)
        guard length > 0.000_001, speed != 0 else { return .zero }
        return dispersal / length * speed
    }

    /// Prewarm simulator without GPU write so first present already has a spread population.
    /// `presimulateDelay: true` drops the dead zone: WPE documents `starttime` as
    /// "pre-simulate the particle system … as if it has already been running for
    /// the configured time", not as a wait. Measured against RenderDoc —
    /// 3448877775's snowperspective (starttime 15) holds 344 particles at frame
    /// time 4.851s, where a dead zone predicts 121; 3521337568's starttime-200
    /// system holds 1251 at 13.4s. Both the oracle and the live path pass true —
    /// see `particlePrewarmSeconds`, which feeds each its own window.
    func prewarm(simulatedSeconds: Double, step: Double = 1.0 / 60,
                 presimulateDelay: Bool = false) {
        guard step > 0,
              let range = beginPrewarm(simulatedSeconds: simulatedSeconds,
                                       presimulateDelay: presimulateDelay)
        else { return }
        var virtualNow = range.lowerBound
        let substeps = Int(((range.upperBound - virtualNow) / step).rounded(.up))
        for _ in 0..<substeps {
            virtualNow = min(range.upperBound, virtualNow + step)
            prewarmStep(to: virtualNow)
        }
        endPrewarm()
    }

    /// Virtual time of the last `prewarmStep`; non-nil only between
    /// `beginPrewarm` and `endPrewarm`.
    private var prewarmVirtualNow: Double?

    /// Set up tick bookkeeping and return the virtual-time span this system will
    /// step, or nil when there is nothing to simulate. Split out of `prewarm` so
    /// an `eventfollow` chain can be driven in lockstep — see
    /// `prewarmParticleSystems`.
    ///
    /// `convergenceSeconds` overrides how far back the simulation actually has to
    /// run (a follow chain passes the chain-wide value so a child never starts
    /// before the parent it rides). The returned span starts at the first instant
    /// that can still affect the end state — see `prewarmConvergenceStart`.
    func beginPrewarm(
        simulatedSeconds: Double,
        presimulateDelay: Bool,
        convergenceSeconds: Double? = nil
    ) -> ClosedRange<Double>? {
        guard simulatedSeconds > 0,
              definition.rate > 0 || definition.instantaneousCount > 0 else { return nil }
        presimulatingStartDelay = presimulateDelay
        if presimulateDelay { startDelayWasPresimulated = true }
        let delay = presimulateDelay ? 0 : max(0, definition.startDelay)
        let activeStart = min(delay, simulatedSeconds)
        if simulatedSeconds <= activeStart {
            presimulatingStartDelay = false
            firstTickTime = -simulatedSeconds
            lastTickTime = 0
            return nil
        }
        let simulationStart = prewarmConvergenceStart(
            activeStart: activeStart,
            simulatedSeconds: simulatedSeconds,
            convergenceSeconds: convergenceSeconds
        )
        // The clock anchor stays at the TRUE start even when the head is skipped,
        // so `systemElapsed` (which drives `overrideAlphaAnimation` and the
        // startDelay gate) still reads the full window.
        firstTickTime = 0
        lastTickTime = simulationStart
        prewarmVirtualNow = simulationStart
        if simulationStart > activeStart {
            // The one-shot `instantaneous` burst fires at `activeStart`; skipping
            // the head means its particles are already past `lifetimeMax` and
            // dead, so it must NOT re-fire at the truncated start.
            hasEmittedBurst = true
        }
        return simulationStart...simulatedSeconds
    }

    /// First instant that can still affect the end of the prewarm window.
    /// Everything alive at `simulatedSeconds` was born within the last
    /// `lifetimeMax` seconds, so simulating earlier is a treadmill: measured
    /// (optimized build) 455 ms → 59.7 ms on a heavy `starttime: 200` emitter,
    /// population unchanged at ~3500. A system whose authored lifetime exceeds
    /// the window skips nothing — the 15 s control case stayed at 35 ms.
    private func prewarmConvergenceStart(
        activeStart: Double,
        simulatedSeconds: Double,
        convergenceSeconds: Double?
    ) -> Double {
        // The system's OWN lifetime is always a lower bound — a chain-wide value
        // may only extend the window, never truncate a longer-lived member.
        // Floor of 1s: a degenerate lifetimeMax of 0 must still leave real steps.
        let converged = max(convergenceSeconds ?? 0, definition.lifetimeMax, 1.0)
        guard converged.isFinite else { return activeStart }
        return max(activeStart, simulatedSeconds - converged)
    }

    /// One prewarm substep at `virtualNow` (this system's own clock).
    func prewarmStep(to virtualNow: Double) {
        guard prewarmVirtualNow != nil else { return }
        prewarmVirtualNow = virtualNow
        advance(now: virtualNow)
    }

    func endPrewarm() {
        guard let virtualNow = prewarmVirtualNow else { return }
        prewarmVirtualNow = nil
        presimulatingStartDelay = false
        // Re-anchor tick bookkeeping after prewarm so live frames don't freeze until wall time catches up.
        firstTickTime = -virtualNow
        lastTickTime = 0
        // Drop the prewarm-era spawn events so the first real frame doesn't
        // replay births the follow children already consumed during prewarm —
        // dozens of flashes at positions the parent particles have long since
        // left. Their effects are short-lived (3–4s in 3413921910) and the
        // parent keeps spawning, so nothing is lost for long.
        spawnEventsThisTick.removeAll()
    }

    /// Shared draw attrs for sprite/rope: alpha envelope, size, tint, sway position.
    private func drawAttributes(
        of particle: Particle
    ) -> (position: SIMD3<Float>, rgb: SIMD3<Float>, alpha: Float, size: Float, lifetimeFraction: Float) {
        let envelope = fadeEnvelope(age: particle.age, lifetime: particle.lifetime)
        let lifetimeFraction = particle.lifetime > 0 ? min(1, max(0, particle.age / particle.lifetime)) : 0
        var alpha = particle.alphaBase * envelope
        if let alphaChange = definition.alphaChange {
            alpha *= Float(alphaChange.factor(lifetimeFraction: Double(lifetimeFraction)))
        }
        if let overrideAlpha = definition.overrideAlphaAnimation,
           let scale = overrideAlpha.scalar(at: systemElapsed) {
            alpha *= Float(max(0, scale))
        }
        if let oscillateAlpha = definition.oscillateAlpha {
            alpha *= Float(oscillateAlpha.factor(
                age: Double(particle.age),
                frequency: Double(particle.oscAlphaFrequency),
                phase: Double(particle.oscAlphaPhase)
            ))
        }
        alpha = min(max(alpha, 0), 1)
        // `sizechange`: lifetime-fraction multiplier on the sprite quad.
        var spriteSize = particle.size
        if let sizeChange = definition.sizeChange {
            spriteSize *= Float(sizeChange.factor(lifetimeFraction: Double(lifetimeFraction)))
        }
        if let oscillateSize = definition.oscillateSize {
            spriteSize *= Float(oscillateSize.factor(
                age: Double(particle.age),
                frequency: Double(particle.oscSizeFrequency),
                phase: Double(particle.oscSizePhase)
            ))
        }
        // Re-apply the additive cap on the FINAL size: `sizechange` can grow
        // the sprite past the spawn-time cap and re-hit the saturation path.
        if blendMode == .additive {
            spriteSize = min(spriteSize, sceneTransform.sceneHeight)
        }
        // colorchange RGB multiplier only when a colour initializer was authored.
        var rgb = particle.color
        if definition.hasColorInitializer, let colorChange = definition.colorChange {
            let c = colorChange.color(lifetimeFraction: Double(lifetimeFraction))
            rgb *= SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        }
        // `oscillateposition`: transient sine sway (never integrated into
        // the stored position, so the particle sways without drifting).
        var drawPosition = particle.position
        if particle.oscPosScale != 0, particle.oscPosFrequency != 0 {
            // frequency is angular rate (rad/s); phase in radians — do not multiply an extra 2π.
            let sway = sin(particle.age * particle.oscPosFrequency + particle.oscPosPhase)
            drawPosition += oscillatePositionMask * (sway * particle.oscPosScale)
        }
        // Perspective (`flags & 4`): project draw position + size through a depth
        if definition.isPerspective {
            let scale = perspectiveDepthScale(depth: particle.position.z)
            let vp = sceneTransform.renderOrigin
            drawPosition = SIMD3<Float>(
                vp.x + (drawPosition.x - vp.x) * scale,
                vp.y + (drawPosition.y - vp.y) * scale,
                drawPosition.z
            )
            spriteSize *= scale
        }
        return (drawPosition, rgb, alpha, spriteSize, lifetimeFraction)
    }

    /// depthScale in [1, 1+boost]; drives sprite size and draw-position projection.
    private func perspectiveDepthScale(depth z: Float) -> Float {
        let maxDepth = perspectiveDepthExtent()
        let t = min(max(z / maxDepth, 0), 1)
        return 1 + Self.perspectiveNearBoost * t
    }

    private func perspectiveDepthExtent() -> Float {
        let localSpawnDepth: Double
        switch definition.emitterShape {
        case .box:
            localSpawnDepth = abs(definition.dispersalMax.z)
        case .sphere:
            localSpawnDepth = abs(definition.dispersalMax.z * definition.directionMask.z)
        }
        let spawnDepth = Float(localSpawnDepth) * max(0.0001, abs(sceneTransform.objectScale.z))
        let lifetime = Float(max(definition.lifetimeMin, definition.lifetimeMax, 0))
        let localVelocityMin = SIMD3<Float>(
            Float(definition.velocityMin.x),
            Float(definition.velocityMin.y),
            Float(definition.velocityMin.z)
        )
        let localVelocityMax = SIMD3<Float>(
            Float(definition.velocityMax.x),
            Float(definition.velocityMax.y),
            Float(definition.velocityMax.z)
        )
        let velocityDepth = max(
            abs(sceneTransform.applyModelDirection(localVelocityMin).z),
            abs(sceneTransform.applyModelDirection(localVelocityMax).z)
        ) * lifetime
        let gravityDepth = abs(gravity.z) * lifetime * lifetime * 0.5
        return max(1, spawnDepth, velocityDepth, gravityDepth)
    }

    func tick(now: Double, frameSlot: Int = 0) {
        precondition(instanceBuffers.indices.contains(frameSlot))
        activeFrameSlot = frameSlot
        advance(now: now)
        if isRope {
            buildRopeGeometry()
            return
        }
        if usesTrailRibbon {
            buildTrailGeometry()
            return
        }
        let pointer = instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: capacity)
        // sequence = lifetime-relative cycles; random/once pick a fixed frame at spawn.
        let frameCount: Float = Float(max(1, spriteSheet?.frameCount ?? 1))
        let animatesSequence = definition.animationMode == .sequence && frameCount > 1
        let cyclesPerLifetime = max(0.0001, Float(definition.sequenceMultiplier))
        let visualScaleSigns = sceneTransform.visualScaleSigns()
        var written = 0
        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            let particle = particles[index]
            let attrs = drawAttributes(of: particle)
            let lifetimeFraction = attrs.lifetimeFraction
            let alpha = attrs.alpha
            let spriteSize = attrs.size
            let rgb = attrs.rgb
            let drawPosition = attrs.position
            let frameIndex: Float
            if animatesSequence {
                let raw = lifetimeFraction * cyclesPerLifetime * frameCount
                frameIndex = raw.truncatingRemainder(dividingBy: frameCount)
            } else {
                // `.randomFrame` (or single-frame sprite): the spawn-time
                frameIndex = particle.staticFrame
            }
            pointer[written] = WPEParticleInstance(
                positionAndSize: SIMD4<Float>(
                    drawPosition.x, drawPosition.y, visualScaleSigns.x, spriteSize
                ),
                color: SIMD4<Float>(rgb.x, rgb.y, rgb.z, alpha),
                rotationAndLife: SIMD4<Float>(particle.rotationZ, lifetimeFraction, frameIndex, visualScaleSigns.y),
                velocity: SIMD4<Float>(particle.velocity.x, particle.velocity.y, 0, 0)
            )
            written += 1
        }
        aliveCount = written
    }

    /// Rope ribbon: age-order knots, ±half-size along segment normal; coincident knots → zero area.
    private func buildRopeGeometry() {
        guard let buffer = ropeVertexBuffer else {
            aliveCount = 0
            ropeVertexCount = 0
            return
        }
        var knots: [(position: SIMD2<Float>, color: SIMD4<Float>, halfSize: Float, age: Float)] = []
        knots.reserveCapacity(capacity)
        for index in 0..<capacity {
            let particle = particles[index]
            guard particle.age != .greatestFiniteMagnitude else { continue }
            let attrs = drawAttributes(of: particle)
            knots.append((
                SIMD2<Float>(attrs.position.x, attrs.position.y),
                SIMD4<Float>(attrs.rgb.x, attrs.rgb.y, attrs.rgb.z, attrs.alpha),
                max(0, attrs.size * 0.5),
                particle.age
            ))
        }
        aliveCount = knots.count
        guard knots.count >= 2 else {
            ropeVertexCount = 0
            return
        }
        knots.sort { $0.age < $1.age }

        let verts = buffer.contents().bindMemory(to: WPEParticleRopeVertex.self, capacity: capacity * 2)
        let count = knots.count
        // Carry the last valid normal across degenerate (coincident) segments so
        // a momentary overlap doesn't collapse the ribbon to a spike.
        var lastNormal = SIMD2<Float>(0, 1)
        var written = 0
        for i in 0..<count {
            let prev = knots[max(0, i - 1)].position
            let next = knots[min(count - 1, i + 1)].position
            let tangent = next - prev
            let length = (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot()
            var normal = lastNormal
            if length > 1e-4 {
                let unit = tangent / length
                normal = SIMD2<Float>(-unit.y, unit.x)
                lastNormal = normal
            }
            let knot = knots[i]
            let offset = normal * knot.halfSize
            let along = Float(i) / Float(count - 1)   // v runs 0→1 head→tail
            verts[written] = WPEParticleRopeVertex(
                positionUV: SIMD4<Float>(knot.position.x + offset.x, knot.position.y + offset.y, 0, along),
                color: knot.color
            )
            verts[written + 1] = WPEParticleRopeVertex(
                positionUV: SIMD4<Float>(knot.position.x - offset.x, knot.position.y - offset.y, 1, along),
                color: knot.color
            )
            written += 2
        }
        ropeVertexCount = written
    }

    /// `ropetrail`: one ribbon per particle through its own position history,
    /// all packed into a single triangle strip joined by degenerate bridges.
    private func buildTrailGeometry() {
        guard let buffer = ropeVertexBuffer, trailPointCount >= 2 else {
            aliveCount = 0
            ropeVertexCount = 0
            return
        }
        let verts = buffer.contents()
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: ropeVertexCapacity)
        let pointCount = trailPointCount
        let perRibbon = pointCount * 2 + 2
        var written = 0
        var live = 0
        for index in 0..<capacity {
            let particle = particles[index]
            guard particle.age != .greatestFiniteMagnitude else { continue }
            live += 1
            guard written + perRibbon <= ropeVertexCapacity else { continue }
            let attrs = drawAttributes(of: particle)
            let color = SIMD4<Float>(attrs.rgb.x, attrs.rgb.y, attrs.rgb.z, attrs.alpha)
            let halfSize = max(0, attrs.size * 0.5)
            resampleTrailRibbon(index, size: attrs.size, velocity: particle.velocity)
            // The strip is continuous, so every ribbon after the first is joined to
            // the previous one by two repeated vertices (zero-area triangles).
            let bridges = written > 0
            let ribbonStart = written + (bridges ? 2 : 0)
            var cursor = ribbonStart
            // Same tangent/normal construction as `buildRopeGeometry`, including
            // carrying the last valid normal across coincident points.
            var lastNormal = SIMD2<Float>(0, 1)
            for point in 0..<pointCount {
                let prev = trailRibbonScratch[max(0, point - 1)]
                let next = trailRibbonScratch[min(pointCount - 1, point + 1)]
                // Points run newest→oldest, so the tangent points backwards along
                // travel; the normal is perpendicular either way.
                let tangent = next - prev
                let length = (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot()
                var normal = lastNormal
                if length > 1e-4 {
                    let unit = tangent / length
                    normal = SIMD2<Float>(-unit.y, unit.x)
                    lastNormal = normal
                }
                let position = trailRibbonScratch[point]
                let offset = normal * halfSize
                let along = Float(point) / Float(pointCount - 1)   // v runs 0→1 head→tail
                verts[cursor] = WPEParticleRopeVertex(
                    positionUV: SIMD4<Float>(position.x + offset.x, position.y + offset.y, 0, along),
                    color: color
                )
                verts[cursor + 1] = WPEParticleRopeVertex(
                    positionUV: SIMD4<Float>(position.x - offset.x, position.y - offset.y, 1, along),
                    color: color
                )
                cursor += 2
            }
            if bridges {
                verts[written] = verts[written - 1]
                verts[written + 1] = verts[ribbonStart]
            }
            written = cursor
        }
        aliveCount = live
        ropeVertexCount = written
    }

    /// Record this particle's current position as the newest ring sample.
    ///
    /// Stores the integrated position, not `drawAttributes`' — so an `oscillateposition`
    /// ribbon would trail straight while its sprite sways. None of the 10 corpus
    /// `ropetrail` definitions carries that operator (all are movement+alphafade,
    /// one adds controlpointattract), so nothing exercises the gap today.
    private func pushTrailPoint(_ index: Int) {
        let ring = Self.trailSampleCapacity
        let head = (trailSampleHead[index] + 1) % ring
        trailSampleHead[index] = head
        trailSamples[index * ring + head] = SIMD2<Float>(
            particles[index].position.x, particles[index].position.y
        )
        trailSampleFill[index] = min(trailSampleFill[index] + 1, ring)
    }

    /// Collapse a slot's path onto the spawn point. Without this the ribbon draws
    /// from the world origin on the first frame, and a reused slot inherits the
    /// previous particle's path.
    private func resetTrailHistory(_ index: Int, to position: SIMD3<Float>) {
        trailSampleHead[index] = 0
        trailSampleFill[index] = 1
        trailSamples[index * Self.trailSampleCapacity] = SIMD2<Float>(position.x, position.y)
    }

    /// `back` samples before the newest one, clamped to what the ring holds.
    private func trailSample(_ index: Int, back: Int) -> SIMD2<Float> {
        let ring = Self.trailSampleCapacity
        let step = min(back, max(0, trailSampleFill[index] - 1))
        let slot = ((trailSampleHead[index] - step) % ring + ring) % ring
        return trailSamples[index * ring + slot]
    }

    /// Walk the particle's recorded path backwards and drop `trailPointCount`
    /// points at even arc-length intervals spanning the authored trail length.
    ///
    /// WPE's own reference scenes for BOTH trail renderers
    /// (`assets/scenes/particleelementpreviews/{ropetrail,spritetrail}`) author
    /// only `length`, never `subdivision` or `maxlength`, and the corpus spreads
    /// `length` over 0.2…3 — so `length` is what sets how far back the ribbon
    /// reaches, exactly as it does for `spritetrail` (`ComputeParticleTrailTangents`:
    /// `clamp(speed·length, minlen, maxlength)` multiplying the sprite size).
    /// `subdivision` only says how many segments that span is cut into.
    ///
    /// Sampling per tick and resampling by DISTANCE keeps the ribbon's world
    /// length frame-rate independent; only the smoothness varies with frame rate.
    private func resampleTrailRibbon(_ index: Int, size: Float, velocity: SIMD3<Float>) {
        let pointCount = trailPointCount
        let head = trailSample(index, back: 0)
        trailRibbonScratch[0] = head
        guard pointCount > 1 else { return }
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        let trail = definition.trailRenderer
        let lengthCoefficient = Float(trail?.length ?? 0.05)
        let maxStretch = Float(trail?.maxLength ?? 10)
        // The 1 floor is OURS, not WPE's: `spritetrail` passes minlen 0 and lets a
        // stalled particle collapse its quad, but a collapsed RIBBON disappears
        // entirely (scene 3426865175 parks meteors on a control point). One sprite
        // size is the shortest ribbon that still reads as the sprite it's made of.
        let stretch = max(1, min(speed * lengthCoefficient, maxStretch))
        let spacing = max(size, 0) * stretch / Float(pointCount - 1)
        guard spacing > 1e-4 else {
            for point in 1..<pointCount { trailRibbonScratch[point] = head }
            return
        }
        var target = spacing
        var point = 1
        var travelled: Float = 0
        var current = head
        var back = 1
        let oldest = max(0, trailSampleFill[index] - 1)
        while point < pointCount, back <= oldest {
            let previous = trailSample(index, back: back)
            let step = previous - current
            let stepLength = (step.x * step.x + step.y * step.y).squareRoot()
            if stepLength > 1e-6 {
                // Emit every ribbon point that falls inside this path segment.
                while point < pointCount, target <= travelled + stepLength {
                    let t = (target - travelled) / stepLength
                    trailRibbonScratch[point] = current + step * t
                    point += 1
                    target += spacing
                }
                travelled += stepLength
            }
            current = previous
            back += 1
        }
        // Ran out of recorded path (a young particle, or a trail longer than the
        // ring): pin the rest to the oldest sample so the ribbon grows in from the
        // spawn point instead of reaching back to somewhere it has never been.
        while point < pointCount {
            trailRibbonScratch[point] = current
            point += 1
        }
    }

    var liveInstanceCount: Int { aliveCount }

    /// True when control point 0 follows the cursor (particles spawn at the
    var tracksPointer: Bool { emitterTracksPointer }

    /// Kill all live particles + emission backlog (Follow Cursor off must clear pointer spawns now).
    func clearLiveParticles() {
        for index in 0..<capacity {
            particles[index].age = .greatestFiniteMagnitude
        }
        aliveCount = 0
        spawnAccumulator = 0
    }

    /// Representative live particle in render-frame coordinates, used as the
    var primaryLiveParticlePosition: SIMD3<Float>? {
        var bestPosition: SIMD3<Float>?
        var bestAge = Float.greatestFiniteMagnitude
        for particle in particles where particle.age != .greatestFiniteMagnitude && particle.age < bestAge {
            bestAge = particle.age
            bestPosition = particle.position
        }
        return bestPosition
    }

    /// Integrate every alive particle and spawn new ones. Split from
    private var systemElapsed: Double = 0

    private func advance(now: Double) {
        spawnEventsThisTick.removeAll(keepingCapacity: true)
        defer { lastTickTime = now }
        if firstTickTime == nil { firstTickTime = now }
        let dt: Float
        if let last = lastTickTime {
            dt = Float(max(0, min(now - last, 0.1)))
        } else {
            dt = 0
        }
        let elapsed = now - (firstTickTime ?? now)
        systemElapsed = elapsed
        // WPE's drag is `-2·strength·v` (algorism.h `DragForce`: `-2.0 * speed *
        let dragScalar: Float = max(0, 1 - 2 * Float(definition.drag) * dt)
        let angularDragScalar: Float = max(0, 1 - 2 * Float(definition.angularDrag) * dt)
        let angularForce = sceneTransform.visualAngularZ(localAngularZ: Float(definition.angularForceZ))
        // `turbulence` OPERATOR: a per-frame curl-noise wind, applied in render
        let turbulenceOp = definition.turbulence
        let turbulenceScale = turbulenceOp.map { $0.scale * 2 } ?? 0
        let turbulenceTimescale = turbulenceOp.map(\.timescale) ?? 0
        let turbulenceMask = turbulenceOp.map {
            SIMD3<Double>($0.mask.x, $0.mask.y, $0.mask.z)
        } ?? .zero

        var attractorAffectedThisTick = 0
        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            particles[index].age += dt
            if particles[index].age >= particles[index].lifetime {
                particles[index].age = .greatestFiniteMagnitude
                continue
            }
            // Linear motion with gravity + drag.
            particles[index].velocity += gravity * dt
            if dragScalar < 1 { particles[index].velocity *= dragScalar }
            // Control-point attract/repel (cursor follow/avoid). Force points
            if !attractors.isEmpty {
                let pos = particles[index].position
                var affectedThisParticle = false
                for attractor in attractors {
                    guard let cp = controlPointPosition(attractor.controlPointID) else { continue }
                    let dx = cp.x - pos.x
                    let dy = cp.y - pos.y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    let threshold = Float(attractor.threshold)
                    guard dist > 1e-3, dist < threshold else { continue }
                    let falloff = 1 - dist / threshold
                    let accel = Float(attractor.scale) * falloff / dist
                    particles[index].velocity.x += dx * accel * dt
                    particles[index].velocity.y += dy * accel * dt
                    affectedThisParticle = true
                }
                if affectedThisParticle { attractorAffectedThisTick += 1 }
            }
            if turbulenceOp != nil, particles[index].turbulenceSpeed > 0 {
                let pos = particles[index].position
                // Scroll the field along X by phase + timescale·t, then sample the
                // curl direction and accelerate along it (masked per axis).
                let sample = SIMD3<Double>(
                    Double(pos.x) + Double(particles[index].turbulencePhase) + turbulenceTimescale * elapsed,
                    Double(pos.y),
                    Double(pos.z)
                ) * turbulenceScale
                let dir = WPEParticleCurlNoise.direction(at: sample)
                let speed = Double(particles[index].turbulenceSpeed)
                particles[index].velocity.x += Float(dir.x * speed * turbulenceMask.x) * dt
                particles[index].velocity.y += Float(dir.y * speed * turbulenceMask.y) * dt
                particles[index].velocity.z += Float(dir.z * speed * turbulenceMask.z) * dt
            }
            particles[index].position += particles[index].velocity * dt
            // Angular motion with force + drag.
            particles[index].angularVelocityZ += angularForce * dt
            if angularDragScalar < 1 { particles[index].angularVelocityZ *= angularDragScalar }
            particles[index].rotationZ += particles[index].angularVelocityZ * dt
            if trailPointCount > 0 { pushTrailPoint(index) }
        }
        lastAttractorAffectedCount = attractorAffectedThisTick

        // `duration` bounds births only. Existing particles continue integrating
        // and expire through their own lifetime after the emitter has stopped.
        // During authored pre-simulation, starttime is elapsed history rather
        // than a delay, so the duration window begins at virtual time zero.
        let emissionStart = presimulatingStartDelay || startDelayWasPresimulated
            ? 0
            : max(0, definition.startDelay)
        let hasStartedEmitting = presimulatingStartDelay || elapsed >= emissionStart
        let isWithinDuration = definition.duration.map {
            elapsed <= emissionStart + $0
        } ?? true
        if hasStartedEmitting {
            if definition.instantaneousCount > 0 {
                if requiresFollowParent {
                    // eventfollow: burst once per parent birth, not once per system.
                    if isWithinDuration { emitFollowBursts() }
                } else if !hasEmittedBurst,
                          isWithinDuration || (lastTickTime ?? emissionStart) <= emissionStart {
                    // One-time `instantaneous` burst (explosions, fireworks, initial
                    var blocked = false
                    for _ in 0..<definition.instantaneousCount {
                        guard let slot = nextFreeSlot() else { break }
                        if !spawn(into: slot) {
                            // Pointer-locked emitter with no live cursor: retry the
                            // whole burst next tick rather than burning it on a no-op.
                            blocked = true
                            break
                        }
                    }
                    if !blocked { hasEmittedBurst = true }
                }
            }
            // Continuous `rate` emission (particles per second).
            if isWithinDuration, definition.rate > 0 {
                spawnAccumulator += Double(dt) * definition.rate
                while spawnAccumulator >= 1 {
                    spawnAccumulator -= 1
                    guard let slot = nextFreeSlot() else { break }
                    spawn(into: slot)
                }
                // While the pool is saturated (rate × lifetime > maxCount) the
                spawnAccumulator = min(spawnAccumulator, 1)
            }
        }
    }

    #if !LITE_BUILD && DEBUG
    /// Dev-only: per-alive-particle state for oracle comparison against WPE's
    func particleStateDumpText() -> String {
        var lines: [String] = [
            "object=\(traceObjectID ?? "?") particle=\(traceParticlePath ?? "?")",
            "alive=\(liveInstanceCount) speedScale-applied velocity is base; WPE TEXCOORD1=velocity",
            "ribbon: isRope=\(isRope) trailRibbon=\(usesTrailRibbon)"
                + " trailPoints=\(trailPointCount) ropeVerts=\(ropeVertexCount)",
            "(pos.xyz | vel.xyz(base) | size | rotZ | angVelZ | color.rgb | alphaBase"
                + " | turb spd/ph | frame | oscPos f/s/p | oscAlpha f/p | oscSize f/p | age/life)",
        ]
        for p in particles where p.age != .greatestFiniteMagnitude {
            lines.append(String(
                format: "  pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) size=%.1f rotZ=%.2f angVelZ=%.2f"
                    + " rgb=(%.2f,%.2f,%.2f) a=%.2f turb=%.1f/%.2f frame=%.0f"
                    + " oscPos=%.2f/%.2f/%.2f oscA=%.2f/%.2f oscS=%.2f/%.2f age=%.2f/%.2f",
                p.position.x, p.position.y, p.position.z,
                p.velocity.x, p.velocity.y, p.velocity.z,
                p.size, p.rotationZ, p.angularVelocityZ,
                p.color.x, p.color.y, p.color.z, p.alphaBase,
                p.turbulenceSpeed, p.turbulencePhase, p.staticFrame,
                p.oscPosFrequency, p.oscPosScale, p.oscPosPhase,
                p.oscAlphaFrequency, p.oscAlphaPhase,
                p.oscSizeFrequency, p.oscSizePhase,
                p.age, p.lifetime))
        }
        return lines.joined(separator: "\n")
    }

    /// Dev-only: what the GPU actually consumes this frame, as trace records —
    /// the Mac mirror of the Windows trace's decoded `POINTLIST` vertex buffers
    /// (`parse_capture.py decode_draw_vertices`, same 256 cap). Sprite systems
    /// read the compacted instance buffer (draw position, fade-applied alpha);
    /// ribbon systems read the rope strip's knot vertices instead, because the
    /// instance buffer is not what they draw.
    func particleTraceVertices(limit: Int = 256) -> (records: [[String: Any]], truncated: Bool) {
        var records: [[String: Any]] = []
        if usesRibbonGeometry {
            guard let buffer = ropeVertexBuffer, ropeVertexCount > 0 else { return ([], false) }
            let verts = buffer.contents().bindMemory(
                to: WPEParticleRopeVertex.self, capacity: ropeVertexCount)
            let count = min(ropeVertexCount, limit)
            records.reserveCapacity(count)
            for index in 0..<count {
                let vertex = verts[index]
                records.append([
                    "vertexIndex": index,
                    "POSITION": [Double(vertex.positionUV.x), Double(vertex.positionUV.y)],
                    "uv": [Double(vertex.positionUV.z), Double(vertex.positionUV.w)],
                    "COLOR": [Double(vertex.color.x), Double(vertex.color.y),
                              Double(vertex.color.z), Double(vertex.color.w)]
                ])
            }
            return (records, ropeVertexCount > limit)
        }
        let alive = liveInstanceCount
        guard alive > 0 else { return ([], false) }
        let pointer = instanceBuffer.contents().bindMemory(
            to: WPEParticleInstance.self, capacity: alive)
        let count = min(alive, limit)
        records.reserveCapacity(count)
        for index in 0..<count {
            let instance = pointer[index]
            records.append([
                "vertexIndex": index,
                "POSITION": [Double(instance.positionAndSize.x), Double(instance.positionAndSize.y)],
                "size": Double(instance.positionAndSize.w),
                "COLOR": [Double(instance.color.x), Double(instance.color.y),
                          Double(instance.color.z), Double(instance.color.w)],
                "rotation": Double(instance.rotationAndLife.x),
                "lifetimeFraction": Double(instance.rotationAndLife.y),
                "frame": Double(instance.rotationAndLife.z),
                "velocity": [Double(instance.velocity.x), Double(instance.velocity.y)]
            ])
        }
        return (records, alive > limit)
    }
    #endif

    /// alphafade.fadeintime / fadeouttime are **lifetime fractions** in
    private func fadeEnvelope(age: Float, lifetime: Float) -> Float {
        guard lifetime > 0 else { return 1 }
        let fraction = max(0, min(1, age / lifetime))
        let fadeInFrac = Float(min(max(definition.fadeInSeconds, 0), 1))
        let fadeOutFrac = Float(min(max(definition.fadeOutSeconds, 0), 1))
        var value: Float = 1
        if fadeInFrac > 0 && fraction < fadeInFrac {
            value = max(0, fraction / fadeInFrac)
        }
        if fadeOutFrac > 0 && fraction > fadeOutFrac {
            let span = max(0.0001, 1 - fadeOutFrac)
            value = min(value, max(0, 1 - (fraction - fadeOutFrac) / span))
        }
        return value
    }

    /// `eventfollow` + `instantaneous`: fire one burst at each position the parent
    /// spawned a particle at this tick. The two children of scene 3413921910's
    /// meteor emitter carry no velocity and zero gravity, so the burst is a
    /// birth-point flash, not something that rides the parent.
    private func emitFollowBursts() {
        guard let parent = followParent, !parent.spawnEventsThisTick.isEmpty else { return }
        // `spawn` reads the follow position from the injected control point, so
        // point it at each event in turn and restore the frame's value afterwards.
        let injected = injectedControlPoints[followControlPointID]
        defer {
            if let injected {
                injectedControlPoints[followControlPointID] = injected
            } else {
                injectedControlPoints.removeValue(forKey: followControlPointID)
            }
        }
        for event in parent.spawnEventsThisTick {
            // One roll per event: WPE's `probability` is "the chance the child is
            // spawned when the event condition is met", so a 0.5 child accompanies
            // half the parent's particles rather than half of all sessions.
            if spawnProbability < 1, Double.random(in: 0..<1, using: &rng) >= spawnProbability {
                continue
            }
            injectedControlPoints[followControlPointID] = event
            for _ in 0..<definition.instantaneousCount {
                guard let slot = nextFreeSlot() else { return }
                if !spawn(into: slot) { return }
            }
        }
    }

    private func nextFreeSlot() -> Int? {
        for index in 0..<capacity {
            if particles[index].age == .greatestFiniteMagnitude {
                return index
            }
        }
        return nil
    }

    /// Spawns into `slot`, returning whether a particle was actually written.
    @discardableResult
    private func spawn(into slot: Int) -> Bool {
        // Y-up author space: emitter origin and per-particle velocity are
        let dispersal: SIMD3<Float>
        switch definition.emitterShape {
        case .box:
            // `boxrandom`: uniform per axis within ±half-extent around the origin —
            let ext = definition.dispersalMax
            dispersal = SIMD3<Float>(
                Float(uniform(-ext.x, ext.x)),
                Float(uniform(-ext.y, ext.y)),
                Float(uniform(-ext.z, ext.z))
            )
        case .sphere:
            let radius = Self.sphereRadius(
                min: definition.dispersalMin.x,
                max: definition.dispersalMax.x,
                uniform01: Double.random(in: 0..<1, using: &rng)
            )
            let normal = Self.sphereSurfaceDirection(
                directions: definition.directionMask,
                gaussian: { mean, stddev in self.gaussian(mean: mean, stddev: stddev) }
            )
            let signedPoint = Self.applyEmitterSign(normal * radius, sign: definition.sign)
            dispersal = SIMD3<Float>(
                Float(signedPoint.x), Float(signedPoint.y), Float(signedPoint.z)
            )
        }
        let emitterOriginLocal = SIMD3<Float>(
            Float(definition.originOffset.x),
            Float(definition.originOffset.y),
            Float(definition.originOffset.z)
        )
        let localPoint = emitterOriginLocal + dispersal
        var localVelocity = uniformVector(definition.velocityMin, definition.velocityMax)
        localVelocity += Self.emitterRadialVelocity(
            dispersal: dispersal,
            speed: Float(uniform(definition.emitterSpeedMin, definition.emitterSpeedMax))
        )
        if let tvi = definition.turbulentVelocityInit {
            localVelocity += seedTurbulentVelocity(tvi)
        }
        let position: SIMD3<Float>
        if requiresFollowParent {
            // Event-follow child: ride the parent's live particle. Skip spawning
            // when the parent has no live particle this frame (no stale origin).
            guard let followPosition = injectedControlPoints[followControlPointID] else { return false }
            // The parent particle is already in render space and already carries
            position = followPosition + sceneTransform.applyModelDirection(dispersal)
        } else if emitterTracksPointer {
            // Pointer-locked emitter (control point 0 tracks the cursor): spawn
            guard let p = pointerCentered else { return false }
            position = SIMD3<Float>(p.x, p.y, 0) + sceneTransform.applyModelDirection(localPoint)
        } else {
            position = sceneTransform.applyModelMatrix(toLocalPoint: localPoint)
        }
        let velocity = sceneTransform.applyModelDirection(localVelocity)
        // REFRACT "lens water" droplets: the object scale (e.g. 3.52×) is there to
        let sizeScale = (isRefract || isNestedChildSystem) ? 1.0 : sceneTransform.worldSizeMultiplier()
        // `sizerandom` exponent: WPE samples min + (max-min)·rand^exp (exp>1
        // biases toward min). `uniform` is exp==1; only pay `pow` when it differs.
        let sizeSample: Double
        if abs(definition.sizeExponent - 1) < 0.0001 {
            sizeSample = uniform(definition.sizeMin, definition.sizeMax)
        } else if definition.sizeMax > definition.sizeMin {
            let r = pow(Double.random(in: 0...1, using: &rng), definition.sizeExponent)
            sizeSample = definition.sizeMin + (definition.sizeMax - definition.sizeMin) * r
        } else {
            sizeSample = definition.sizeMin
        }
        var size = Float(sizeSample) * sizeScale
        // Blend-aware cap: a hugely-scaled ADDITIVE emitter (e.g. 3426865175's
        if blendMode == .additive {
            size = min(size, sceneTransform.sceneHeight)
        }
        let rawColor = lerpVector(definition.colorMin, definition.colorMax)
        let lifetime = Float(uniform(definition.lifetimeMin, definition.lifetimeMax))
        let alpha = Float(uniform(definition.alphaMin, definition.alphaMax))
        let rotationVec = uniformVector(definition.rotationMin, definition.rotationMax)
        let angularVec = uniformVector(definition.angularVelocityMin, definition.angularVelocityMax)
        // Per-particle wind speed/phase for the `turbulence` OPERATOR only. Drawn
        let turbulenceSpeed: Float
        let turbulencePhase: Float
        if let turb = definition.turbulence {
            turbulenceSpeed = Float(uniform(turb.speedMin, turb.speedMax))
            turbulencePhase = Float(uniform(turb.phaseMin, turb.phaseMax))
        } else {
            turbulenceSpeed = 0
            turbulencePhase = 0
        }
        let oscPosFrequency: Float
        let oscPosScale: Float
        let oscPosPhase: Float
        if let osc = definition.oscillatePosition {
            oscPosFrequency = Float(uniform(osc.frequencyMin, osc.frequencyMax))
            oscPosScale = Float(uniform(osc.scaleMin, osc.scaleMax))
            // WPE samples the phase over [phasemin, phasemax + 2π] so a preset
            oscPosPhase = Float(uniform(osc.phaseMin, osc.phaseMax + 2 * .pi))
        } else {
            oscPosFrequency = 0
            oscPosScale = 0
            oscPosPhase = 0
        }
        let oscAlphaFrequency: Float
        let oscAlphaPhase: Float
        if let osc = definition.oscillateAlpha {
            oscAlphaFrequency = Float(uniform(osc.frequencyMin, osc.frequencyMax))
            oscAlphaPhase = Float(uniform(osc.phaseMin, osc.phaseMax + 2 * .pi))
        } else {
            oscAlphaFrequency = 0
            oscAlphaPhase = 0
        }
        let oscSizeFrequency: Float
        let oscSizePhase: Float
        if let osc = definition.oscillateSize {
            oscSizeFrequency = Float(uniform(osc.frequencyMin, osc.frequencyMax))
            oscSizePhase = Float(uniform(osc.phaseMin, osc.phaseMax + 2 * .pi))
        } else {
            oscSizeFrequency = 0
            oscSizePhase = 0
        }
        // `.randomFrame`: lock onto one atlas cell for life so each shard
        let staticFrame: Float
        if definition.animationMode == .randomFrame, let sheet = spriteSheet, sheet.frameCount > 1 {
            staticFrame = Float(Int.random(in: 0..<sheet.frameCount, using: &rng))
        } else {
            staticFrame = 0
        }
        particles[slot] = Particle(
            position: position,
            velocity: velocity,
            size: size,
            color: SIMD3<Float>(
                max(rawColor.x / 255, 0),
                max(rawColor.y / 255, 0),
                max(rawColor.z / 255, 0)
            ),
            rotationZ: sceneTransform.visualRotationZ(localRotationZ: rotationVec.z),
            angularVelocityZ: sceneTransform.visualAngularZ(localAngularZ: angularVec.z),
            alphaBase: min(max(alpha, 0), 1),
            lifetime: max(0.0001, lifetime),
            age: 0,
            turbulenceSpeed: turbulenceSpeed,
            turbulencePhase: turbulencePhase,
            staticFrame: staticFrame,
            oscPosFrequency: oscPosFrequency,
            oscPosScale: oscPosScale,
            oscPosPhase: oscPosPhase,
            oscAlphaFrequency: oscAlphaFrequency,
            oscAlphaPhase: oscAlphaPhase,
            oscSizeFrequency: oscSizeFrequency,
            oscSizePhase: oscSizePhase
        )
        if trailPointCount > 0 { resetTrailHistory(slot, to: position) }
        spawnEventsThisTick.append(position)
        return true
    }

    /// `turbulentvelocityrandom` spawn velocity in emitter-local space. A curl-noise
    private func seedTurbulentVelocity(_ tvi: WPEParticleTurbulentVelocityInit) -> SIMD3<Float> {
        let speed = uniform(tvi.speedMin, tvi.speedMax)
        // The emit interval is how much field time this particle owns (WPE hands
        var duration = definition.rate > 0 ? 1 / definition.rate : .infinity
        if duration > 10 {
            turbulentSamplePoint.x += speed
            duration = 0
        }
        let forward = simd_normalize(tvi.forward)
        // `timescale` = how fast the field evolves, so it divides the step. Guard
        // the division: an authored 0 would send the sample point to infinity.
        let timescale = tvi.timescale.isFinite && tvi.timescale > 0 ? tvi.timescale : 1
        let step = 0.005 / timescale
        var dir: SIMD3<Double>
        repeat {
            dir = WPEParticleCurlNoise.direction(at: turbulentSamplePoint, fallback: forward)
            turbulentSamplePoint += dir * step
            duration -= 0.01
        } while duration > 0.01
        // Cone limit: `scale` is the cone width as a hemisphere fraction (2 =
        let coneFrac = tvi.scale / 2
        let c = min(max(simd_dot(dir, forward), -1), 1)
        let a = acos(c) / .pi
        if a > coneFrac {
            let axis = simd_cross(dir, forward)
            if simd_length(axis) > 1e-6 {
                dir = Self.rotate(dir, around: simd_normalize(axis), by: a * (1 - coneFrac) * .pi)
            }
        }
        if tvi.offset != 0, simd_length(tvi.right) > 1e-6 {
            dir = Self.rotate(dir, around: simd_normalize(tvi.right), by: tvi.offset)
        }
        let v = dir * speed
        return SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
    }

    private static func rotate(_ v: SIMD3<Double>, around k: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        let cosA = cos(angle)
        let sinA = sin(angle)
        return v * cosA + simd_cross(k, v) * sinA + k * simd_dot(k, v) * (1 - cosA)
    }
}
#endif
