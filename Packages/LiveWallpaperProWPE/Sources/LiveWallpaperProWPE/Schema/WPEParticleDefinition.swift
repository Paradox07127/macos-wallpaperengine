import CoreGraphics
import Foundation
import LiveWallpaperCore

/// WPE particle blend → Metal factors; unknown → `.translucent` (safe default).
public enum WPEParticleBlendMode: String, Sendable, CaseIterable, Equatable {
    case normal
    case translucent
    case additive

    public init(materialString: String?) {
        guard let raw = materialString?.lowercased() else {
            self = .translucent
            return
        }
        self = WPEParticleBlendMode(rawValue: raw) ?? .translucent
    }
}

/// Sprite-atlas walk. Missing `animationmode` → `.sequence`.
/// `.randomFrame` = one static atlas cell per particle (shatter/debris).
public enum WPEParticleAnimationMode: String, Sendable, Equatable, CaseIterable {
    case sequence
    case randomFrame

    public init(wpeString raw: String?) {
        switch raw?.lowercased() {
        case "randomframe": self = .randomFrame
        default: self = .sequence
        }
    }
}

/// Emitter/operator anchor. id 0 = spawn origin; `flags & 1` = lock to pointer.
public struct WPEParticleControlPoint: Equatable, Sendable {
    public let id: Int
    public let offset: SIMD3<Double>
    public let pointerLocked: Bool
    /// Authored `flags`, when present and non-null. Keep the raw value because WPE exposes more modes than the simulator consumes.
    public let flagsRaw: Int?
    /// Authored control-point `angles`; nil when absent or JSON null.
    public let angles: SIMD3<Double>?

    /// Bit 1 (`2`) is worldspace.
    public var isWorldSpace: Bool {
        flagsRaw.map { ($0 & 2) != 0 } ?? false
    }

    public init(
        id: Int,
        offset: SIMD3<Double>,
        pointerLocked: Bool,
        flagsRaw: Int? = nil,
        angles: SIMD3<Double>? = nil
    ) {
        self.id = id
        self.offset = offset
        self.pointerLocked = pointerLocked
        self.flagsRaw = flagsRaw
        self.angles = angles
    }
}

/// `controlpointattract`: force toward/away from a control point within `threshold`.
public struct WPEParticleControlPointAttractor: Equatable, Sendable {
    public let controlPointID: Int
    public let scale: Double
    public let threshold: Double

    public init(controlPointID: Int, scale: Double, threshold: Double) {
        self.controlPointID = controlPointID
        self.scale = scale
        self.threshold = max(0, threshold)
    }
}

/// Child system ref. Same path + different origins is intentional — keep order, do not dedupe.
public struct WPEParticleChildReference: Equatable, Sendable {
    public let id: Int?
    public let relativePath: String
    public let originOffset: SIMD3<Double>
    public let type: String?
    /// Optional: missing/null and explicit zero have different authored shapes.
    public let maxCount: Int?
    public let angles: SIMD3<Double>?
    /// Authored child flags, kept opaque except for the reference-backed legacy
    /// event-follow bit used below.
    public let flagsRaw: Int?
    /// Presence is significant; do not synthesize a default.
    public let controlPointStartIndex: Int?
    /// Rolled once per event when the event condition is met, not once per scene.
    public let probability: Double
    /// Spawn-time child-system transform, sibling of `origin`/`angles`, not a `sizerandom` multiplier. Per-axis vector; do not collapse Z or anisotropy.
    public let scale: SIMD3<Double>

    /// `type: "eventfollow"` rides the parent's live particles. Legacy `flags & 2` only when `type` is absent; an authored type always wins.
    public var isEventFollow: Bool {
        effectiveType == "eventfollow"
    }

    /// Event-driven children re-roll `probability` on every event. `static`
    /// children roll once, when the system is created.
    public var rollsProbabilityPerEvent: Bool {
        switch effectiveType {
        case "eventfollow", "eventspawn", "eventdeath": return true
        default: return false
        }
    }

    private var effectiveType: String? {
        if let type { return type.lowercased() }
        return flagsRaw.map { ($0 & 2) != 0 } == true ? "eventfollow" : nil
    }

    public init(
        id: Int? = nil,
        relativePath: String,
        originOffset: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        type: String? = nil,
        maxCount: Int? = nil,
        angles: SIMD3<Double>? = nil,
        flagsRaw: Int? = nil,
        controlPointStartIndex: Int? = nil,
        probability: Double = 1,
        scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1)
    ) {
        self.id = id
        self.relativePath = relativePath
        self.originOffset = originOffset
        self.type = type
        self.maxCount = maxCount
        self.angles = angles
        self.flagsRaw = flagsRaw
        self.controlPointStartIndex = controlPointStartIndex
        self.probability = min(max(probability, 0), 1)
        self.scale = scale
    }
}

public enum WPEParticleComponentArrayKind: String, CaseIterable, Equatable, Sendable {
    case emitters = "emitter"
    case renderers = "renderer"
    case initializers = "initializer"
    case operators = "operator"
    case children
    case controlPoints = "controlpoint"
}

public struct WPEParticleRawComponentBag: Equatable, Sendable {
    public let emitters: [WPESceneJSONValue]
    public let renderers: [WPESceneJSONValue]
    public let initializers: [WPESceneJSONValue]
    public let operators: [WPESceneJSONValue]
    public let children: [WPESceneJSONValue]
    public let controlPoints: [WPESceneJSONValue]

    public init(sourceJSON: WPESceneJSONValue) {
        func array(_ kind: WPEParticleComponentArrayKind) -> [WPESceneJSONValue] {
            guard let authored = sourceJSON[kind.rawValue],
                  case .array(let values) = authored else { return [] }
            return values
        }
        self.emitters = array(.emitters)
        self.renderers = array(.renderers)
        self.initializers = array(.initializers)
        self.operators = array(.operators)
        self.children = array(.children)
        self.controlPoints = array(.controlPoints)
    }

    public subscript(kind: WPEParticleComponentArrayKind) -> [WPESceneJSONValue] {
        switch kind {
        case .emitters: emitters
        case .renderers: renderers
        case .initializers: initializers
        case .operators: operators
        case .children: children
        case .controlPoints: controlPoints
        }
    }
}

/// `alphachange` operator: a lifetime-fraction alpha multiplier ramp from
/// `startValue` to `endValue` over `[startTime, endTime]` (lifetime fractions).
public struct WPEParticleAlphaChange: Equatable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let startValue: Double
    public let endValue: Double

    public init(startTime: Double, endTime: Double, startValue: Double, endValue: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.startValue = startValue
        self.endValue = endValue
    }

    public func factor(lifetimeFraction: Double) -> Double {
        wpeParticleLifetimeRamp(
            lifetimeFraction,
            startTime: startTime, endTime: endTime,
            startValue: startValue, endValue: endValue
        )
    }
}

/// Cosine lerps alpha across `[scaleMin, scaleMax]`. Frequency/phase are per-particle at spawn. Authored frequency is `w` — do not fold in another 2π.
public struct WPEParticleOscillateAlpha: Equatable, Sendable {
    public let frequencyMin: Double
    public let frequencyMax: Double
    public let scaleMin: Double
    public let scaleMax: Double
    public let phaseMin: Double
    public let phaseMax: Double

    public init(
        frequencyMin: Double,
        frequencyMax: Double,
        scaleMin: Double,
        scaleMax: Double,
        phaseMin: Double,
        phaseMax: Double
    ) {
        self.frequencyMin = frequencyMin
        self.frequencyMax = frequencyMax
        self.scaleMin = scaleMin
        self.scaleMax = scaleMax
        self.phaseMin = phaseMin
        self.phaseMax = phaseMax
    }

    /// `frequency`/`phase` come from the particle's spawn-time draw.
    public func factor(age: Double, frequency: Double, phase: Double) -> Double {
        guard frequency != 0 else { return 1 }
        let wave = (cos(frequency * age + phase) + 1) * 0.5
        return min(max(scaleMin + (scaleMax - scaleMin) * wave, 0), 1)
    }
}

/// Same cosine as oscillate-alpha but size is not clamped to 0…1 (authors enlarge past 1). Scale defaults 0.8…1.2, not FrequencyValue's 0…1.
public struct WPEParticleOscillateSize: Equatable, Sendable {
    public let frequencyMin: Double
    public let frequencyMax: Double
    public let scaleMin: Double
    public let scaleMax: Double
    public let phaseMin: Double
    public let phaseMax: Double

