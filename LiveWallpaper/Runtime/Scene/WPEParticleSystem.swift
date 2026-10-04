#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

func wpeTrailPointCount(subdivision: Double) -> Int {
    let finiteSubdivision = subdivision.isFinite ? subdivision : 3
    let segments = min(max(finiteSubdivision, 1), 7).rounded()
    return Int(segments) + 1
}

/// Layout MUST match `WPEParticleInstance` in `WPEMetalBuiltins.metal` exactly.
struct WPEParticleInstance {
    var positionAndSize: SIMD4<Float>
    var color: SIMD4<Float>
    var rotationAndLife: SIMD4<Float>
    /// xyz = local trail velocity; w = unprojected scene-centered depth.
    var velocity: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
}

/// Layout MUST match `WPEParticleRopeVertex` in `WPEMetalBuiltins.metal`.
struct WPEParticleRopeVertex {
    var positionUV: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Value-typed RNG. Production `.system`; oracle injects `.seeded`.
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

/// SplitMix64 for the render oracle only — spawn jitter must be reproducible run-to-run.
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

/// Birth takes the lowest free slot and live iteration is ascending — both must match the old 0..<capacity linear scans, or RNG, draw order, and spawn-event order drift.
struct WPEParticleSlotIndex {
    private var words: [UInt64]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.words = .init(repeating: 0, count: (capacity + 63) >> 6)
    }

    var wordCount: Int { words.count }

    func word(at index: Int) -> UInt64 { words[index] }

    func isLive(_ slot: Int) -> Bool {
        words[slot >> 6] & ((1 as UInt64) << UInt64(slot & 63)) != 0
    }

    mutating func markLive(_ slot: Int) {
        words[slot >> 6] |= (1 as UInt64) << UInt64(slot & 63)
    }

    mutating func markDead(_ slot: Int) {
        words[slot >> 6] &= ~((1 as UInt64) << UInt64(slot & 63))
    }

    mutating func removeAll() {
        for index in words.indices { words[index] = 0 }
    }

    /// Equivalent to the old linear free scan from slot 0. Tail bits past
    /// `capacity` are never set, so a full pool maps them to nil, not a slot.
    var lowestFreeSlot: Int? {
        for wordIndex in words.indices {
            let free = ~words[wordIndex]
            if free != 0 {
                let slot = wordIndex << 6 | free.trailingZeroBitCount
                return slot < capacity ? slot : nil
            }
        }
        return nil
    }

    /// Ascending live slots. The body must not mutate this index (exclusivity);
    /// loops that kill mid-iteration use `wordCount`/`word(at:)` instead.
    func forEachLiveSlot(_ body: (Int) -> Void) {
        for wordIndex in words.indices {
            var word = words[wordIndex]
            while word != 0 {
                body(wordIndex << 6 | word.trailingZeroBitCount)
                word &= word &- 1
            }
        }
    }
}

/// Child transforms compose as parent * (T * S): offset is in the parent's scaled axes; scale multiplies descendant local coordinates component-wise.
struct WPEParticleChildTransform: Equatable {
    var origin: SIMD3<Double>
    var scale: SIMD3<Double>

    static let identity = WPEParticleChildTransform(
        origin: .zero,
        scale: SIMD3<Double>(repeating: 1)
    )

    func appending(_ child: WPEParticleChildReference) -> WPEParticleChildTransform {
        WPEParticleChildTransform(
            origin: origin + scale * child.originOffset,
            scale: scale * child.scale
        )
    }
}

/// WPE author space is Y-up; origin, velocity, gravity, and rotation must not be flipped.
struct WPEParticleSceneTransform {
    var renderOrigin: SIMD3<Float>
    var objectScale: SIMD3<Float>
    let objectAngleZ: Float
    /// Hoisted cos/sin(objectAngleZ) — same libm calls, so results stay bit-exact.
    /// `objectAngleZ` is `let` so these cannot go stale.
    let cosAngleZ: Float
    let sinAngleZ: Float
    /// Caps oversized additive sprites so a scaled emitter cannot saturate the frame.
    var sceneHeight: Float
    let sceneWidth: Float

    init(
        sceneSize: SIMD2<Float>,
        objectOrigin: SIMD3<Float>,
        objectScale: SIMD3<Float>,
        objectAngleZ: Float,
        childOrigin: SIMD3<Float> = .zero,
        childScale: SIMD3<Float> = SIMD3<Float>(repeating: 1)
    ) {
        let cosAngleZ = cos(objectAngleZ)
        let sinAngleZ = sin(objectAngleZ)
        let scaledChildOrigin = childOrigin * objectScale
        let rotatedChildOrigin = SIMD3<Float>(
            scaledChildOrigin.x * cosAngleZ - scaledChildOrigin.y * sinAngleZ,
            scaledChildOrigin.x * sinAngleZ + scaledChildOrigin.y * cosAngleZ,
            scaledChildOrigin.z
        )
        self.renderOrigin = SIMD3<Float>(
            objectOrigin.x - sceneSize.x * 0.5,
            objectOrigin.y - sceneSize.y * 0.5,
            objectOrigin.z
        ) + rotatedChildOrigin
        self.objectScale = objectScale * childScale
        self.objectAngleZ = objectAngleZ
        self.cosAngleZ = cosAngleZ
        self.sinAngleZ = sinAngleZ
        sceneHeight = max(1, sceneSize.y)
        sceneWidth = max(1, sceneSize.x)
    }

    static let identity = WPEParticleSceneTransform(
        sceneSize: SIMD2<Float>(1, 1),
        objectOrigin: SIMD3<Float>(0, 0, 0),
        objectScale: SIMD3<Float>(1, 1, 1),
        objectAngleZ: 0
    )

    func applyModelMatrix(toLocalPoint p: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(p.x * objectScale.x, p.y * objectScale.y, p.z * objectScale.z)
        let cosA = cosAngleZ
        let sinA = sinAngleZ
        return renderOrigin + SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    /// No Y-flip. Oracle 3526278753: velocity Y must stay negative = falling.
    func applyModelDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(v.x * objectScale.x, v.y * objectScale.y, v.z * objectScale.z)
        let cosA = cosAngleZ
        let sinA = sinAngleZ
        return SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    /// Trail stretch uses local velocity before the model transform (WPE GS).
    func localVelocity(ofWorldVelocity velocity: SIMD3<Float>) -> SIMD3<Float> {
        let unrotated = SIMD3<Float>(
            velocity.x * cosAngleZ + velocity.y * sinAngleZ,
            -velocity.x * sinAngleZ + velocity.y * cosAngleZ,
            velocity.z
        )
        return SIMD3<Float>(
            abs(objectScale.x) > 0.000001 ? unrotated.x / objectScale.x : 0,
            abs(objectScale.y) > 0.000001 ? unrotated.y / objectScale.y : 0,
            abs(objectScale.z) > 0.000001 ? unrotated.z / objectScale.z : 0
        )
    }

    func worldSizeMultiplier() -> Float {
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
        return objectAngleZ + localRotation
    }

    func visualAngularZ(localAngularZ: Float) -> Float {
        let signs = visualScaleSigns()
        return signs.x * signs.y < 0 ? -localAngularZ : localAngularZ
    }
}

final class WPEParticleSystem {
    let definition: WPEParticleDefinition
    let capacity: Int
    let blendMode: WPEParticleBlendMode
    let sceneTransform: WPEParticleSceneTransform
    private let instanceBuffers: [MTLBuffer]
    let usesFrameArena: Bool
    private var renderSlice: WPEParticleRenderSlice?
    private var activeFrameSlot = 0
    var instanceBuffer: MTLBuffer {
        renderSlice?.buffer ?? instanceBuffers[activeFrameSlot]
    }