    public init(
        frequencyMin: Double,
        frequencyMax: Double,
        scaleMin: Double,
        scaleMax: Double,
        phaseMin: Double,
        phaseMax: Double
    ) {
        self.frequencyMin = frequencyMin
        self.frequencyMax = frequencyMax
        self.scaleMin = scaleMin
        self.scaleMax = scaleMax
        self.phaseMin = phaseMin
        self.phaseMax = phaseMax
    }

    /// `frequency`/`phase` come from the particle's spawn-time draw. Clamped at 0 only — the
    /// upper end is whatever the author asked for.
    public func factor(age: Double, frequency: Double, phase: Double) -> Double {
        guard frequency != 0 else { return 1 }
        let wave = (cos(frequency * age + phase) + 1) * 0.5
        return max(scaleMin + (scaleMax - scaleMin) * wave, 0)
    }
}

/// Shader stretch is `clamp(speed * length, min, maxLength)`. Defaults length 0.05, maxlength 10, subdivision 3 — absent maxlength is 10, not unbounded.
public struct WPEParticleTrailRenderer: Equatable, Sendable {
    /// `spritetrail` = velocity-stretched quad. `ropetrail` = ribbon through the particle's own history; length is UV scale, not velocity stretch. A `.rope` trail must never take the `spritetrail` path.
    public enum Kind: Sendable, Equatable { case sprite, rope }
    public let kind: Kind
    public let length: Double
    public let maxLength: Double
    /// `nil` = missing or JSON null (no established engine default). Runtime consumption gated to `.sprite`.
    public let minLength: Double?
    /// Trail segment count — `subdivision`, NOT `length`. The default 3 is why
    /// RenderDoc shows `trailPosition` cycling 0,1,2,3 (4 points per particle).
    public let subdivision: Double

    public init(
        kind: Kind,
        length: Double,
        maxLength: Double,
        minLength: Double? = nil,
        subdivision: Double
    ) {
        self.kind = kind
        self.length = length
        self.maxLength = maxLength
        self.minLength = minLength
        self.subdivision = subdivision
    }
}

@inline(__always)
func wpeParticleLifetimeRamp(
    _ lifetimeFraction: Double,
    startTime: Double,
    endTime: Double,
    startValue: Double,
    endValue: Double
) -> Double {
    let fraction = min(max(lifetimeFraction, 0), 1)
    let span = endTime - startTime
    let t: Double
    if abs(span) < 0.000_001 {
        t = fraction >= endTime ? 1 : 0
    } else {
        t = min(max((fraction - startTime) / span, 0), 1)
    }
    return startValue + (endValue - startValue) * t
}

/// Lifetime-fraction SIZE multiplier ramp (same shape as alphachange).
public struct WPEParticleSizeChange: Equatable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let startValue: Double
    public let endValue: Double

    public init(startTime: Double, endTime: Double, startValue: Double, endValue: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.startValue = startValue
        self.endValue = endValue
    }

    public func factor(lifetimeFraction: Double) -> Double {
        wpeParticleLifetimeRamp(
            lifetimeFraction,
            startTime: startTime, endTime: endTime,
            startValue: startValue, endValue: endValue
        )
    }
}

/// Lifetime-fraction RGB multiplier ramp; channels are 0…1 tint multipliers.
public struct WPEParticleColorChange: Equatable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let startColor: SIMD3<Double>
    public let endColor: SIMD3<Double>

    public init(startTime: Double, endTime: Double, startColor: SIMD3<Double>, endColor: SIMD3<Double>) {
        self.startTime = startTime
        self.endTime = endTime
        self.startColor = startColor
        self.endColor = endColor
    }

    public func color(lifetimeFraction: Double) -> SIMD3<Double> {
        SIMD3<Double>(
            wpeParticleLifetimeRamp(lifetimeFraction, startTime: startTime, endTime: endTime,
                                    startValue: startColor.x, endValue: endColor.x),
            wpeParticleLifetimeRamp(lifetimeFraction, startTime: startTime, endTime: endTime,
                                    startValue: startColor.y, endValue: endColor.y),
            wpeParticleLifetimeRamp(lifetimeFraction, startTime: startTime, endTime: endTime,
                                    startValue: startColor.z, endValue: endColor.z)
        )
    }
}

/// Amplitude `scale` is in pixels. Displacement is derived from age each frame, never integrated into stored position.
public struct WPEParticleOscillatePosition: Equatable, Sendable {
    public let frequencyMin: Double
    public let frequencyMax: Double
    public let scaleMin: Double
    public let scaleMax: Double
    public let phaseMin: Double
    public let phaseMax: Double
    public let mask: SIMD3<Double>

    public init(
        frequencyMin: Double, frequencyMax: Double,
        scaleMin: Double, scaleMax: Double,
        phaseMin: Double, phaseMax: Double,
        mask: SIMD3<Double>
    ) {
        self.frequencyMin = min(frequencyMin, frequencyMax)
        self.frequencyMax = max(frequencyMin, frequencyMax)
        self.scaleMin = min(scaleMin, scaleMax)
        self.scaleMax = max(scaleMin, scaleMax)
        self.phaseMin = min(phaseMin, phaseMax)
        self.phaseMax = max(phaseMin, phaseMax)
        self.mask = mask
    }
}

/// Spawn-once curl-noise velocity, not the per-frame operator. `scale` is cone width as a fraction of a hemisphere (`2` = every direction). `offset` rotates the stream about `right` (leaves `offset: 3` ≈ 172° turns +Y to nearly -Y).
public struct WPEParticleTurbulentVelocityInit: Equatable, Sendable {
    public let speedMin: Double
    public let speedMax: Double
    public let scale: Double
    public let timescale: Double
    public let offset: Double
    public let phaseMin: Double
    public let phaseMax: Double
    public let forward: SIMD3<Double>
    public let right: SIMD3<Double>

    public init(
        speedMin: Double = 100,
        speedMax: Double = 250,
        scale: Double = 1,
        timescale: Double = 1,
        offset: Double = 0,
        phaseMin: Double = 0,
        phaseMax: Double = 0.1,
        forward: SIMD3<Double> = SIMD3<Double>(0, 1, 0),
        right: SIMD3<Double> = SIMD3<Double>(0, 0, 1)
    ) {
        self.speedMin = min(speedMin, speedMax)
        self.speedMax = max(speedMin, speedMax)
        self.scale = max(0, scale)
        self.timescale = timescale
        self.offset = offset
        self.phaseMin = min(phaseMin, phaseMax)
        self.phaseMax = max(phaseMin, phaseMax)
        self.forward = forward
        self.right = right
    }
}

/// Per-frame curl-noise acceleration: `velocity += speed · normalize(curl((pos + X·(phase + timescale·t))·2·scale)) · mask · dt`.
public struct WPEParticleTurbulenceOperator: Equatable, Sendable {
    public let speedMin: Double
    public let speedMax: Double
    public let scale: Double
    public let timescale: Double
    public let phaseMin: Double
    public let phaseMax: Double
    public let mask: SIMD3<Double>

    public init(
        speedMin: Double = 500,
        speedMax: Double = 1000,
        scale: Double = 0.01,
        timescale: Double = 20,
        phaseMin: Double = 0,
        phaseMax: Double = 0,
        mask: SIMD3<Double> = SIMD3<Double>(1, 1, 0)
    ) {
        self.speedMin = min(speedMin, speedMax)
        self.speedMax = max(speedMin, speedMax)
        self.scale = max(0, scale)
        self.timescale = timescale
        self.phaseMin = min(phaseMin, phaseMax)
        self.phaseMax = max(phaseMin, phaseMax)
        self.mask = SIMD3<Double>(max(0, mask.x), max(0, mask.y), max(0, mask.z))
    }
}

/// `sphererandom` scatters within a radius; `boxrandom` samples each axis from its distance range and applies `directions`.
public enum WPEParticleEmitterShape: String, Sendable, Equatable {
    case sphere
    case box
    case unsupported

    public var isRuntimeSupported: Bool {
        self != .unsupported
    }
}

public indirect enum WPEParticleRawJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WPEParticleRawJSONValue])
    case object([String: WPEParticleRawJSONValue])

    fileprivate init?(_ raw: Any) {
        if raw is NSNull {
            self = .null
        } else if let value = WPEValueParser.strictBool(raw) {
            self = .bool(value)
        } else if let value = raw as? NSNumber {
            self = .number(value.doubleValue)
        } else if let value = raw as? String {
            self = .string(value)
        } else if let values = raw as? [Any] {
            var parsed: [WPEParticleRawJSONValue] = []
            parsed.reserveCapacity(values.count)
            for value in values {
                guard let item = WPEParticleRawJSONValue(value) else { return nil }
                parsed.append(item)
            }
            self = .array(parsed)
        } else if let values = raw as? [String: Any] {
            var parsed: [String: WPEParticleRawJSONValue] = [:]
            parsed.reserveCapacity(values.count)
            for (key, value) in values {
                guard let item = WPEParticleRawJSONValue(value) else { return nil }
                parsed[key] = item
            }
            self = .object(parsed)
        } else {
            return nil
        }
    }
}

public struct WPEParticleEmitterAudioState: Equatable, Sendable {
    public let mode: Int?
    public let frequencyStart: Double?
    public let frequencyEnd: Double?
    public let bounds: [Double]?
    public let exponent: Double?
    public let amount: Double?
    public let rawFields: [String: WPEParticleRawJSONValue]

    public init(
        mode: Int? = nil,
        frequencyStart: Double? = nil,
        frequencyEnd: Double? = nil,
        bounds: [Double]? = nil,
        exponent: Double? = nil,
        amount: Double? = nil,
        rawFields: [String: WPEParticleRawJSONValue] = [:]
    ) {
        self.mode = mode
        self.frequencyStart = frequencyStart
        self.frequencyEnd = frequencyEnd
        self.bounds = bounds
        self.exponent = exponent
        self.amount = amount
        self.rawFields = rawFields
    }

    /// `audioprocessingmode != 0` is the only enable gate (reference parser:
    /// `.enable = wpe.audioprocessingmode != u32()`).
    public var isEnabled: Bool { (mode ?? 0) != 0 }

    /// Mean of clamped `[frequencyStart, frequencyEnd]` (defaults 0…15), linearly normalized against `bounds` (defaults 0…1, not material smoothstep), raised to `max(0.001, exponent)`, then `max(0, 1 + level·amount)`. Silence ⇒ 1.
    public func emissionScale(spectrum16: [Float]) -> Double {
        guard isEnabled, !spectrum16.isEmpty else { return 1 }
        let maxIndex = spectrum16.count - 1
        func bandIndex(_ value: Double) -> Int {
            min(max(WPEValueParser.saturatingInt(value.rounded()), 0), maxIndex)
        }
        var first = bandIndex(frequencyStart ?? 0)
        var last = bandIndex(frequencyEnd ?? Double(maxIndex))
        if last < first { swap(&first, &last) }
        var level = 0.0
        for index in first...last { level += Double(max(0, spectrum16[index])) }
        level /= Double(last - first + 1)
        let low = min(bounds?.first ?? 0, bounds?.dropFirst().first ?? 1)
        let high = max(bounds?.first ?? 0, bounds?.dropFirst().first ?? 1)
        if high > low { level = (level - low) / (high - low) }
        level = min(max(level, 0), 1)
        level = pow(level, max(0.001, exponent ?? 1))
        return max(0, 1 + level * (amount ?? 1))
    }
}

public struct WPEParticleDefinition: Equatable, Sendable {
    public let sourceJSON: WPESceneJSONValue
    public let rawComponents: WPEParticleRawComponentBag
    public let materialRelativePath: String?
    public let childReferences: [WPEParticleChildReference]
    /// Empty `renderer: []` is a simulation-only spawner and must not register a drawable system.
    public let rendersSprite: Bool
    /// Keyframed `instanceoverride.alpha`, applied per frame by the system
    /// (NOT baked into `alphaMin/alphaMax` — see `applying(instanceOverride:)`).
    public let overrideAlphaAnimation: WPESceneAnimatedValue?
    /// `renderer: [{name:"rope"}]` threads one ribbon through the particle chain as a triangle strip, not instanced quads.
    public let isRope: Bool
    /// `spritetrail` stretches along velocity; `ropetrail` ribbons through each particle's own history. Distinct from `isRope` (one ribbon through the whole chain).
    public let trailRenderer: WPEParticleTrailRenderer?
    /// `ropetrail`: per-particle history ribbon. Derived from `trailRenderer.kind`
    /// rather than stored, so parse can't disagree with the taxonomy.
    public var usesTrailRibbon: Bool { trailRenderer?.kind == .rope }
    public let maxCount: Int
    public let rate: Double
    /// One-time burst at emitter start, in addition to `rate`. Zero ⇒ rate-only emission.
    public let instantaneousCount: Int
    public let startDelay: Double
    /// `nil` = unbounded emission; a finite value stops future births without killing particles already alive.
    public let duration: Double?
    /// Authored emitter `flags`, preserved as an opaque integer. In particular,
    /// bit 0 is NOT interpreted as one-per-frame without Windows-side evidence.
    public let emitterFlagsRaw: Int?
    public let emitterAudioState: WPEParticleEmitterAudioState?
    public let lifetimeMin: Double
    public let lifetimeMax: Double
    public let sizeMin: Double
    public let sizeMax: Double
    /// WPE samples `min + (max-min)·rand^exp` (default 1); exp>1 biases toward min.
    public let sizeExponent: Double
    public let originOffset: SIMD3<Double>
    /// `.sphere` uses dispersalMin/Max `.x` as radius. `.box` samples each axis with `min + U(-1...1) * (max - min)`, then multiplies by `directions`.
    public let emitterShape: WPEParticleEmitterShape
    /// Sphere reads `.x` as radius; box reads all three as interpolation endpoints so `distancemax: "1200 1000 0"` survives.
    public let dispersalMin: SIMD3<Double>
    public let dispersalMax: SIMD3<Double>
    public let directionMask: SIMD3<Double>
    /// Normalized to -1/0/1 per axis (`v != 0 ? v / abs(v) : 0`); a nonzero axis forces sphere dispersal to `abs(value) * sign`.
    public let sign: SIMD3<Double>
    /// Emitter-authored radial launch speed along the normalized dispersal vector.
    public let emitterSpeedMin: Double
    public let emitterSpeedMax: Double
    public let velocityMin: SIMD3<Double>
    public let velocityMax: SIMD3<Double>
    public let colorMin: SIMD3<Double>
    public let colorMax: SIMD3<Double>
    /// Tracks explicit `color`/`colorrandom` initialization because `colorchange` must not recolor an unauthored base.
    /// Instance-level `colorn` remains applicable independently.
    public let hasColorInitializer: Bool
    /// Explicit `"animationmode": "sequence"` or a non-null `sequencemultiplier`. `animationMode` alone cannot distinguish this — omitted `animationmode` also defaults to `.sequence`.
    public let declaresSequenceAnimation: Bool
    /// True when `flags & 4` enables depth-aware perspective sizing and motion.
    public let isPerspective: Bool
    public let turbulentVelocityInit: WPEParticleTurbulentVelocityInit?
    public let turbulence: WPEParticleTurbulenceOperator?
    /// Per-particle base alpha sampled on spawn (alpharandom). The
    /// fade-in/out envelope multiplies this value at draw time.
    public let alphaMin: Double
    public let alphaMax: Double
    /// Only Z drives the 2D quad orientation.
    public let rotationMin: SIMD3<Double>
    public let rotationMax: SIMD3<Double>
    /// Angular-velocity initializer (radians/s); Z drives 2D spin.
    public let angularVelocityMin: SIMD3<Double>
    public let angularVelocityMax: SIMD3<Double>
    public let fadeInSeconds: Double
    public let fadeOutSeconds: Double
    public let alphaChange: WPEParticleAlphaChange?
    public let oscillateAlpha: WPEParticleOscillateAlpha?
    public let oscillateSize: WPEParticleOscillateSize?
    public let sizeChange: WPEParticleSizeChange?
    public let colorChange: WPEParticleColorChange?
    public let oscillatePosition: WPEParticleOscillatePosition?
    /// `operator: movement.gravity` (world units / s²) and drag scalar.
    public let gravity: SIMD3<Double>
    public let drag: Double
    /// `operator: angularmovement` — applied on rotationZ.
    public let angularForceZ: Double
    public let angularDrag: Double
    /// Multiplies `.tex-json` `frames/duration` rate. `1` is the WPE default; `0` freezes on frame 0.
    public let sequenceMultiplier: Double
    public let animationMode: WPEParticleAnimationMode
    /// Parsed control points (mouse anchors). `id 0` is the emitter origin.
    public let controlPoints: [WPEParticleControlPoint]
    public let attractors: [WPEParticleControlPointAttractor]