    var renderBufferOffset: Int {
        renderSlice?.offset ?? 0
    }

    let isRope: Bool
    /// `ropetrail`: each particle owns a history ribbon. `isRope`: one ribbon through the pool.
    let usesTrailRibbon: Bool
    /// Set per frame by the renderer: true when the GPU sprite-perspective path has no matrix to bind
    /// (a 3D scene camera), so sprites keep the CPU depth scale ribbons always get.
    var cpuPerspectiveFallback = false

    var usesRibbonGeometry: Bool { isRope || usesTrailRibbon }
    private let trailPointCount: Int
    private var trailSamples: [SIMD2<Float>] {
        _read { yield cpuStorage.trailSamples }
        _modify { yield &cpuStorage.trailSamples }
    }

    private var trailSampleHead: [Int] {
        _read { yield cpuStorage.trailHeads }
        _modify { yield &cpuStorage.trailHeads }
    }

    private var trailSampleFill: [Int] {
        _read { yield cpuStorage.trailFills }
        _modify { yield &cpuStorage.trailFills }
    }

    private var trailRibbonScratch: [SIMD2<Float>] = []
    /// 48 samples still cover corpus trails at 120 Hz.
    private static let trailSampleCapacity = 48
    private let ropeVertexBuffers: [MTLBuffer]
    private let ropeVertexCapacity: Int
    var ropeVertexBuffer: MTLBuffer? {
        if usesRibbonGeometry, let renderSlice {
            return renderSlice.buffer
        }
        return ropeVertexBuffers.indices.contains(activeFrameSlot)
            ? ropeVertexBuffers[activeFrameSlot]
            : nil
    }
    private(set) var ropeVertexCount: Int = 0
    let spriteSheet: WPEParticleSpriteSheet?
    var parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0)
    var parallaxCenter: SIMD2<Double> = SIMD2<Double>(0, 0)

    #if !LITE_BUILD && DEBUG
    /// Dumps pair by this id, not `particle-def-N` / `particle-state-N` filename numbers.
    var traceObjectID: String?
    var traceParticlePath: String?
    #endif

    /// startDelay is pre-simulation, not a wait.
    private var presimulatingStartDelay = false
    /// After prewarm, a finite duration stays anchored at virtual time zero.
    private var startDelayWasPresimulated = false
    var hostOriginOffset: SIMD2<Float> = .init(0, 0)
    /// Rigid event-instance translation; existing particles move with their own parent.
    var instanceOriginOffset: SIMD3<Float> = .zero
    var hostAncestorIDs: [String] = []
    var sortIndex: Int = 0
    var overbright: Float = 1.0
    var isRefract: Bool = false
    var refractAmount: Float = 0.05
    /// Nested child: sprite size uses the child-system scale while spawn positions,
    /// velocities, gravity and control-point offsets use the composed model matrix.
    var isNestedChildSystem: Bool = false
    var groupOpacityMask: MTLTexture?
    var groupTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    var pointerCentered: SIMD2<Float>?
    var scriptParticleObjectID: String?
    /// 1 when the object has no such script — and it keeps its last ticked value if the script later fails.
    var instanceValues = WPEParticleInstanceValues()
    var instanceColorBrightnessScale: Float = 1
    var instanceAlphaScale: Float {
        get { Float(instanceValues.alpha) }
        set { instanceValues.alpha = Double(newValue) }
    }

    private var rateElapsedAdjustment: Double = 0
    /// Scene object whose `instanceoverride.alpha` script drives `instanceAlphaScale`.
    /// nil ⇒ no script; the renderer skips this system when fanning tick results out.
    var instanceAlphaScriptObjectID: String?
    /// 16-band mono spectrum for this frame (renderer-set); nil ⇒ silence ⇒ scale 1.
    var audioSpectrum16: [Float]?

    var isAudioResponsive: Bool { definition.emitterAudioState?.isEnabled == true }

    var injectedControlPoints: [Int: SIMD3<Float>] = [:]
    private(set) var particleEventsThisTick: [WPEParticleEvent] = []
    private(set) var droppedParticleEventsThisTick = 0
    private var recordsParticleEvents = false
    private var particleGenerations: [UInt64] {
        _read { yield cpuStorage.generations }
        _modify { yield &cpuStorage.generations }
    }

    static let maximumRecordedParticleEvents = absoluteCap * 2

    private var simulationNow: Double = 0

    private let attractors: [WPEParticleControlPointAttractor]
    private let emitterTracksPointer: Bool
    private let controlPointRawOffsets: [Int: SIMD3<Float>]
    private let pointerLockedControlPointIDs: Set<Int>
    private let worldSpaceControlPointIDs: Set<Int>

    private var aliveCount: Int = 0
    var liveParticleCount: Int {
        aliveCount
    }

    private(set) var lastAttractorAffectedCount = 0
    private var particles: [Particle] {
        _read { yield cpuStorage.particles }
        _modify { yield &cpuStorage.particles }
    }

    /// Must stay exactly consistent with the `age` sentinel: every alive/dead
    /// transition (spawn, lifetime expiry, clearLiveParticles) updates both.
    private var liveSlots: WPEParticleSlotIndex {
        _read { yield cpuStorage.liveSlots }
        _modify { yield &cpuStorage.liveSlots }
    }

    private struct ResolvedAttractor {
        var position: SIMD3<Float>
        var threshold: Float
        var scale: Float
    }
    /// Rebuilt each `advance`: injected/pointer control points move between ticks,
    /// but never inside the per-particle loop.
    private var resolvedAttractors: [ResolvedAttractor] = []
    private var ropeKnotScratch: [(position: SIMD2<Float>, color: SIMD4<Float>, halfSize: Float, age: Float)] = []
    private var cachedPrimaryAge: Float = .greatestFiniteMagnitude
    private var cachedPrimarySlot: Int = .max
    private var spawnAccumulator: Double = 0
    private var hasEmittedBurst = false
    private enum Playback { case playing, paused, stopped }
    private var playback: Playback = .playing
    private var explicitlyRequestedParticles = 0
    private var explicitBirths: [(count: Int, values: WPEParticleInstanceValues)] = []
    private var lastTickTime: Double?
    private var firstTickTime: Double?
    private var rng: WPEParticleRNG
    /// Shared `turbulentvelocityrandom` sample (WPE initializer-closure semantics).
    private var turbulentSamplePoint = SIMD3<Double>.zero
    /// Cached gravity in render space (Y-up).
    private let gravity: SIMD3<Float>
    private let oscillatePositionMask: SIMD3<Float>
    private let perspectiveExtent: Float
    private let visualScaleSigns: SIMD2<Float>
    private let spawnWorldSizeMultiplier: Float
    /// Child scale is distinct from the scene object's scale. Nested systems inherit this for sprite size; X/Y use the same mean-absolute rule as root sprites.
    private let childWorldSizeMultiplier: Float

    /// Pre-uploaded TEXS UV rects; avoids the 4 KB `setVertexBytes` limit.
    let frameRectsBuffer: MTLBuffer?

    static let absoluteCap = 8192
    static let perspectiveNearBoost: Float = 1.5

    var requiredRenderByteCount: Int {
        let stride = MemoryLayout<WPEParticleRopeVertex>.stride
        if isRope {
            return aliveCount * 2 * stride
        }
        if usesTrailRibbon {
            return aliveCount * (trailPointCount * 2 + 2) * stride
        }
        return aliveCount * MemoryLayout<WPEParticleInstance>.stride
    }

    var ownedRenderBufferBytes: Int {
        (instanceBuffers + ropeVertexBuffers).reduce(0) { $0 + $1.length }
    }