    /// True when the emitter's origin (control point `id 0`) tracks the cursor —
    /// the canonical "particles spawn at the pointer" / follow behavior.
    public var emitterTracksPointer: Bool {
        controlPoints.first(where: { $0.id == 0 })?.pointerLocked ?? false
    }

    public init(
        materialRelativePath: String?,
        childRelativePaths: [String] = [],
        childReferences: [WPEParticleChildReference]? = nil,
        rendersSprite: Bool = true,
        overrideAlphaAnimation: WPESceneAnimatedValue? = nil,
        isRope: Bool = false,
        trailRenderer: WPEParticleTrailRenderer? = nil,
        maxCount: Int,
        rate: Double,
        instantaneousCount: Int = 0,
        startDelay: Double,
        duration: Double? = nil,
        emitterFlagsRaw: Int? = nil,
        emitterAudioState: WPEParticleEmitterAudioState? = nil,
        lifetimeMin: Double,
        lifetimeMax: Double,
        sizeMin: Double,
        sizeMax: Double,
        sizeExponent: Double = 1,
        originOffset: SIMD3<Double>,
        emitterShape: WPEParticleEmitterShape = .sphere,
        dispersalMin: SIMD3<Double>,
        dispersalMax: SIMD3<Double>,
        velocityMin: SIMD3<Double>,
        velocityMax: SIMD3<Double>,
        colorMin: SIMD3<Double>,
        colorMax: SIMD3<Double>,
        fadeInSeconds: Double,
        directionMask: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        sign: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        emitterSpeedMin: Double = 0,
        emitterSpeedMax: Double = 0,
        alphaMin: Double = 1,
        alphaMax: Double = 1,
        rotationMin: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        rotationMax: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        angularVelocityMin: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        angularVelocityMax: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        fadeOutSeconds: Double = 0,
        alphaChange: WPEParticleAlphaChange? = nil,
        oscillateAlpha: WPEParticleOscillateAlpha? = nil,
        oscillateSize: WPEParticleOscillateSize? = nil,
        sizeChange: WPEParticleSizeChange? = nil,
        colorChange: WPEParticleColorChange? = nil,
        oscillatePosition: WPEParticleOscillatePosition? = nil,
        gravity: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        drag: Double = 0,
        angularForceZ: Double = 0,
        angularDrag: Double = 0,
        turbulentVelocityInit: WPEParticleTurbulentVelocityInit? = nil,
        turbulence: WPEParticleTurbulenceOperator? = nil,
        sequenceMultiplier: Double = 1,
        animationMode: WPEParticleAnimationMode = .sequence,
        controlPoints: [WPEParticleControlPoint] = [],
        attractors: [WPEParticleControlPointAttractor] = [],
        hasColorInitializer: Bool = false,
        declaresSequenceAnimation: Bool = false,
        isPerspective: Bool = false,
        sourceJSON: WPESceneJSONValue = .object([:])
    ) {
        self.sourceJSON = sourceJSON
        self.rawComponents = WPEParticleRawComponentBag(sourceJSON: sourceJSON)
        self.materialRelativePath = materialRelativePath
        self.childReferences = childReferences ?? childRelativePaths.map {
            WPEParticleChildReference(relativePath: $0)
        }
        self.rendersSprite = rendersSprite
        self.overrideAlphaAnimation = overrideAlphaAnimation
        self.isRope = isRope
        self.trailRenderer = trailRenderer
        self.maxCount = maxCount
        self.rate = rate
        self.instantaneousCount = max(0, instantaneousCount)
        self.startDelay = startDelay
        self.duration = duration.map { max(0, $0) }
        self.emitterFlagsRaw = emitterFlagsRaw
        self.emitterAudioState = emitterAudioState
        self.lifetimeMin = lifetimeMin
        self.lifetimeMax = lifetimeMax
        self.sizeMin = sizeMin
        self.sizeMax = sizeMax
        self.sizeExponent = max(0.0001, sizeExponent)
        self.originOffset = originOffset
        self.emitterShape = emitterShape
        self.dispersalMin = dispersalMin
        self.dispersalMax = dispersalMax
        self.directionMask = directionMask
        self.sign = sign
        self.emitterSpeedMin = min(emitterSpeedMin, emitterSpeedMax)
        self.emitterSpeedMax = max(emitterSpeedMin, emitterSpeedMax)
        self.velocityMin = velocityMin
        self.velocityMax = velocityMax
        self.colorMin = colorMin
        self.colorMax = colorMax
        self.hasColorInitializer = hasColorInitializer
        self.declaresSequenceAnimation = declaresSequenceAnimation
        self.isPerspective = isPerspective
        self.turbulentVelocityInit = turbulentVelocityInit
        self.turbulence = turbulence
        self.alphaMin = alphaMin
        self.alphaMax = alphaMax
        self.rotationMin = rotationMin
        self.rotationMax = rotationMax
        self.angularVelocityMin = angularVelocityMin
        self.angularVelocityMax = angularVelocityMax
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.alphaChange = alphaChange
        self.oscillateAlpha = oscillateAlpha
        self.oscillateSize = oscillateSize
        self.sizeChange = sizeChange
        self.colorChange = colorChange
        self.oscillatePosition = oscillatePosition
        self.gravity = gravity
        self.drag = drag
        self.angularForceZ = angularForceZ
        self.angularDrag = angularDrag
        self.sequenceMultiplier = max(0, sequenceMultiplier)
        self.animationMode = animationMode
        self.controlPoints = controlPoints
        self.attractors = attractors
    }

    /// `colorn` arrives ×255 (see `parseNormalizedParticleColor`); treat it as a
    /// 0…1 fraction multiplying the 0…255 base colour channel-wise.
    private static func multiplyingColor(
        _ base: SIMD3<Double>,
        byNormalizedOverride override: SIMD3<Double>?
    ) -> SIMD3<Double> {
        guard let override else { return base }
        return SIMD3<Double>(
            base.x * max(0, override.x) / 255,
            base.y * max(0, override.y) / 255,
            base.z * max(0, override.z) / 255
        )
    }

    public func applying(instanceOverride: WPESceneParticleInstanceOverride?) -> WPEParticleDefinition {
        guard let instanceOverride else { return self }

        let countScale = max(0, instanceOverride.count ?? 1)
        let rateScale = max(0, instanceOverride.rate ?? countScale)
        let lifetimeScale = max(0.0001, instanceOverride.lifetime ?? 1)
        let sizeScale = max(0, instanceOverride.size ?? 1)
        let speedScale = instanceOverride.speed ?? 1
        // Unlike material g_Overbright, the instance override is baked into each generated vertex COLOR.rgb.
        let brightnessScale = max(0, instanceOverride.brightness ?? 1)
        // Per-instance control points replace the definition's own. Points the override omits keep their authored offset.
        let overriddenControlPoints = instanceOverride.controlPointOffsets.isEmpty
            ? controlPoints
            : controlPoints.map { point in
                instanceOverride.controlPointOffsets[point.id].map {
                    WPEParticleControlPoint(
                        id: point.id,
                        offset: $0,
                        pointerLocked: point.pointerLocked,
                        flagsRaw: point.flagsRaw,
                        angles: point.angles
                    )
                } ?? point
            }
        // Keyframed or scripted override alpha must not be baked: `alpha` is only the static seed. Baking a scripted seed would square it.
        let alphaScale = instanceOverride.alphaAnimation != nil || instanceOverride.alphaScript != nil
            ? 1
            : max(0, instanceOverride.alpha ?? 1)
        let scaledMaxCount: Int
        if countScale == 0 || maxCount == 0 {
            scaledMaxCount = 0
        } else {
            scaledMaxCount = max(1, WPEValueParser.saturatingInt((Double(maxCount) * countScale).rounded()))
        }
        let scaledInstantaneous: Int
        if countScale == 0 || instantaneousCount == 0 {
            scaledInstantaneous = 0
        } else {
            scaledInstantaneous = max(1, WPEValueParser.saturatingInt((Double(instantaneousCount) * countScale).rounded()))
        }
        // `speed` override scales emission velocity — including the turbulence
        // seed/wind speeds (the reference renderer multiplies every velocity op).
        let scaledTurbulentVelocityInit = turbulentVelocityInit.map {
            WPEParticleTurbulentVelocityInit(
                speedMin: $0.speedMin * speedScale, speedMax: $0.speedMax * speedScale,
                scale: $0.scale, timescale: $0.timescale, offset: $0.offset,
                phaseMin: $0.phaseMin, phaseMax: $0.phaseMax,
                forward: $0.forward, right: $0.right
            )
        }
        let scaledTurbulence = turbulence.map {
            WPEParticleTurbulenceOperator(
                speedMin: $0.speedMin * speedScale, speedMax: $0.speedMax * speedScale,
                scale: $0.scale, timescale: $0.timescale,
                phaseMin: $0.phaseMin, phaseMax: $0.phaseMax, mask: $0.mask
            )
        }

        return WPEParticleDefinition(
            materialRelativePath: materialRelativePath,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            overrideAlphaAnimation: instanceOverride.alphaAnimation,
            isRope: isRope,
            trailRenderer: trailRenderer,
            maxCount: scaledMaxCount,
            rate: rate * rateScale,
            instantaneousCount: scaledInstantaneous,
            startDelay: startDelay,
            duration: duration,
            emitterFlagsRaw: emitterFlagsRaw,
            emitterAudioState: emitterAudioState,
            lifetimeMin: lifetimeMin * lifetimeScale,
            lifetimeMax: lifetimeMax * lifetimeScale,
            sizeMin: sizeMin * sizeScale,
            sizeMax: sizeMax * sizeScale,
            sizeExponent: sizeExponent,
            originOffset: originOffset,
            emitterShape: emitterShape,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin * speedScale,
            velocityMax: velocityMax * speedScale,
            // `colorn` is a per-instance colour multiplier, not a replacement.
            colorMin: Self.multiplyingColor(
                colorMin, byNormalizedOverride: instanceOverride.color) * brightnessScale,
            colorMax: Self.multiplyingColor(
                colorMax, byNormalizedOverride: instanceOverride.color) * brightnessScale,
            fadeInSeconds: fadeInSeconds,
            directionMask: directionMask,
            sign: sign,
            emitterSpeedMin: emitterSpeedMin * speedScale,
            emitterSpeedMax: emitterSpeedMax * speedScale,
            alphaMin: alphaMin * alphaScale,
            alphaMax: alphaMax * alphaScale,
            rotationMin: rotationMin,
            rotationMax: rotationMax,
            angularVelocityMin: angularVelocityMin * speedScale,
            angularVelocityMax: angularVelocityMax * speedScale,
            fadeOutSeconds: fadeOutSeconds,
            alphaChange: alphaChange,
            oscillateAlpha: oscillateAlpha,
            oscillateSize: oscillateSize,
            sizeChange: sizeChange,
            colorChange: colorChange,
            oscillatePosition: oscillatePosition,
            gravity: gravity * speedScale,
            drag: drag,
            angularForceZ: angularForceZ * speedScale,
            angularDrag: angularDrag,
            turbulentVelocityInit: scaledTurbulentVelocityInit,
            turbulence: scaledTurbulence,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: overriddenControlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer,
            declaresSequenceAnimation: declaresSequenceAnimation,
            isPerspective: isPerspective,
            sourceJSON: sourceJSON
        )
    }

    public func offsettingOrigin(by delta: SIMD3<Double>) -> WPEParticleDefinition {
        guard delta != SIMD3<Double>(0, 0, 0) else { return self }
        return WPEParticleDefinition(
            materialRelativePath: materialRelativePath,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            overrideAlphaAnimation: overrideAlphaAnimation,
            isRope: isRope,
            trailRenderer: trailRenderer,
            maxCount: maxCount,
            rate: rate,
            instantaneousCount: instantaneousCount,
            startDelay: startDelay,
            duration: duration,
            emitterFlagsRaw: emitterFlagsRaw,
            emitterAudioState: emitterAudioState,
            lifetimeMin: lifetimeMin,
            lifetimeMax: lifetimeMax,
            sizeMin: sizeMin,
            sizeMax: sizeMax,
            sizeExponent: sizeExponent,
            originOffset: originOffset + delta,
            emitterShape: emitterShape,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin,
            velocityMax: velocityMax,
            colorMin: colorMin,
            colorMax: colorMax,
            fadeInSeconds: fadeInSeconds,
            directionMask: directionMask,
            sign: sign,
            emitterSpeedMin: emitterSpeedMin,
            emitterSpeedMax: emitterSpeedMax,
            alphaMin: alphaMin,
            alphaMax: alphaMax,
            rotationMin: rotationMin,
            rotationMax: rotationMax,
            angularVelocityMin: angularVelocityMin,
            angularVelocityMax: angularVelocityMax,
            fadeOutSeconds: fadeOutSeconds,
            alphaChange: alphaChange,
            oscillateAlpha: oscillateAlpha,
            oscillateSize: oscillateSize,
            sizeChange: sizeChange,
            colorChange: colorChange,
            oscillatePosition: oscillatePosition,
            gravity: gravity,
            drag: drag,
            angularForceZ: angularForceZ,
            angularDrag: angularDrag,
            turbulentVelocityInit: turbulentVelocityInit,
            turbulence: turbulence,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer,
            declaresSequenceAnimation: declaresSequenceAnimation,
            isPerspective: isPerspective,
            sourceJSON: sourceJSON
        )
    }

    public static let empty = WPEParticleDefinition(
        materialRelativePath: nil,
        maxCount: 0,
        rate: 0,
        startDelay: 0,
        lifetimeMin: 1,
        lifetimeMax: 1,
        sizeMin: 4,
        sizeMax: 4,
        originOffset: SIMD3<Double>(0, 0, 0),
        dispersalMin: SIMD3<Double>(0, 0, 0),
        dispersalMax: SIMD3<Double>(0, 0, 0),
        velocityMin: SIMD3<Double>(0, 0, 0),
        velocityMax: SIMD3<Double>(0, 0, 0),
        colorMin: SIMD3<Double>(255, 255, 255),
        colorMax: SIMD3<Double>(255, 255, 255),
        fadeInSeconds: 0.1
    )
}