    func discardRenderData() {
        renderSlice = nil
        ropeVertexCount = 0
    }

    func anchorInstanceClock(at now: Double, presimulateDelay: Bool = false) {
        firstTickTime = now
        lastTickTime = now
        if presimulateDelay {
            startDelayWasPresimulated = true
        }
    }

    func finishInstancePrewarm() {
        lastTickTime = 0
        particleEventsThisTick.removeAll(keepingCapacity: true)
        droppedParticleEventsThisTick = 0
    }

    /// Allocate only mutable state; all loaded definition/material resources stay shared.
    func makeEventInstance(device: MTLDevice, seed: UInt64) -> WPEParticleSystem? {
        guard let instance = WPEParticleSystem(
            definition: definition, device: device, blendMode: blendMode,
            sceneTransform: sceneTransform,
            childScale: SIMD3(repeating: childWorldSizeMultiplier),
            spriteSheet: spriteSheet, seed: seed, usesFrameArena: usesFrameArena,
            sharedFrameRectsBuffer: frameRectsBuffer, cpuStoragePool: cpuStoragePool
        ) else { return nil }
        instance.parallaxDepth = parallaxDepth
        instance.parallaxCenter = parallaxCenter
        instance.hostOriginOffset = hostOriginOffset
        instance.hostAncestorIDs = hostAncestorIDs
        instance.sortIndex = sortIndex
        instance.overbright = overbright
        instance.isRefract = isRefract
        instance.refractAmount = refractAmount
        instance.isNestedChildSystem = isNestedChildSystem
        instance.groupOpacityMask = groupOpacityMask
        instance.groupTint = groupTint
        instance.scriptParticleObjectID = scriptParticleObjectID
        instance.instanceAlphaScriptObjectID = instanceAlphaScriptObjectID
        instance.instanceValues = instanceValues
        instance.instanceColorBrightnessScale = instanceColorBrightnessScale
        #if DEBUG
        instance.traceObjectID = traceObjectID
        instance.traceParticlePath = traceParticlePath
        #endif
        return instance
    }

    /// FNV-1a, not salted Hasher. Only when oracle mode is enabled.
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

    private typealias Particle = WPEParticleCPUState
    private let cpuStorage: WPEParticleCPUStorage
    private let cpuStoragePool: WPEParticleCPUStoragePool?

    var cpuStorageIdentity: ObjectIdentifier {
        ObjectIdentifier(cpuStorage)
    }

    deinit {
        cpuStoragePool?.recycle(cpuStorage)
    }