/// Missing keys fall back to defaults. `parse(data:)` returns nil only when the input is not a JSON object.
public enum WPEParticleDefinitionParser {
    public static func parse(data: Data) -> WPEParticleDefinition? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any] else {
            return nil
        }
        return parse(dictionary: json)
    }

    /// Diagnostics have no caller to return to, so they are logged rather than dropped — discarding them would be as silent as `default: break`.
    public static func parse(dictionary json: [String: Any]) -> WPEParticleDefinition {
        var diagnostics: [WPESceneDiagnostic] = []
        let definition = parse(dictionary: json, diagnostics: &diagnostics)
        for diagnostic in diagnostics {
            Logger.log(diagnostic.message, category: .wpeRender, level: diagnostic.severity.logLevel)
        }
        return definition
    }

    public static func parse(
        dictionary json: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPEParticleDefinition {
        let def = WPEParticleDefinition.empty
        let sourceJSON = WPESceneJSONValue(jsonValue: json) ?? .object([:])
        let rawComponents = WPEParticleRawComponentBag(sourceJSON: sourceJSON)

        let material = json["material"] as? String
        let childReferences = WPEValueParser.objectArray(json["children"])?
            .compactMap { child -> WPEParticleChildReference? in
                let path: String?
                if let name = child["name"] as? String, !name.isEmpty {
                    path = name
                } else if let particle = child["particle"] as? String, !particle.isEmpty {
                    path = particle
                } else {
                    path = nil
                }
                guard let path else { return nil }
                return WPEParticleChildReference(
                    id: intValue(child["id"]),
                    relativePath: path,
                    originOffset: WPEValueParser.vector3(child["origin"]) ?? SIMD3(0, 0, 0),
                    type: child["type"] as? String,
                    maxCount: WPEValueParser.int(child["maxcount"]),
                    angles: WPEValueParser.vector3(child["angles"]),
                    flagsRaw: WPEValueParser.int(child["flags"]),
                    controlPointStartIndex: WPEValueParser.int(child["controlpointstartindex"]),
                    probability: WPEValueParser.double(child["probability"]) ?? 1,
                    scale: WPEValueParser.vector3(child["scale"]) ?? SIMD3(1, 1, 1)
                )
            } ?? []
        // Absent `renderer` keeps legacy drawable behavior; an explicit empty
        // array marks a simulation-only spawner (renders nothing itself).
        let rendererEntries = WPEValueParser.objectArray(json["renderer"])
        let rendersSprite = rendererEntries.map { !$0.isEmpty } ?? true
        // `rope` is one ribbon through the whole particle chain. `ropetrail`/`spritetrail` are per-particle history; `ropetrail` must not take the rope path.
        let rendererNames = (rendererEntries ?? []).compactMap {
            ($0["name"] as? String)?.lowercased()
        }
        let isRope = rendererNames.contains("rope")
        let trailEntry = rendererEntries?.first {
            guard let n = ($0["name"] as? String)?.lowercased() else { return false }
            return n.hasSuffix("trail") && !isRope
        }
        // Engine defaults, not zero: absent `maxlength` means 10, not unbounded. `rope`-prefixed names are history-ribbon, not stretched.
        let parsedTrail: WPEParticleTrailRenderer? = trailEntry.map {
            let name = ($0["name"] as? String)?.lowercased() ?? ""
            return WPEParticleTrailRenderer(
                kind: name.hasPrefix("rope") ? .rope : .sprite,
                length: WPEValueParser.double($0["length"]) ?? 0.05,
                maxLength: WPEValueParser.double($0["maxlength"]) ?? 10.0,
                minLength: WPEValueParser.double($0["minlength"]),
                subdivision: WPEValueParser.double($0["subdivision"]) ?? 3.0
            )
        }
        let maxCount = WPEValueParser.int(json["maxcount"]) ?? 0
        let startDelay = WPEValueParser.double(json["starttime"]) ?? 0
        let sequenceMultiplier = WPEValueParser.double(json["sequencemultiplier"]) ?? 1
        let animationMode = WPEParticleAnimationMode(wpeString: json["animationmode"] as? String)
        let declaresSequenceAnimation =
            (json["animationmode"] as? String)?.lowercased() == "sequence"
            || WPEValueParser.double(json["sequencemultiplier"]) != nil
        // Top-level `flags` bit 4 = perspective (WPE's snowperspective etc.):
        // particles carry a Z depth and draw with a perspective divide.
        let particleFlags = WPEValueParser.int(json["flags"]) ?? 0
        let isPerspective = (particleFlags & 4) != 0

        let firstEmitter = WPEValueParser.objectArray(json["emitter"])?.first
        if rawComponents.emitters.count > 1 {
            diagnostics.append(.init(
                severity: .info,
                message: "Particle definition preserved \(rawComponents.emitters.count) emitters; typed runtime projection remains PARTIAL and consumes only the first emitter"
            ))
        }
        // `duration: 0` is the editor default and means unbounded, not emit-for-zero-seconds.
        let emitterDuration = firstEmitter
            .flatMap { WPEValueParser.double($0["duration"]) }
            .flatMap { $0 > 0 ? $0 : nil }
        let emitterFlagsRaw = firstEmitter.flatMap { WPEValueParser.int($0["flags"]) }
        if let emitterFlagsRaw {
            diagnostics.append(.init(
                severity: .info,
                message: "Particle emitter flags \(emitterFlagsRaw) were preserved without runtime interpretation"
            ))
        }
        let emitterAudioState = firstEmitter.flatMap(Self.parseEmitterAudioState)
        if let emitterAudioState {
            let unconsumed = emitterAudioState.rawFields.keys
                .filter { !Self.consumedEmitterAudioKeys.contains($0.lowercased()) }
                .sorted()
            if !unconsumed.isEmpty {
                diagnostics.append(.init(
                    severity: .info,
                    message: "Particle emitter audio fields [\(unconsumed.joined(separator: ", "))] were preserved without a runtime consumer"
                ))
            }
        }

        var rate: Double = 0
        var instantaneousCount: Int = 0
        var origin: SIMD3<Double> = SIMD3(0, 0, 0)
        var emitterShape: WPEParticleEmitterShape = .sphere
        var dispersalMin = SIMD3<Double>(0, 0, 0)
        var dispersalMax = SIMD3<Double>(0, 0, 0)
        // Do not default missing `directions` to Z=1: that collapses depth-only random offsets onto the same screen-space center.
        var directionMask: SIMD3<Double> = SIMD3(1, 1, 0)
        var sign: SIMD3<Double> = SIMD3(0, 0, 0)
        var emitterSpeedMin: Double = 0
        var emitterSpeedMax: Double = 0

        if let first = firstEmitter {
            // Absent emitter `rate` defaults to 5.0, not 0. Not the per-instance-override `rate` default of 1.0 (a multiplier).
            rate = WPEValueParser.double(first["rate"]) ?? 5
            instantaneousCount = WPEValueParser.double(first["instantaneous"])
                .map { max(0, WPEValueParser.saturatingInt($0)) } ?? 0
            origin = WPEValueParser.vector3(first["origin"]) ?? SIMD3(0, 0, 0)
            emitterSpeedMin = WPEValueParser.double(first["speedmin"]) ?? 0
            emitterSpeedMax = WPEValueParser.double(first["speedmax"]) ?? emitterSpeedMin
            let emitterName = (first["name"] as? String)?.lowercased()
            if emitterName == "boxrandom" {
                // `boxrandom` distances are per-axis interpolation endpoints; scalar parsing would collapse the box to a point.
                emitterShape = .box
                func absVec(_ v: SIMD3<Double>?) -> SIMD3<Double> {
                    guard let v else { return SIMD3(0, 0, 0) }
                    return SIMD3(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z))
                }
                dispersalMin = absVec(WPEValueParser.vector3(first["distancemin"]))
                dispersalMax = absVec(WPEValueParser.vector3(first["distancemax"]))
            } else if emitterName == nil || emitterName == "sphererandom" {
                let scalarMin = max(0, WPEValueParser.double(first["distancemin"]) ?? 0)
                let scalarMax = max(scalarMin, WPEValueParser.double(first["distancemax"]) ?? 0)
                dispersalMin = SIMD3(scalarMin, scalarMin, scalarMin)
                dispersalMax = SIMD3(scalarMax, scalarMax, scalarMax)
            } else {
                emitterShape = .unsupported
                diagnostics.append(.init(
                    severity: .info,
                    message: "Particle emitter '\(emitterName ?? "<invalid>")' is not supported by the particle simulator"
                ))
            }
            if let mask = WPEValueParser.vector3(first["directions"]) {
                directionMask = SIMD3<Double>(abs(mask.x), abs(mask.y), abs(mask.z))
            }
            if let raw = WPEValueParser.vector3(first["sign"]) {
                func normalized(_ v: Double) -> Double { v != 0 ? (v > 0 ? 1 : -1) : 0 }
                sign = SIMD3<Double>(normalized(raw.x), normalized(raw.y), normalized(raw.z))
            }
        }

        var lifetimeMin: Double = def.lifetimeMin
        var lifetimeMax: Double = def.lifetimeMax
        var sizeMin: Double = def.sizeMin
        var sizeMax: Double = def.sizeMax
        var sizeExponent: Double = def.sizeExponent
        var velocityMin = def.velocityMin
        var velocityMax = def.velocityMax
        var colorMin = def.colorMin
        var colorMax = def.colorMax
        var hasColorInitializer = false
        var turbulentVelocityInit: WPEParticleTurbulentVelocityInit?
        var turbulence: WPEParticleTurbulenceOperator?
        var alphaMin: Double = def.alphaMin
        var alphaMax: Double = def.alphaMax
        var rotationMin: SIMD3<Double> = def.rotationMin
        var rotationMax: SIMD3<Double> = def.rotationMax
        var angularVelocityMin: SIMD3<Double> = def.angularVelocityMin
        var angularVelocityMax: SIMD3<Double> = def.angularVelocityMax

        if let initializers = WPEValueParser.objectArray(json["initializer"]) {
            for entry in initializers {
                guard let name = (entry["name"] as? String)?.lowercased() else { continue }
                switch name {
                case "lifetimerandom":
                    lifetimeMin = WPEValueParser.double(entry["min"]) ?? lifetimeMin
                    lifetimeMax = WPEValueParser.double(entry["max"]) ?? lifetimeMax
                case "lifetime":
                    if let v = WPEValueParser.double(entry["value"]) {
                        lifetimeMin = v; lifetimeMax = v
                    }
                case "sizerandom":
                    sizeMin = WPEValueParser.double(entry["min"]) ?? sizeMin
                    sizeMax = WPEValueParser.double(entry["max"]) ?? sizeMax
                    sizeExponent = WPEValueParser.double(entry["exponent"]) ?? sizeExponent
                case "size":
                    if let v = WPEValueParser.double(entry["value"]) {
                        sizeMin = v; sizeMax = v
                    }
                case "velocityrandom":
                    // Absent `min`/`max` keeps the reference default x,y ∈ [-32,32], z=0 — not zero.
                    velocityMin = WPEValueParser.vector3(entry["min"]) ?? SIMD3(-32, -32, 0)
                    velocityMax = WPEValueParser.vector3(entry["max"]) ?? SIMD3(32, 32, 0)
                case "velocity":
                    if let v = WPEValueParser.vector3(entry["value"]) {
                        velocityMin = v; velocityMax = v
                    }
                case "colorrandom":
                    colorMin = WPEValueParser.vector3(entry["min"]) ?? colorMin
                    colorMax = WPEValueParser.vector3(entry["max"]) ?? colorMax
                    hasColorInitializer = true
                case "color":
                    if let v = WPEValueParser.vector3(entry["value"]) {
                        colorMin = v; colorMax = v
                    }
                    hasColorInitializer = true
                case "alpharandom":
                    alphaMin = WPEValueParser.double(entry["min"]) ?? 0.05
                    alphaMax = WPEValueParser.double(entry["max"]) ?? 1
                case "alpha":
                    if let v = WPEValueParser.double(entry["value"]) {
                        alphaMin = v; alphaMax = v
                    }
                case "rotationrandom":
                    // Default max is (0,0,2π) — only z spins.
                    rotationMin = WPEValueParser.vector3(entry["min"]) ?? SIMD3(0, 0, 0)
                    rotationMax = WPEValueParser.vector3(entry["max"]) ?? SIMD3(0, 0, 2 * .pi)
                case "angularvelocityrandom":
                    // Absent `min`/`max` keeps z ∈ [-5,5] (x/y=0), not zero.
                    angularVelocityMin = WPEValueParser.vector3(entry["min"]) ?? SIMD3(0, 0, -5)
                    angularVelocityMax = WPEValueParser.vector3(entry["max"]) ?? SIMD3(0, 0, 5)
                case "turbulentvelocityrandom":
                    // Absent fields take engine defaults (speed 100…250, scale 1, timescale 1, phase 0…0.1, forward +Y, right +Z), not zero.
                    let d = WPEParticleTurbulentVelocityInit()
                    turbulentVelocityInit = WPEParticleTurbulentVelocityInit(
                        speedMin: WPEValueParser.double(entry["speedmin"]) ?? d.speedMin,
                        speedMax: WPEValueParser.double(entry["speedmax"]) ?? d.speedMax,
                        scale: WPEValueParser.double(entry["scale"]) ?? d.scale,
                        timescale: WPEValueParser.double(entry["timescale"]) ?? d.timescale,
                        offset: WPEValueParser.double(entry["offset"]) ?? d.offset,
                        phaseMin: WPEValueParser.double(entry["phasemin"]) ?? d.phaseMin,
                        phaseMax: WPEValueParser.double(entry["phasemax"]) ?? d.phaseMax,
                        forward: WPEValueParser.vector3(entry["forward"]) ?? d.forward,
                        right: WPEValueParser.vector3(entry["right"]) ?? d.right
                    )
                default:
                    diagnostics.append(.init(
                        severity: .info,
                        message: "Particle initializer '\(name)' is not supported by the particle simulator"
                    ))
                }
            }
        }

        // `flags & 1` locks to pointer; pointer-locked id-0 makes the emitter spawn at the cursor.
        var controlPoints: [WPEParticleControlPoint] = []
        if let cps = WPEValueParser.objectArray(json["controlpoint"]) {
            for cp in cps {
                guard let id = (cp["id"] as? Int) ?? (cp["id"] as? Double).map({ WPEValueParser.saturatingInt($0) }) else { continue }
                let offset = WPEValueParser.vector3(cp["offset"]) ?? SIMD3(0, 0, 0)
                let flagsRaw = WPEValueParser.int(cp["flags"])
                controlPoints.append(WPEParticleControlPoint(
                    id: id,
                    offset: offset,
                    pointerLocked: flagsRaw.map { ($0 & 1) != 0 } ?? false,
                    flagsRaw: flagsRaw,
                    angles: WPEValueParser.vector3(cp["angles"])
                ))
            }
        }

        var fadeInSeconds: Double = 0.1
        var fadeOutSeconds: Double = 0
        var alphaChange: WPEParticleAlphaChange?
        var oscillateAlpha: WPEParticleOscillateAlpha?
        var oscillateSize: WPEParticleOscillateSize?
        var sizeChange: WPEParticleSizeChange?
        var colorChange: WPEParticleColorChange?
        var oscillatePosition: WPEParticleOscillatePosition?
        var gravity: SIMD3<Double> = SIMD3(0, 0, 0)
        var drag: Double = 0
        var angularForceZ: Double = 0
        var angularDrag: Double = 0
        var attractors: [WPEParticleControlPointAttractor] = []
        if let operators = WPEValueParser.objectArray(json["operator"]) {
            for entry in operators {
                guard let name = (entry["name"] as? String)?.lowercased() else { continue }
                switch name {
                case "controlpointattract":
                    let cpID = (entry["controlpoint"] as? Int)
                        ?? (entry["controlpoint"] as? Double).map { WPEValueParser.saturatingInt($0) } ?? 0
                    let scale = WPEValueParser.double(entry["scale"]) ?? 0
                    let threshold = WPEValueParser.double(entry["threshold"]) ?? 0
                    if scale != 0, threshold > 0 {
                        attractors.append(WPEParticleControlPointAttractor(
                            controlPointID: cpID, scale: scale, threshold: threshold
                        ))
                    }
                case "alphafade":
                    // A bare `{"name":"alphafade"}` must fade out; absent `fadeouttime` uses 0.3 (low end of reference scenes, not a verified engine default).
                    fadeInSeconds = WPEValueParser.double(entry["fadeintime"]) ?? 0.1
                    fadeOutSeconds = WPEValueParser.double(entry["fadeouttime"]) ?? 0.3
                case "alphachange":
                    alphaChange = WPEParticleAlphaChange(
                        startTime: WPEValueParser.double(entry["starttime"]) ?? 0,
                        endTime: WPEValueParser.double(entry["endtime"]) ?? 1,
                        startValue: WPEValueParser.double(entry["startvalue"]) ?? 1,
                        endValue: WPEValueParser.double(entry["endvalue"]) ?? 1
                    )
                case "oscillatealpha":
                    // Absent bound takes the FrequencyValue default (freq 0…10, scale 0…1, phase 0…2π), NOT the other bound.
                    let freqMin = WPEValueParser.double(entry["frequencymin"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 0
                    var freqMax = WPEValueParser.double(entry["frequencymax"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 10
                    // Reference: `if (frequencymax == 0) frequencymax = frequencymin`.
                    if freqMax == 0 { freqMax = freqMin }
                    let scaleMin = WPEValueParser.double(entry["scalemin"])
                        ?? WPEValueParser.double(entry["scale"]) ?? 0
                    let scaleMax = WPEValueParser.double(entry["scalemax"]) ?? 1
                    let phaseMin = WPEValueParser.double(entry["phasemin"])
                        ?? WPEValueParser.double(entry["phase"]) ?? 0
                    let phaseMax = WPEValueParser.double(entry["phasemax"]) ?? 2 * .pi
                    oscillateAlpha = WPEParticleOscillateAlpha(
                        frequencyMin: freqMin,
                        frequencyMax: freqMax,
                        scaleMin: scaleMin,
                        scaleMax: scaleMax,
                        phaseMin: phaseMin,
                        phaseMax: phaseMax
                    )
                case "oscillatesize":
                    // `oscillatesize` scale defaults 0.8…1.2, not FrequencyValue's 0…1.
                    let freqMin = WPEValueParser.double(entry["frequencymin"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 0
                    var freqMax = WPEValueParser.double(entry["frequencymax"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 10
                    if freqMax == 0 { freqMax = freqMin }
                    let scaleMin = WPEValueParser.double(entry["scalemin"])
                        ?? WPEValueParser.double(entry["scale"]) ?? 0.8
                    let scaleMax = WPEValueParser.double(entry["scalemax"]) ?? 1.2
                    let phaseMin = WPEValueParser.double(entry["phasemin"])
                        ?? WPEValueParser.double(entry["phase"]) ?? 0
                    let phaseMax = WPEValueParser.double(entry["phasemax"]) ?? 2 * .pi
                    oscillateSize = WPEParticleOscillateSize(
                        frequencyMin: freqMin,
                        frequencyMax: freqMax,
                        scaleMin: scaleMin,
                        scaleMax: scaleMax,
                        phaseMin: phaseMin,
                        phaseMax: phaseMax
                    )
                case "sizechange":
                    sizeChange = WPEParticleSizeChange(
                        startTime: WPEValueParser.double(entry["starttime"]) ?? 0,
                        endTime: WPEValueParser.double(entry["endtime"]) ?? 1,
                        startValue: WPEValueParser.double(entry["startvalue"]) ?? 1,
                        endValue: WPEValueParser.double(entry["endvalue"]) ?? 1
                    )
                case "colorchange":
                    // 0…1 RGB multipliers (unlike `colorrandom`, which is 0…255).
                    let identity = SIMD3<Double>(1, 1, 1)
                    let start = WPEValueParser.vector3(entry["startvalue"]) ?? identity
                    let end = WPEValueParser.vector3(entry["endvalue"]) ?? identity
                    colorChange = WPEParticleColorChange(
                        startTime: WPEValueParser.double(entry["starttime"]) ?? 0,
                        endTime: WPEValueParser.double(entry["endtime"]) ?? 1,
                        startColor: start,
                        endColor: end
                    )
                case "oscillateposition":
                    let freqMin = WPEValueParser.double(entry["frequencymin"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 0
                    let freqMax = WPEValueParser.double(entry["frequencymax"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 5
                    let scaleMin = WPEValueParser.double(entry["scalemin"])
                        ?? WPEValueParser.double(entry["scale"]) ?? 0
                    let scaleMax = WPEValueParser.double(entry["scalemax"])
                        ?? WPEValueParser.double(entry["scale"]) ?? scaleMin
                    let phaseMin = WPEValueParser.double(entry["phasemin"])
                        ?? WPEValueParser.double(entry["phase"]) ?? 0
                    let phaseMax = WPEValueParser.double(entry["phasemax"])
                        ?? WPEValueParser.double(entry["phase"]) ?? phaseMin
                    let mask = WPEValueParser.vector3(entry["mask"]) ?? SIMD3<Double>(1, 1, 1)
                    if scaleMax > 0, freqMax > 0 {
                        oscillatePosition = WPEParticleOscillatePosition(
                            frequencyMin: freqMin, frequencyMax: freqMax,
                            scaleMin: scaleMin, scaleMax: scaleMax,
                            phaseMin: phaseMin, phaseMax: phaseMax,
                            mask: mask
                        )
                    }
                case "movement":
                    gravity = WPEValueParser.vector3(entry["gravity"]) ?? gravity
                    drag = WPEValueParser.double(entry["drag"]) ?? drag
                case "angularmovement":
                    if let force = WPEValueParser.vector3(entry["force"]) {
                        angularForceZ = force.z
                    }
                    angularDrag = WPEValueParser.double(entry["drag"]) ?? angularDrag
                case "turbulence":
                    // Engine defaults 500…1000 / scale 0.01 / timescale 20 / mask "1 1 0".
                    let d = WPEParticleTurbulenceOperator()
                    turbulence = WPEParticleTurbulenceOperator(
                        speedMin: WPEValueParser.double(entry["speedmin"]) ?? d.speedMin,
                        speedMax: WPEValueParser.double(entry["speedmax"]) ?? d.speedMax,
                        scale: WPEValueParser.double(entry["scale"]) ?? d.scale,
                        timescale: WPEValueParser.double(entry["timescale"]) ?? d.timescale,
                        phaseMin: WPEValueParser.double(entry["phasemin"]) ?? d.phaseMin,
                        phaseMax: WPEValueParser.double(entry["phasemax"]) ?? d.phaseMax,
                        mask: WPEValueParser.vector3(entry["mask"]) ?? d.mask
                    )
                default:
                    diagnostics.append(.init(
                        severity: .info,
                        message: "Particle operator '\(name)' is not supported by the particle simulator"
                    ))
                }
            }
        }

        return WPEParticleDefinition(
            materialRelativePath: material,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            isRope: isRope,
            trailRenderer: parsedTrail,
            maxCount: max(0, maxCount),
            rate: max(0, rate),
            instantaneousCount: instantaneousCount,
            startDelay: max(0, startDelay),
            duration: emitterDuration,
            emitterFlagsRaw: emitterFlagsRaw,
            emitterAudioState: emitterAudioState,
            lifetimeMin: max(0.0001, lifetimeMin),
            lifetimeMax: max(lifetimeMin, lifetimeMax),
            sizeMin: max(0, sizeMin),
            sizeMax: max(sizeMin, sizeMax),
            sizeExponent: sizeExponent,
            originOffset: origin,
            emitterShape: emitterShape,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin,
            velocityMax: velocityMax,
            colorMin: colorMin,
            colorMax: colorMax,
            fadeInSeconds: max(0, fadeInSeconds),
            directionMask: directionMask,
            sign: sign,
            emitterSpeedMin: emitterSpeedMin,
            emitterSpeedMax: emitterSpeedMax,
            alphaMin: max(0, min(alphaMin, alphaMax)),
            alphaMax: max(alphaMin, alphaMax),
            rotationMin: rotationMin,
            rotationMax: rotationMax,
            angularVelocityMin: angularVelocityMin,
            angularVelocityMax: angularVelocityMax,
            fadeOutSeconds: max(0, fadeOutSeconds),
            alphaChange: alphaChange,
            oscillateAlpha: oscillateAlpha,
            oscillateSize: oscillateSize,
            sizeChange: sizeChange,
            colorChange: colorChange,
            oscillatePosition: oscillatePosition,
            gravity: gravity,
            drag: max(0, drag),
            angularForceZ: angularForceZ,
            angularDrag: max(0, angularDrag),
            turbulentVelocityInit: turbulentVelocityInit,
            turbulence: turbulence,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer,
            declaresSequenceAnimation: declaresSequenceAnimation,
            isPerspective: isPerspective,
            sourceJSON: sourceJSON
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return WPEValueParser.saturatingInt(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }

    /// Both key families feeding `emissionScale`; anything else in `rawFields`
    /// is preserved but unconsumed and gets the parse diagnostic.
    private static let consumedEmitterAudioKeys: Set<String> = [
        "audioprocessingmode",
        "audioprocessingfrequencystart", "audioprocessingfrequencyend", "audiofrequency",
        "audioprocessingbounds", "audiobounds",
        "audioprocessingexponent", "audioexponent",
        "audioamount"
    ]

    private static func parseEmitterAudioState(
        _ emitter: [String: Any]
    ) -> WPEParticleEmitterAudioState? {
        var rawFields: [String: WPEParticleRawJSONValue] = [:]
        for (key, value) in emitter where key.lowercased().hasPrefix("audio") {
            if let preserved = WPEParticleRawJSONValue(value) {
                rawFields[key] = preserved
            }
        }
        guard !rawFields.isEmpty else { return nil }

        let referenceFrequency = WPEValueParser.numberVector(emitter["audiofrequency"])
        return WPEParticleEmitterAudioState(
            mode: WPEValueParser.int(emitter["audioprocessingmode"]),
            frequencyStart: WPEValueParser.double(emitter["audioprocessingfrequencystart"])
                ?? referenceFrequency?.first,
            frequencyEnd: WPEValueParser.double(emitter["audioprocessingfrequencyend"])
                ?? referenceFrequency?.dropFirst().first,
            bounds: WPEValueParser.numberVector(emitter["audioprocessingbounds"])
                ?? WPEValueParser.numberVector(emitter["audiobounds"]),
            exponent: WPEValueParser.double(emitter["audioprocessingexponent"])
                ?? WPEValueParser.double(emitter["audioexponent"]),
            amount: WPEValueParser.double(emitter["audioamount"]),
            rawFields: rawFields
        )
    }
}