    init?(
        definition: WPEParticleDefinition,
        device: MTLDevice,
        blendMode: WPEParticleBlendMode = .translucent,
        sceneTransform: WPEParticleSceneTransform = .identity,
        childScale: SIMD3<Float> = SIMD3<Float>(repeating: 1),
        spriteSheet: WPEParticleSpriteSheet? = nil,
        seed: UInt64? = nil,
        usesFrameArena: Bool = false,
        sharedFrameRectsBuffer: MTLBuffer? = nil,
        cpuStoragePool: WPEParticleCPUStoragePool? = nil
    ) {
        self.definition = definition
        self.blendMode = blendMode
        self.sceneTransform = sceneTransform
        self.spriteSheet = spriteSheet
        self.usesFrameArena = usesFrameArena
        let cap = max(1, min(definition.maxCount, Self.absoluteCap))
        self.capacity = cap
        let storageKey = WPEParticleCPUStorage.Key(
            capacity: cap, trailSamples: definition.usesTrailRibbon ? Self.trailSampleCapacity : 0
        )
        self.cpuStoragePool = cpuStoragePool
        cpuStorage = cpuStoragePool?.acquire(storageKey) ?? WPEParticleCPUStorage(key: storageKey)
        var instanceBuffers: [MTLBuffer] = []
        instanceBuffers.reserveCapacity(WPEMetalRenderExecutor.maxFramesInFlight)
        for slot in 0 ..< (usesFrameArena ? 0 : WPEMetalRenderExecutor.maxFramesInFlight) {
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
        let trailPoints = if usesTrailRibbon, let trail = definition.trailRenderer {
            // `subdivision` is segments, so points = segments + 1. Clamp 2…8.
            wpeTrailPointCount(subdivision: trail.subdivision)
        } else {
            0
        }
        self.trailPointCount = trailPoints
        if definition.isRope || usesTrailRibbon {
            // rope: 2 verts/knot. ropetrail: 2/history point + a 2-vert degenerate bridge.
            let vertexCapacity = definition.isRope ? cap * 2 : cap * (trailPoints * 2 + 2)
            self.ropeVertexCapacity = vertexCapacity
            var ropeBuffers: [MTLBuffer] = []
            ropeBuffers.reserveCapacity(WPEMetalRenderExecutor.maxFramesInFlight)
            for slot in 0 ..< (usesFrameArena ? 0 : WPEMetalRenderExecutor.maxFramesInFlight) {
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
            self.trailRibbonScratch = .init(repeating: .zero, count: trailPoints)
        }
        if let seed {
            self.rng = .seeded(SplitMix64(seed: seed))
        } else {
            self.rng = .system(SystemRandomNumberGenerator())
        }
        let localGravity = SIMD3<Float>(
            Float(definition.gravity.x),
            Float(definition.gravity.y),
            Float(definition.gravity.z)
        )
        let gravity = sceneTransform.applyModelDirection(localGravity)
        self.gravity = gravity
        self.perspectiveExtent = Self.perspectiveDepthExtent(
            definition: definition, sceneTransform: sceneTransform, gravity: gravity)
        self.visualScaleSigns = sceneTransform.visualScaleSigns()
        self.spawnWorldSizeMultiplier = sceneTransform.worldSizeMultiplier()
        self.childWorldSizeMultiplier = max(0, (abs(childScale.x) + abs(childScale.y)) * 0.5)
        if let osc = definition.oscillatePosition {
            // Mask gates axes, does not scale them (snowperspective 1 0.5 0).
            let gate = SIMD3<Float>(
                osc.mask.x < 0.01 ? 0 : 1,
                osc.mask.y < 0.01 ? 0 : 1,
                osc.mask.z < 0.01 ? 0 : 1
            )
            self.oscillatePositionMask = sceneTransform.applyModelDirection(gate)
        } else {
            self.oscillatePositionMask = .zero
        }
        if let sharedFrameRectsBuffer, sharedFrameRectsBuffer.device.registryID == device.registryID {
            frameRectsBuffer = sharedFrameRectsBuffer
        } else if let rects = spriteSheet?.frameRects, !rects.isEmpty {
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
        var worldIDs: Set<Int> = []
        for cp in definition.controlPoints {
            offsets[cp.id] = SIMD3<Float>(Float(cp.offset.x), Float(cp.offset.y), Float(cp.offset.z))
            if cp.pointerLocked {
                pointerIDs.insert(cp.id)
            }
            if cp.isWorldSpace {
                worldIDs.insert(cp.id)
            }
        }
        controlPointRawOffsets = offsets
        pointerLockedControlPointIDs = pointerIDs
        worldSpaceControlPointIDs = worldIDs
        // Only systems with the initializer draw this, so other spawn sequences stay oracle-identical.
        if definition.turbulentVelocityInit != nil {
            turbulentSamplePoint = SIMD3<Double>(
                Double.random(in: 0..<10, using: &rng),
                Double.random(in: 0..<10, using: &rng),
                Double.random(in: 0..<10, using: &rng)
            )
        }
        if definition.isRope { ropeKnotScratch.reserveCapacity(cap) }
        resolvedAttractors.reserveCapacity(definition.attractors.count)
    }

    func pointerInSimulationFrame(_ point: SIMD2<Float>?) -> SIMD2<Float>? {
        point.map { $0 - SIMD2(instanceOriginOffset.x, instanceOriginOffset.y) - hostOriginOffset }
    }

    func controlPointPosition(_ id: Int) -> SIMD3<Float>? {
        guard (0 ... 7).contains(id) else { return nil }
        if let injected = injectedControlPoints[id] {
            return injected
        }
        let rawOffset = instanceValues.controlPoints[id].map {
            SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
        } ?? controlPointRawOffsets[id] ?? .zero
        if pointerLockedControlPointIDs.contains(id) {
            guard let point = pointerCentered else { return nil }
            let offset = worldSpaceControlPointIDs.contains(id) ? rawOffset : sceneTransform.applyModelDirection(rawOffset)
            return SIMD3(point.x, point.y, 0) + offset
        }
        if worldSpaceControlPointIDs.contains(id) {
            return SIMD3(rawOffset.x - sceneTransform.sceneWidth * 0.5,
                         rawOffset.y - sceneTransform.sceneHeight * 0.5, rawOffset.z)
                - instanceOriginOffset - SIMD3(hostOriginOffset.x, hostOriginOffset.y, 0)
        }
        return sceneTransform.applyModelMatrix(toLocalPoint: rawOffset)
    }

    /// Parent's raw model coordinates; missing live entries leave a child's previous/authored control points intact.
    func liveControlPointSourcePositions(limit: Int) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        guard limit > 0 else { return result }
        for wordIndex in 0 ..< liveSlots.wordCount {
            var word = liveSlots.word(at: wordIndex)
            while word != 0 {
                let index = wordIndex << 6 | word.trailingZeroBitCount
                word &= word &- 1
                result.append(sceneTransform.localVelocity(ofWorldVelocity: particles[index].position - sceneTransform.renderOrigin))
                if result.count == limit {
                    return result
                }
            }
        }
        return result
    }

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
        // Endpoints are unordered; sorting avoids pinning a reversed range to one end.
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

    /// Box–Muller over the spawn `rng`.
    private func gaussian(mean: Double, stddev: Double) -> Double {
        let u1 = Swift.max(Double.leastNormalMagnitude, Double.random(in: 0..<1, using: &rng))
        let u2 = Double.random(in: 0..<1, using: &rng)
        let mag = (-2 * log(u1)).squareRoot()
        return mean + stddev * mag * cos(2 * Double.pi * u2)
    }

    /// colorrandom: one t lerps all channels, not per-channel draws.
    private func lerpVector(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> SIMD3<Float> {
        let t = uniform(0, 1)
        return SIMD3<Float>(
            Float(low.x + (high.x - low.x) * t),
            Float(low.y + (high.y - low.y) * t),
            Float(low.z + (high.z - low.z) * t)
        )
    }

    /// Volume-uniform sphere: lerp(pow(rand, 1/3), min, max).
    static func sphereRadius(min: Double, max: Double, uniform01: Double) -> Double {
        let t = pow(Swift.max(0, Swift.min(1, uniform01)), 1.0 / 3.0)
        return min + t * (max - min)
    }

    static func sphereSurfaceDirection(
        directions: SIMD3<Double>,
        gaussian: (_ mean: Double, _ stddev: Double) -> Double
    ) -> SIMD3<Double> {
        let u = abs(directions.x) > 1e-6 ? gaussian(0, 1) : 0
        let v = abs(directions.y) > 1e-6 ? gaussian(0, 1) : 0
        let w = abs(directions.z) > 1e-6 ? gaussian(0, 1) : 0
        let norm = (u * u + v * v + w * w).squareRoot()
        guard norm > 0 else { return SIMD3<Double>(0, 0, 0) }
        return SIMD3<Double>(u, v, w) / norm
    }

    static func applyEmitterSign(_ p: SIMD3<Double>, sign: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            sign.x != 0 ? Swift.abs(p.x) * sign.x : p.x,
            sign.y != 0 ? Swift.abs(p.y) * sign.y : p.y,
            sign.z != 0 ? Swift.abs(p.z) * sign.z : p.z
        )
    }

    /// WPE boxrandom: each axis lerps min→max with a sample in -1...1, then applies directions. Unlike sphererandom, the box emitter does not apply sign.
    static func boxEmitterDispersal(
        minimum: SIMD3<Double>,
        maximum: SIMD3<Double>,
        directions: SIMD3<Double>,
        samples: SIMD3<Double>
    ) -> SIMD3<Double> {
        let clampedSamples = SIMD3<Double>(
            min(max(samples.x, -1), 1),
            min(max(samples.y, -1), 1),
            min(max(samples.z, -1), 1)
        )
        let sampled = minimum + clampedSamples * (maximum - minimum)
        return sampled * directions
    }

    static func emitterRadialVelocity(dispersal: SIMD3<Float>, speed: Float) -> SIMD3<Float> {
        let length = simd_length(dispersal)
        guard length > 0.000_001, speed != 0 else { return .zero }
        return dispersal / length * speed
    }

    /// starttime is pre-sim, not a wait.
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

    private var prewarmVirtualNow: Double?

    func beginPrewarm(simulatedSeconds: Double, presimulateDelay: Bool) -> ClosedRange<Double>? {
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
        let simulationStart = prewarmConvergenceStart(activeStart: activeStart, simulatedSeconds: simulatedSeconds)
        // Clock stays at the true start so `systemElapsed` still covers the full window.
        firstTickTime = 0
        lastTickTime = simulationStart
        prewarmVirtualNow = simulationStart
        if simulationStart > activeStart {
            // Instantaneous burst already died in the skipped head — do not re-fire.
            hasEmittedBurst = true
        }
        return simulationStart...simulatedSeconds
    }

    /// Skip the birth-dead treadmill of a long starttime.
    private func prewarmConvergenceStart(activeStart: Double, simulatedSeconds: Double) -> Double {
        // Wall-clock lifetime: births sample the instance lifetime scale and age at the clamped `rate` (see advance).
        // Floor 1s so lifetimeMax 0 still has steps.
        let rate = max(0.01, min(64, instanceValues.rate))
        let converged = max(definition.lifetimeMax * max(0.0001, instanceValues.lifetime) / rate, 1.0)
        guard converged.isFinite else { return activeStart }
        return max(activeStart, simulatedSeconds - converged)
    }

    func prewarmStep(to virtualNow: Double) {
        guard prewarmVirtualNow != nil else { return }
        prewarmVirtualNow = virtualNow
        advance(now: virtualNow)
    }

    func endPrewarm() {
        guard let virtualNow = prewarmVirtualNow else { return }
        prewarmVirtualNow = nil
        presimulatingStartDelay = false
        // Re-anchor so live frames don't freeze until wall time catches up.
        firstTickTime = -virtualNow
        lastTickTime = 0
        // Drop prewarm births so the first live frame doesn't replay them (3413921910).
        particleEventsThisTick.removeAll(keepingCapacity: true)
        droppedParticleEventsThisTick = 0
    }

    private func drawAttributes(
        of particle: Particle, overrideAlphaScale: Float?
    ) -> (position: SIMD3<Float>, rgb: SIMD3<Float>, alpha: Float, size: Float, lifetimeFraction: Float) {
        let envelope = fadeEnvelope(age: particle.age, lifetime: particle.lifetime)
        let lifetimeFraction = particle.lifetime > 0 ? min(1, max(0, particle.age / particle.lifetime)) : 0
        var alpha = particle.alphaBase * envelope
        if let alphaChange = definition.alphaChange {
            alpha *= Float(alphaChange.factor(lifetimeFraction: Double(lifetimeFraction)))
        }
        if let overrideAlphaScale {
            alpha *= overrideAlphaScale
        }
        if let oscillateAlpha = definition.oscillateAlpha {
            alpha *= Float(oscillateAlpha.factor(
                age: Double(particle.age),
                frequency: Double(particle.oscAlphaFrequency),
                phase: Double(particle.oscAlphaPhase)
            ))
        }
        alpha = min(max(alpha, 0), 1)
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
        // Re-cap after `sizechange`, which can grow past the spawn-time additive limit.
        if blendMode == .additive {
            spriteSize = min(spriteSize, sceneTransform.sceneHeight)
        }
        var rgb = particle.color
        if definition.hasColorInitializer, let colorChange = definition.colorChange {
            let c = colorChange.color(lifetimeFraction: Double(lifetimeFraction))
            rgb *= SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        }
        // Transient sine sway — never integrated into stored position.
        var drawPosition = particle.position + instanceOriginOffset
        if particle.oscPosScale != 0, particle.oscPosFrequency != 0 {
            // frequency is rad/s, phase is radians — do not multiply an extra 2π.
            let sway = sin(particle.age * particle.oscPosFrequency + particle.oscPosPhase)
            drawPosition += oscillatePositionMask * (sway * particle.oscPosScale)
        }
        if definition.isPerspective, usesRibbonGeometry || cpuPerspectiveFallback {
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

    private var animatedOverrideAlphaScale: Float? {
        definition.overrideAlphaAnimation?.scalar(at: systemElapsed).map { Float(max(0, $0)) }
    }

    private func perspectiveDepthScale(depth z: Float) -> Float {
        let t = min(max(z / perspectiveExtent, 0), 1)
        return 1 + Self.perspectiveNearBoost * t
    }

    private static func perspectiveDepthExtent(
        definition: WPEParticleDefinition,
        sceneTransform: WPEParticleSceneTransform,
        gravity: SIMD3<Float>
    ) -> Float {
        let localSpawnDepth: Double
        switch definition.emitterShape {
        case .box:
            let minimum = definition.dispersalMin.z
            let maximum = definition.dispersalMax.z
            let lowEndpoint = minimum - (maximum - minimum)
            localSpawnDepth = max(abs(lowEndpoint), abs(maximum))
                * abs(definition.directionMask.z)
        case .sphere:
            localSpawnDepth = abs(definition.dispersalMax.z * definition.directionMask.z)
        case .unsupported:
            localSpawnDepth = 0
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
        advanceSimulation(now: now)
        prepareRenderData(frameSlot: frameSlot)
    }

    func advanceSimulation(now: Double) {
        advance(now: now)
    }

    func prepareRenderData(frameSlot: Int = 0, slice: WPEParticleRenderSlice? = nil) {
        precondition((0 ..< WPEMetalRenderExecutor.maxFramesInFlight).contains(frameSlot))
        precondition(!usesFrameArena || slice != nil || aliveCount == 0)
        if let slice {
            precondition(slice.offset >= 0 && slice.length >= requiredRenderByteCount)
            precondition(slice.offset <= slice.buffer.length - slice.length)
        }
        activeFrameSlot = frameSlot
        renderSlice = slice
        if aliveCount == 0 {
            ropeVertexCount = 0
            return
        }
        if isRope {
            buildRopeGeometry()
            return
        }
        if usesTrailRibbon {
            buildTrailGeometry()
            return
        }
        let pointer = instanceBuffer.contents().advanced(by: renderBufferOffset)
            .bindMemory(to: WPEParticleInstance.self, capacity: aliveCount)
        let frameCount: Float = Float(max(1, spriteSheet?.frameCount ?? 1))
        let animatesSequence = definition.animationMode == .sequence && frameCount > 1
        let cyclesPerLifetime = max(0.0001, Float(definition.sequenceMultiplier))
        var written = 0
        let overrideAlphaScale = animatedOverrideAlphaScale
        liveSlots.forEachLiveSlot { index in
            let particle = particles[index]
            let attrs = drawAttributes(of: particle, overrideAlphaScale: overrideAlphaScale)
            let lifetimeFraction = attrs.lifetimeFraction
            let alpha = attrs.alpha
            let spriteSize = attrs.size
            let rgb = attrs.rgb
            let drawPosition = attrs.position
            let localVelocity = definition.trailRenderer?.kind == .sprite
                ? sceneTransform.localVelocity(ofWorldVelocity: particle.velocity) : .zero
            let frameIndex: Float
            if animatesSequence {
                let raw = lifetimeFraction * cyclesPerLifetime * frameCount
                frameIndex = raw.truncatingRemainder(dividingBy: frameCount)
            } else {
                frameIndex = particle.staticFrame
            }
            pointer[written] = WPEParticleInstance(
                positionAndSize: SIMD4<Float>(
                    drawPosition.x, drawPosition.y, visualScaleSigns.x, spriteSize * 0.5
                ),
                color: SIMD4<Float>(rgb.x, rgb.y, rgb.z, alpha),
                rotationAndLife: SIMD4<Float>(particle.rotationZ, lifetimeFraction, frameIndex, visualScaleSigns.y),
                velocity: SIMD4<Float>(
                    localVelocity.x, localVelocity.y, localVelocity.z, drawPosition.z
                )
            )
            written += 1
        }
    }

    private func buildRopeGeometry() {
        guard let buffer = ropeVertexBuffer else {
            ropeVertexCount = 0
            return
        }
        ropeKnotScratch.removeAll(keepingCapacity: true)
        let overrideAlphaScale = animatedOverrideAlphaScale
        liveSlots.forEachLiveSlot { index in
            let particle = particles[index]
            let attrs = drawAttributes(of: particle, overrideAlphaScale: overrideAlphaScale)
            ropeKnotScratch.append((
                SIMD2<Float>(attrs.position.x, attrs.position.y),
                SIMD4<Float>(attrs.rgb.x, attrs.rgb.y, attrs.rgb.z, attrs.alpha),
                max(0, attrs.size * 0.5),
                particle.age
            ))
        }
        guard ropeKnotScratch.count >= 2 else {
            ropeVertexCount = 0
            return
        }
        ropeKnotScratch.sort { $0.age < $1.age }

        let verts = buffer.contents().advanced(by: renderBufferOffset)
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: aliveCount * 2)
        let count = ropeKnotScratch.count
        // Carry the last valid normal across coincident knots so the ribbon does not spike.
        var lastNormal = SIMD2<Float>(0, 1)
        var written = 0
        for i in 0..<count {
            let prev = ropeKnotScratch[max(0, i - 1)].position
            let next = ropeKnotScratch[min(count - 1, i + 1)].position
            let tangent = next - prev
            let length = (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot()
            var normal = lastNormal
            if length > 1e-4 {
                let unit = tangent / length
                normal = SIMD2<Float>(-unit.y, unit.x)
                lastNormal = normal
            }
            let knot = ropeKnotScratch[i]
            let offset = normal * knot.halfSize
            let along = Float(i) / Float(count - 1)
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

    private func buildTrailGeometry() {
        guard let buffer = ropeVertexBuffer, trailPointCount >= 2 else {
            ropeVertexCount = 0
            return
        }
        let verts = buffer.contents().advanced(by: renderBufferOffset)
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: aliveCount * (trailPointCount * 2 + 2))
        let pointCount = trailPointCount
        let perRibbon = pointCount * 2 + 2
        var written = 0
        let overrideAlphaScale = animatedOverrideAlphaScale
        liveSlots.forEachLiveSlot { index in
            let particle = particles[index]
            guard written + perRibbon <= ropeVertexCapacity else { return }
            let attrs = drawAttributes(of: particle, overrideAlphaScale: overrideAlphaScale)
            let color = SIMD4<Float>(attrs.rgb.x, attrs.rgb.y, attrs.rgb.z, attrs.alpha)
            let halfSize = max(0, attrs.size * 0.5)
            resampleTrailRibbon(index, size: attrs.size, velocity: particle.velocity)
            let bridges = written > 0
            let ribbonStart = written + (bridges ? 2 : 0)
            var cursor = ribbonStart
            var lastNormal = SIMD2<Float>(0, 1)
            for point in 0..<pointCount {
                let prev = trailRibbonScratch[max(0, point - 1)]
                let next = trailRibbonScratch[min(pointCount - 1, point + 1)]
                let tangent = next - prev
                let length = (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot()
                var normal = lastNormal
                if length > 1e-4 {
                    let unit = tangent / length
                    normal = SIMD2<Float>(-unit.y, unit.x)
                    lastNormal = normal
                }
                let position = trailRibbonScratch[point] + SIMD2(instanceOriginOffset.x, instanceOriginOffset.y)
                let offset = normal * halfSize
                let along = Float(point) / Float(pointCount - 1)
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
        ropeVertexCount = written
    }

    /// Integrated position, not draw-space: an `oscillateposition` ribbon would trail straight.
    private func pushTrailPoint(_ index: Int) {
        let ring = Self.trailSampleCapacity
        let head = (trailSampleHead[index] + 1) % ring
        trailSampleHead[index] = head
        trailSamples[index * ring + head] = SIMD2<Float>(
            particles[index].position.x, particles[index].position.y
        )
        trailSampleFill[index] = min(trailSampleFill[index] + 1, ring)
    }

    /// Reset onto the spawn point so a reused slot does not inherit the previous path.
    private func resetTrailHistory(_ index: Int, to position: SIMD3<Float>) {
        trailSampleHead[index] = 0
        trailSampleFill[index] = 1
        trailSamples[index * Self.trailSampleCapacity] = SIMD2<Float>(position.x, position.y)
    }

    private func trailSample(_ index: Int, back: Int) -> SIMD2<Float> {
        let ring = Self.trailSampleCapacity
        let step = min(back, max(0, trailSampleFill[index] - 1))
        let slot = ((trailSampleHead[index] - step) % ring + ring) % ring
        return trailSamples[index * ring + slot]
    }

    /// Resample by distance so trail world-length is frame-rate independent.
    /// `length` sets how far back; `subdivision` is only the segment count.
    private func resampleTrailRibbon(_ index: Int, size: Float, velocity: SIMD3<Float>) {
        let pointCount = trailPointCount
        let head = trailSample(index, back: 0)
        trailRibbonScratch[0] = head
        guard pointCount > 1 else { return }
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        let trail = definition.trailRenderer
        let lengthCoefficient = Float(trail?.length ?? 0.05)
        let maxStretch = Float(trail?.maxLength ?? 10)
        // Floor 1 is ours: a collapsed ribbon vanishes (3426865175 parks meteors on a CP).
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
        // Pin leftover points to the oldest sample so a young trail does not invent history.
        while point < pointCount {
            trailRibbonScratch[point] = current
            point += 1
        }
    }

    var liveInstanceCount: Int { aliveCount }

    /// True once every spawn gate is permanently closed. False until the first tick so an untouched system always counts as live.
    private var emissionExhausted = false

    var isPermanentlyIdle: Bool {
        aliveCount == 0 && explicitlyRequestedParticles == 0 && (playback != .playing || emissionExhausted)
    }

    var isPaused: Bool {
        playback == .paused
    }

    var playbackSnapshot: WPEParticlePlaybackSnapshot {
        .init(liveParticleCount: aliveCount + explicitlyRequestedParticles,
              isEmitting: playback == .playing && !emissionExhausted)
    }

    func applyPlaybackCommand(_ command: WPEParticlePlaybackCommand) {
        switch command {
        case .play:
            if playback == .stopped || emissionExhausted {
                firstTickTime = nil
                lastTickTime = nil
                systemElapsed = 0
                rateElapsedAdjustment = 0
                lastFrameInterval = 0
                spawnAccumulator = 0
                hasEmittedBurst = false
                emissionExhausted = false
            }
            playback = .playing
        case .pause: playback = .paused
        case .stop:
            playback = .stopped
            explicitlyRequestedParticles = 0
            explicitBirths.removeAll(keepingCapacity: true)
            clearLiveParticles()
            ropeVertexCount = 0
        case let .modify(mutation): instanceValues.apply(mutation)
        case let .emit(count):
            requestEmission(count, values: instanceValues)
        }
    }

    func requestEmission(_ count: Int, values: WPEParticleInstanceValues) {
        let accepted = max(0, min(count, capacity - explicitlyRequestedParticles))
        guard accepted > 0 else { return }
        explicitlyRequestedParticles += accepted
        explicitBirths.append((accepted, values))
    }

    var tracksPointer: Bool {
        emitterTracksPointer
    }

    /// Pointer-locked emitter with nothing alive and no live pointer is not permanently idle; dropping .particles demand is safe only because pointer enter wakes a frame.
    var isBlockedOnAbsentPointer: Bool {
        tracksPointer && aliveCount == 0 && pointerCentered == nil
    }

    func clearLiveParticles() {
        liveSlots.forEachLiveSlot { index in
            particles[index].age = .greatestFiniteMagnitude
        }
        liveSlots.removeAll()
        particleEventsThisTick.removeAll(keepingCapacity: true)
        droppedParticleEventsThisTick = 0
        resetPrimaryCache()
        aliveCount = 0
        spawnAccumulator = 0
    }

    private func resetPrimaryCache() {
        cachedPrimaryAge = .greatestFiniteMagnitude
        cachedPrimarySlot = .max
    }

    /// Lexicographic (age, slot) min — identical to the old ascending strict-< scan,
    /// including a fresh spawn landing in a lower slot than an equal-age survivor.
    private func notePrimaryCandidate(age: Float, slot: Int) {
        if age < cachedPrimaryAge || (age == cachedPrimaryAge && slot < cachedPrimarySlot) {
            cachedPrimaryAge = age
            cachedPrimarySlot = slot
        }
    }

    func beginRecordingParticleEvents() {
        guard !recordsParticleEvents else { return }
        recordsParticleEvents = true
        particleEventsThisTick.reserveCapacity(min(capacity * 2, Self.maximumRecordedParticleEvents))
    }

    var primaryLiveParticleIdentity: WPEParticleIdentity? {
        guard cachedPrimarySlot < capacity, liveSlots.isLive(cachedPrimarySlot) else { return nil }
        return .init(slot: cachedPrimarySlot, generation: particleGenerations[cachedPrimarySlot])
    }

    func snapshot(for identity: WPEParticleIdentity) -> WPEParticleSnapshot? {
        guard identity.slot >= 0, identity.slot < capacity,
              liveSlots.isLive(identity.slot), particleGenerations[identity.slot] == identity.generation else { return nil }
        return particleSnapshot(at: identity.slot)
    }

    private func particleSnapshot(at slot: Int) -> WPEParticleSnapshot {
        let p = particles[slot]
        let current = drawAttributes(of: p, overrideAlphaScale: animatedOverrideAlphaScale)
        return WPEParticleSnapshot(identity: .init(slot: slot, generation: particleGenerations[slot]),
                                   position: p.position, displayPosition: current.position, velocity: p.velocity,
                                   initialColor: p.color, currentColor: current.rgb,
                                   initialAlpha: p.alphaBase, currentAlpha: current.alpha,
                                   initialSize: p.size, currentSize: current.size, rotationZ: p.rotationZ,
                                   age: min(p.age, p.lifetime), lifetime: p.lifetime)
    }

    private func recordParticleEvent(_ kind: WPEParticleEvent.Kind, slot: Int) {
        guard recordsParticleEvents else { return }
        guard particleEventsThisTick.count < Self.maximumRecordedParticleEvents else {
            droppedParticleEventsThisTick += 1
            return
        }
        particleEventsThisTick.append(.init(kind: kind, simulationTime: simulationNow, particle: particleSnapshot(at: slot)))
    }

    private var systemElapsed: Double = 0

    /// The previous tick's simulated interval; the catch-up bound scales with it.
    private var lastFrameInterval: Double = 0

    private func advance(now: Double) {
        guard now.isFinite else { return }
        particleEventsThisTick.removeAll(keepingCapacity: true)
        droppedParticleEventsThisTick = 0
        defer { lastTickTime = now }
        if firstTickTime == nil {
            firstTickTime = now
        }
        // A frame no longer than twice the previous one is simulated in full (a 1 FPS target
        // produces 1 s frames); anything longer is a resume from suspension and is bounded to
        // 0.1 s so the catch-up cannot emit one large batch. Each step is still at most 1/60 s.
        let raw = max(0, now - (lastTickTime ?? now))
        let delta = min(raw, max(0.1, 2 * lastFrameInterval))
        lastFrameInterval = delta
        // `rate` scales motion and births together (floor 0.01); events keep wall timestamps.
        let rate = max(0.01, min(64, instanceValues.rate))
        let steps = max(1, Int(ceil(delta * rate * 60 - 1e-6)))
        let wallStep = delta / Double(steps)
        rateElapsedAdjustment += (raw - delta) * (rate - 1)
        for index in 0 ..< steps {
            rateElapsedAdjustment += wallStep * (rate - 1)
            advanceStep(now: now - delta + Double(index + 1) * wallStep,
                        dt: Float(wallStep * rate))
        }
    }

    private func advanceStep(now: Double, dt: Float) {
        simulationNow = now
        let elapsed = now - (firstTickTime ?? now) + rateElapsedAdjustment
        systemElapsed = elapsed
        // Drag is `-2·strength·v` (algorism.h `DragForce`).
        let dragScalar: Float = max(0, 1 - 2 * Float(definition.drag) * dt)
        let angularDragScalar: Float = max(0, 1 - 2 * Float(definition.angularDrag) * dt)
        let angularForce = sceneTransform.visualAngularZ(localAngularZ: Float(definition.angularForceZ))
        let turbulenceOp = definition.turbulence
        let turbulenceScale = turbulenceOp.map { $0.scale * 2 } ?? 0
        let turbulenceTimescale = turbulenceOp.map(\.timescale) ?? 0
        let turbulenceMask = turbulenceOp.map {
            SIMD3<Double>($0.mask.x, $0.mask.y, $0.mask.z)
        } ?? .zero
        resolvedAttractors.removeAll(keepingCapacity: true)
        for attractor in attractors {
            guard let cp = controlPointPosition(attractor.controlPointID) else { continue }
            resolvedAttractors.append(ResolvedAttractor(
                position: cp,
                threshold: Float(attractor.threshold),
                scale: Float(attractor.scale)
            ))
        }

        // `duration` bounds births only. After pre-sim, starttime is history so the window starts at 0.
        let emissionStart = presimulatingStartDelay || startDelayWasPresimulated
            ? 0
            : max(0, definition.startDelay)
        let hasStartedEmitting = presimulatingStartDelay || elapsed >= emissionStart
        let isWithinDuration = definition.duration.map {
            elapsed <= emissionStart + $0
        } ?? true
        let emitterCanSpawn = definition.emitterShape.isRuntimeSupported
        if explicitlyRequestedParticles > 0 {
            let currentValues = instanceValues
            explicitlyRequestedParticles = 0
            for request in explicitBirths {
                instanceValues = request.values
                for _ in 0 ..< request.count {
                    guard let slot = nextFreeSlot() else { break }
                    spawn(into: slot)
                }
            }
            instanceValues = currentValues
            explicitBirths.removeAll(keepingCapacity: true)
        }
        if playback == .playing, hasStartedEmitting, emitterCanSpawn {
            if definition.instantaneousCount > 0, !hasEmittedBurst,
               isWithinDuration || (lastTickTime ?? emissionStart) <= emissionStart {
                var blocked = false
                var emitted = 0
                for _ in 0 ..< min(capacity, Int(min(Double(capacity), max(0, Double(definition.instantaneousCount) * instanceValues.count)))) {
                    guard let slot = nextFreeSlot() else { break }
                    if !spawn(into: slot) {
                        // No live cursor: retry the burst next tick instead of burning it.
                        blocked = true
                        break
                    }
                    emitted += 1
                }
                // Burst births consume the rate's emission budget, so the next rate birth waits a full period.
                spawnAccumulator -= Double(emitted)
                if !blocked {
                    hasEmittedBurst = true
                }
            }
            if isWithinDuration, definition.rate > 0 {
                // Audio response scales the continuous rate only — bursts stay
                // authored-size (reference: AudioResponseScale multiplies emit_speed).
                var rate = definition.rate * max(0, instanceValues.count)
                if let audioState = definition.emitterAudioState, let spectrum = audioSpectrum16 {
                    rate *= audioState.emissionScale(spectrum16: spectrum)
                }
                spawnAccumulator += Double(dt) * rate
                // A failed spawn leaves its slot free, so only success or a full pool bounds this loop.
                while spawnAccumulator >= 1 {
                    spawnAccumulator -= 1
                    guard let slot = nextFreeSlot(), spawn(into: slot) else { break }
                }
                spawnAccumulator = min(spawnAccumulator, 1)
            }
        }

        resetPrimaryCache()
        var attractorAffectedThisTick = 0
        for wordIndex in 0..<liveSlots.wordCount {
            var liveWord = liveSlots.word(at: wordIndex)
            while liveWord != 0 {
                let index = wordIndex << 6 | liveWord.trailingZeroBitCount
                liveWord &= liveWord &- 1
                let remainingLifetime = max(0, particles[index].lifetime - particles[index].age)
                let expires = remainingLifetime <= dt
                let particleDT = min(dt, remainingLifetime)
                particles[index].age += particleDT
                let particleDrag = expires ? max(0, 1 - 2 * Float(definition.drag) * particleDT) : dragScalar
                let particleAngularDrag = expires ? max(0, 1 - 2 * Float(definition.angularDrag) * particleDT) : angularDragScalar
                particles[index].velocity += gravity * (particleDT * particles[index].speedScale)
                if particleDrag < 1 {
                    particles[index].velocity *= particleDrag
                }
                if !resolvedAttractors.isEmpty {
                    let pos = particles[index].position
                    var affectedThisParticle = false
                    for attractor in resolvedAttractors {
                        let dx = attractor.position.x - pos.x
                        let dy = attractor.position.y - pos.y
                        let dist = (dx * dx + dy * dy).squareRoot()
                        guard dist > 1e-3, dist < attractor.threshold else { continue }
                        let falloff = 1 - dist / attractor.threshold
                        let accel = attractor.scale * falloff / dist
                        particles[index].velocity.x += dx * accel * particleDT * particles[index].speedScale
                        particles[index].velocity.y += dy * accel * particleDT * particles[index].speedScale
                        affectedThisParticle = true
                    }
                    if affectedThisParticle { attractorAffectedThisTick += 1 }
                }
                if turbulenceOp != nil, particles[index].turbulenceSpeed > 0 {
                    let pos = particles[index].position
                    let sample = SIMD3<Double>(
                        Double(pos.x) + Double(particles[index].turbulencePhase) + turbulenceTimescale * elapsed,
                        Double(pos.y),
                        Double(pos.z)
                    ) * turbulenceScale
                    let dir = WPEParticleCurlNoise.direction(at: sample)
                    let speed = Double(particles[index].turbulenceSpeed * particles[index].speedScale)
                    particles[index].velocity.x += Float(dir.x * speed * turbulenceMask.x) * particleDT
                    particles[index].velocity.y += Float(dir.y * speed * turbulenceMask.y) * particleDT
                    particles[index].velocity.z += Float(dir.z * speed * turbulenceMask.z) * particleDT
                }
                particles[index].position += particles[index].velocity * particleDT
                particles[index].angularVelocityZ += angularForce * particleDT
                if particleAngularDrag < 1 {
                    particles[index].angularVelocityZ *= particleAngularDrag
                }
                particles[index].rotationZ += particles[index].angularVelocityZ * particleDT
                if trailPointCount > 0 {
                    pushTrailPoint(index)
                }
                if expires {
                    // Windows eventdeath/follow freezes at the lifetime endpoint,
                    // not the last still-live frame's position.
                    recordParticleEvent(.death, slot: index)
                    particles[index].age = .greatestFiniteMagnitude
                    liveSlots.markDead(index)
                    aliveCount -= 1
                    continue
                }
                notePrimaryCandidate(age: particles[index].age, slot: index)
            }
        }
        lastAttractorAffectedCount = attractorAffectedThisTick

        // Mirrors the spawn gates above: once every gate is closed no later tick can reopen one. Pointer-blocked bursts stay not-exhausted.
        let rateExhausted = !emitterCanSpawn || definition.rate <= 0 || !isWithinDuration
        let burstExhausted = !emitterCanSpawn || definition.instantaneousCount <= 0 || hasEmittedBurst
        emissionExhausted = hasStartedEmitting && rateExhausted && burstExhausted
    }

    #if !LITE_BUILD && DEBUG
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

    func particleTraceVertices(limit: Int = 256) -> (records: [[String: Any]], truncated: Bool) {
        var records: [[String: Any]] = []
        if usesRibbonGeometry {
            guard let buffer = ropeVertexBuffer, ropeVertexCount > 0 else { return ([], false) }
            let verts = buffer.contents().advanced(by: renderBufferOffset).bindMemory(
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
        guard alive > 0, !usesFrameArena || renderSlice != nil else { return ([], false) }
        let pointer = instanceBuffer.contents().advanced(by: renderBufferOffset).bindMemory(
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

    /// `fadeintime` / `fadeouttime` are lifetime fractions, not seconds.
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

    private func nextFreeSlot() -> Int? {
        liveSlots.lowestFreeSlot
    }

    @discardableResult
    private func spawn(into slot: Int) -> Bool {
        let dispersal: SIMD3<Float>
        switch definition.emitterShape {
        case .box:
            let point = Self.boxEmitterDispersal(
                minimum: definition.dispersalMin,
                maximum: definition.dispersalMax,
                directions: definition.directionMask,
                samples: SIMD3<Double>(
                    uniform(-1, 1),
                    uniform(-1, 1),
                    uniform(-1, 1)
                )
            )
            dispersal = SIMD3<Float>(
                Float(point.x),
                Float(point.y),
                Float(point.z)
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
            let axisScale = SIMD3<Double>(abs(definition.directionMask.x),
                                          abs(definition.directionMask.y),
                                          abs(definition.directionMask.z))
            let signedPoint = Self.applyEmitterSign(normal * axisScale * radius, sign: definition.sign)
            dispersal = SIMD3<Float>(
                Float(signedPoint.x), Float(signedPoint.y), Float(signedPoint.z)
            )
        case .unsupported:
            return false
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
        guard let center = controlPointPosition(definition.emitterControlPointID) else { return false }
        let position = center + sceneTransform.applyModelDirection(localPoint)
        let velocity = sceneTransform.applyModelDirection(localVelocity) * Float(max(0, instanceValues.speed))
        let sizeScale: Float = if isNestedChildSystem {
            childWorldSizeMultiplier
        } else {
            // Refraction changes sampling, not geometry. The instanced shader receives
            // world-sized quads and never applies the scene object's scale again.
            spawnWorldSizeMultiplier
        }
        // `sizerandom`: min + (max-min)·rand^exp (exp>1 biases toward min).
        let sizeSample: Double
        if abs(definition.sizeExponent - 1) < 0.0001 {
            sizeSample = uniform(definition.sizeMin, definition.sizeMax)
        } else if definition.sizeMax > definition.sizeMin {
            let r = pow(Double.random(in: 0...1, using: &rng), definition.sizeExponent)
            sizeSample = definition.sizeMin + (definition.sizeMax - definition.sizeMin) * r
        } else {
            sizeSample = definition.sizeMin
        }
        var size = Float(sizeSample) * sizeScale * Float(max(0, instanceValues.size))
        if blendMode == .additive {
            size = min(size, sceneTransform.sceneHeight)
        }
        // Keep the RNG sequence stable even when a scripted colorn replaces it.
        let sampledColor = lerpVector(definition.colorMin, definition.colorMax)
        let colorn = SIMD3<Float>(Float(instanceValues.colorn.x), Float(instanceValues.colorn.y), Float(instanceValues.colorn.z))
        let rawColor = instanceValues.replacesColor
            ? colorn * (255 * instanceColorBrightnessScale)
            : sampledColor * colorn
        let lifetime = Float(uniform(definition.lifetimeMin, definition.lifetimeMax) * max(0.0001, instanceValues.lifetime))
        let alpha = Float(uniform(definition.alphaMin, definition.alphaMax) * max(0, instanceValues.alpha))
        let rotationVec = uniformVector(definition.rotationMin, definition.rotationMax)
        let angularVec = uniformVector(definition.angularVelocityMin, definition.angularVelocityMax)
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
            // Phase is sampled over [phasemin, phasemax + 2π].
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
        let staticFrame: Float
        if definition.animationMode == .randomFrame, let sheet = spriteSheet, sheet.frameCount > 1 {
            staticFrame = Float(Int.random(in: 0..<sheet.frameCount, using: &rng))
        } else {
            staticFrame = 0
        }
        particles[slot] = Particle(
            position: position,
            velocity: velocity,
            speedScale: Float(max(0, instanceValues.speed)),
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
        particleGenerations[slot] &+= 1
        liveSlots.markLive(slot)
        aliveCount += 1
        notePrimaryCandidate(age: 0, slot: slot)
        if trailPointCount > 0 {
            resetTrailHistory(slot, to: position)
        }
        recordParticleEvent(.spawn, slot: slot)
        return true
    }

    private func seedTurbulentVelocity(_ tvi: WPEParticleTurbulentVelocityInit) -> SIMD3<Float> {
        let speed = uniform(tvi.speedMin, tvi.speedMax)
        var duration = definition.rate > 0 ? 1 / definition.rate : .infinity
        if duration > 10 {
            turbulentSamplePoint.x += speed
            duration = 0
        }
        let forward = simd_normalize(tvi.forward)
        // Guard 0: timescale divides the step and would send the sample to infinity.
        let timescale = tvi.timescale.isFinite && tvi.timescale > 0 ? tvi.timescale : 1
        let step = 0.005 / timescale
        var dir: SIMD3<Double>
        repeat {
            dir = WPEParticleCurlNoise.direction(at: turbulentSamplePoint, fallback: forward)
            turbulentSamplePoint += dir * step
            duration -= 0.01
        } while duration > 0.01
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
