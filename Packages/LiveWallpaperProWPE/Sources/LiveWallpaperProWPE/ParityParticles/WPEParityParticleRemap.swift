import Foundation
import simd

/// remapvalue (operator 19, 1401bfbb0.c, 1401c5490.c:9259-9344, 4439-4826) and remapinitialvalue
/// (initializer 15, 1401c5490.c:7216-7265, 1690-2030). Enum values follow WPE's string tables at 0x140484e00-f38;
/// a string WPE does not know maps past the last case and does nothing.
struct WPEParityParticleRemap: Equatable, Sendable {
    enum Value: Int, Sendable {
        case lifetimeFraction, maxLifetime, size, opacity, speed, rotation, angularSpeed, distanceToControlPoint
        case positionBetweenControlPoints, runtime, timeOfDay, particleSystemTime, layerTime, color, position
        case velocity, controlPoint, deltaToControlPoint, directionToControlPoint, layerOrigin, unknown

        static let names = [
            "lifetimefraction", "maxlifetime", "size", "opacity", "speed", "rotation", "angularspeed",
            "distancetocontrolpoint", "positionbetweentwocontrolpoints", "runtime", "timeofday", "particlesystemtime",
            "layertime", "color", "position", "velocity", "controlpoint", "deltatocontrolpoint",
            "directiontocontrolpoint", "layerorigin",
        ]

        /// FUN_140229370: the entries after layertime carry three components.
        var isVector: Bool {
            rawValue > Value.layerTime.rawValue && self != .unknown
        }
    }

    enum Component: Int, Sendable {
        case all, x, y, z, sum, average, max, min, unknown
        static let names = ["all", "x", "y", "z", "sum", "average", "max", "min"]
    }

    enum Transform: Int, Sendable {
        case none, sine, square, saw, triangle, simplexNoise, fbmNoise, unknown
        static let names = ["none", "sine", "square", "saw", "triangle", "simplexnoise", "fbmnoise"]
    }

    enum Operation: Int, Sendable {
        case remap, multiply, add, subtract, unknown
        static let names = ["remap", "multiply", "add", "subtract"]

        func apply(_ current: Float, _ value: Float) -> Float {
            switch self {
            case .remap: value
            case .multiply: value * current
            case .add: value + current
            case .subtract: current - value
            case .unknown: current
            }
        }
    }

    var operation: Operation
    var input: Value
    var output: Value
    var inputComponent: Component
    var outputComponent: Component
    var transform: Transform
    var octaves: Int
    /// bit 0 clamps the normalised input, bit 1 the mapped output, both to [0, 1].
    var flags: Int
    var inputMin: SIMD3<Float>
    /// max − min, a zero component replaced by 2⁻²³.
    var inputRange: SIMD3<Float>
    var outputMin: SIMD3<Float>
    var outputRange: SIMD3<Float>
    var inputControlPoint: Int
    var outputControlPoint0: Int
    var outputControlPoint1: Int
    var inputScale: Float

    /// The operator defaults its input to lifetimefraction, the initializer to maxlifetime (1401bc4b0.c).
    init(_ entry: WPEParityParticleEntry, defaultInput: Value) {
        func pick<T>(_ key: String, _ names: [String], _ fallback: T, _ make: (Int) -> T?, unknown: T) -> T {
            guard let text = WPEParityParticleJSON.string(entry.json[key]) else { return fallback }
            return names.firstIndex(of: text).flatMap(make) ?? unknown
        }
        operation = pick("operation", Operation.names, .multiply, Operation.init(rawValue:), unknown: .unknown)
        input = pick("input", Value.names, defaultInput, Value.init(rawValue:), unknown: .unknown)
        output = pick("output", Value.names, .size, Value.init(rawValue:), unknown: .unknown)
        inputComponent = pick("inputcomponent", Component.names, .all, Component.init(rawValue:), unknown: .unknown)
        outputComponent = pick("outputcomponent", Component.names, .all, Component.init(rawValue:), unknown: .unknown)
        transform = pick("transformfunction", Transform.names, .none, Transform.init(rawValue:), unknown: .unknown)
        octaves = max(entry.integer("transformoctaves", 3), 0)
        flags = entry.integer("flags", 0)
        inputMin = entry.vector("inputrangemin", .zero)
        var range = entry.vector("inputrangemax", SIMD3(repeating: 1)) - inputMin
        for axis in 0 ..< 3 where range[axis] == 0 {
            range[axis] = Float(bitPattern: 0x3400_0000)
        }
        inputRange = range
        outputMin = entry.vector("outputrangemin", .zero)
        outputRange = entry.vector("outputrangemax", SIMD3(repeating: 1)) - outputMin
        inputControlPoint = entry.controlPoint("inputcontrolpoint0")
        outputControlPoint0 = entry.controlPoint("outputcontrolpoint0")
        outputControlPoint1 = entry.controlPoint("outputcontrolpoint1", 1)
        inputScale = entry.number("transforminputscale", 2)
    }

    /// FUN_1400fb740 with the noise object's gain 0.5: 1 / (1 + 0.5 + 0.25 + …) over `octaves` terms.
    var fractalBounding: Float {
        var amplitude: Float = 0.5, total: Float = 1
        for _ in 1 ..< max(octaves, 1) {
            total += amplitude
            amplitude *= 0.5
        }
        return 1 / total
    }
}

/// inheritvaluefromevent (operator 20) and inheritinitialvaluefromevent (initializer 16): the enum at 0x140484d90.
enum WPEParityParticleInherit: Int, Equatable, Sendable {
    case setColor, multiplyColor, setOpacity, multiplyOpacity, setColorOpacity, multiplyColorOpacity
    case setVelocity, addVelocity, setSize, multiplySize, setRotation, addRotation
    case setAngularVelocity, addAngularVelocity, unknown

    static let names = [
        "setcolor", "multiplycolor", "setopacity", "multiplyopacity", "setcoloropacity", "multiplycoloropacity",
        "setvelocity", "addvelocity", "setsize", "multiplysize", "setrotation", "addrotation", "setangularvelocity",
        "addangularvelocity",
    ]

    /// The operator defaults to setcoloropacity (1401c0080.c), the initializer to setcolor (1401bc980.c).
    init(_ entry: WPEParityParticleEntry, fallback: Self) {
        guard let text = WPEParityParticleJSON.string(entry.json["input"]) else {
            self = fallback
            return
        }
        self = Self.names.firstIndex(of: text).flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

/// The parent particle an event child was spawned from, as the child reads it when it steps.
struct WPEParityParticleParentSample {
    var alive: Bool
    var color: SIMD3<Float>
    var alpha: Float
    var velocity: SIMD3<Float>
    var size: Float
    var rotation: SIMD3<Float>
    var angularVelocity: SIMD3<Float>
}

/// Float paths of the remap transforms, in WPE's operation order.
enum WPEParityParticleRemapMath {
    static let pi = Float(bitPattern: 0x4049_0FDB)
    static let halfPi = Float(bitPattern: 0x3FC9_0FDB)
    static let third = Float(bitPattern: 0x3EAA_AAAB)

    /// cvttss2si / cvtps2dq: out of range and NaN give 0x80000000.
    static func sseInt(_ value: Float) -> Int32 {
        abs(value) < 2_147_483_648 ? Int32(value) : Int32.min
    }

    /// minps(v, 1) then maxps(0, ·): NaN becomes 1.
    static func clampSSE(_ value: Float) -> Float {
        let low = value < 1 ? value : 1
        return low < 0 ? 0 : low
    }

    /// FUN_1401d8360: NaN becomes 0.
    static func clampScalar(_ value: Float) -> Float {
        let high = value >= 0 ? value : 0
        return high <= 1 ? high : 1
    }

    /// The Cephes sin_ps polynomial the operator inlines (constants at 0x140483660-0x140483710).
    static func sinPS(_ input: Float) -> Float {
        var x = Float(bitPattern: input.bitPattern & 0x7FFF_FFFF)
        var sign = input.bitPattern & 0x8000_0000
        var quadrant = sseInt(x * Float(bitPattern: 0x3FA2_F983)) &+ 1
        quadrant &= ~1
        let y = Float(quadrant)
        sign ^= UInt32(bitPattern: (quadrant & 4) << 29)
        x = ((y * -0.785_156_25 + x) + y * Float(bitPattern: 0xB97D_A000)) + y * Float(bitPattern: 0xB322_2169)
        let z = x * x
        var cosine = ((Float(bitPattern: 0x37CC_F5CE) * z + Float(bitPattern: 0xBAB6_061A)) * z
            + Float(bitPattern: 0x3D2A_AAA5)) * z * z
        cosine = cosine - z * 0.5 + 1
        let sine = ((Float(bitPattern: 0xB94C_A1F9) * z + Float(bitPattern: 0x3C08_839E)) * z
            + Float(bitPattern: 0xBE2A_AAA3)) * z * x + x
        let result = quadrant & 2 == 0 ? sine : cosine
        return Float(bitPattern: result.bitPattern ^ sign)
    }

    /// The SSE4 FastNoise 2D simplex at noise vtable 0x140488440 slot 1 (full.s 269051-269257).
    static func simplex2(seed: Int32, _ x: Float, _ y: Float) -> Float {
        let primeX: Int32 = 0x1DDE_90C9, primeY: Int32 = 0x43C4_2E4D
        let g2 = Float(bitPattern: 0x3E58_658C), corner2 = Float(bitPattern: 0xBF13_CD3A)
        let root = Float(bitPattern: 0x401A_827A)
        let f = (x + y) * Float(bitPattern: 0x3EBB_67AE)
        let fy = (f + y).rounded(.down), fx = (f + x).rounded(.down)
        let t = g2 * (fy + fx)
        let i = sseInt(fx) &* primeX, j = sseInt(fy) &* primeY
        let y0 = y - (fy - t), x0 = x - (fx - t)
        let xMajor = y0 < x0
        let x1 = (x0 - (xMajor ? 1 : 0)) + g2, y1 = (y0 - (xMajor ? 0 : 1)) + g2
        let y2 = y0 + corner2, x2 = x0 + corner2
        func falloff(_ a: Float, _ b: Float) -> Float {
            let r = -(a * a) + (-(b * b) + 0.5)
            let clamped = r > 0 ? r : 0
            let square = clamped * clamped
            return square * square
        }
        func gradient(_ hashed: Int32, _ a: Float, _ b: Float) -> Float {
            var h = (hashed ^ seed) &* 0x27D4_EB2D
            h ^= h >> 15
            let fa = Float(bitPattern: a.bitPattern ^ UInt32(bitPattern: h << 31))
            let fb = Float(bitPattern: b.bitPattern ^ UInt32(bitPattern: (h >> 1) << 31))
            return h & 4 != 0 ? fb * root + fa : fa * root + fb
        }
        let n0 = gradient(i ^ j, x0, y0) * falloff(x0, y0)
        let n1 = gradient((i &+ (xMajor ? primeX : 0)) ^ (j &+ (xMajor ? 0 : primeY)), x1, y1) * falloff(x1, y1)
        let n2 = gradient((i &+ primeX) ^ (j &+ primeY), x2, y2) * falloff(x2, y2)
        return (n0 + (n1 + n2)) * Float(bitPattern: 0x4219_227F)
    }

    /// FUN_1400fbc70 with gain 0.5, weighted strength 0, lacunarity 2; the seed rises by one per octave.
    static func fbm2(seed: Int32, octaves: Int, bounding: Float, _ x: Float, _ y: Float) -> Float {
        let weightedStrength: Float = 0
        var noise = simplex2(seed: seed, x, y)
        var amplitude = bounding, sum = noise * bounding
        var octaveSeed = seed, px = x, py = y
        var octave = 1
        while octave < octaves {
            px *= 2
            py *= 2
            octaveSeed &+= 1
            amplitude = amplitude * (((1 + noise) * 0.5 - 1) * weightedStrength + 1) * 0.5
            noise = simplex2(seed: octaveSeed, px, py)
            sum += noise * amplitude
            octave += 1
        }
        return sum
    }

    /// FUN_14027b090: 1D noise, gradient·t before the (1 − t²)⁴ falloff.
    static func simplex1(_ x: Float) -> Float {
        let truncated = sseInt(x)
        let cell = Float(truncated) > x ? truncated &- 1 : truncated
        let t0 = x - Float(cell)
        func corner(_ index: Int32, _ t: Float) -> Float {
            let hashed = WPEParityParticleNoise.permutationValue(Int(index & 255))
            var gradient = Float(hashed & 7) + 1
            if hashed & 8 != 0 {
                gradient = -gradient
            }
            let a = 1 - t * t
            return gradient * t * ((a * a) * (a * a))
        }
        return (corner(cell &+ 1, t0 - 1) + corner(cell, t0)) * 0.395
    }

    /// FUN_14027b4b0 over FUN_14005f580(scale, 1, 2, 0.5): Σ amplitude·noise / Σ amplitude.
    static func fbm1(_ x: Float, octaves: Int, scale: Float) -> Float {
        var sum: Float = 0, total: Float = 0, amplitude: Float = 1, frequency = scale
        for _ in 0 ..< octaves {
            let noise = simplex1(frequency * x)
            total += amplitude
            frequency *= 2
            sum += noise * amplitude
            amplitude *= 0.5
        }
        return sum / total
    }

    /// Per-axis seeds of the operator's noise transforms (full.s 601726, 601733).
    static func seeds(_ u: Float) -> SIMD3<Int32> {
        let bits = Int32(bitPattern: u.bitPattern)
        return SIMD3(bits, bits ^ 0x0B39_24AD, bits ^ 0x493A_8E83)
    }
}

extension WPEParityParticleSystem {
    private func remapInput(_ remap: WPEParityParticleRemap, slot: Int, initializer: Bool) -> SIMD3<Float> {
        let p = position[slot]
        func splat(_ value: Float) -> SIMD3<Float> {
            SIMD3(repeating: value)
        }
        func lengthOf(_ v: SIMD3<Float>) -> Float {
            (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        }
        switch remap.input {
        case .lifetimeFraction:
            // The initializer reads the sprite phase array (inst[0x4d]) here (full.s 594458).
            return splat(initializer ? frame[slot] : age[slot] / lifetime[slot])
        case .maxLifetime: return splat(lifetime[slot])
        case .size: return splat(initializer ? initialSize[slot] : size[slot])
        case .opacity: return splat(initializer ? initialAlpha[slot] : alpha[slot])
        case .speed: return splat(lengthOf(velocity[slot]))
        case .rotation: return splat(rotation[slot].z)
        case .angularSpeed: return splat(angularVelocity[slot].z)
        case .distanceToControlPoint:
            return splat(lengthOf(p - controlPointTranslation(remap.inputControlPoint)))
        case .positionBetweenControlPoints:
            let a = controlPointTranslation(remap.outputControlPoint0)
            let line = controlPointTranslation(remap.outputControlPoint1) - a
            let along = p - a
            if initializer {
                let length = lengthOf(line)
                guard length > Float(bitPattern: 0x3400_0000) else { return .zero }
                let direction = line / length
                return splat((along.x * direction.x + along.y * direction.y + along.z * direction.z) / length)
            }
            let lengthSquared = line.y * line.y + line.x * line.x + line.z * line.z
            let dot = along.y * line.y + along.x * line.x + along.z * line.z
            return splat(lengthSquared > 0 ? dot / lengthSquared : 0)
        case .runtime: return splat(frameContext.time)
        case .timeOfDay: return splat(frameContext.timeOfDay)
        case .particleSystemTime: return splat(initializer ? simulationTime : frameContext.time)
        case .layerTime: return splat(objectTime)
        case .color: return initializer ? initialColor[slot] : color[slot]
        case .position: return p
        case .velocity: return velocity[slot]
        case .controlPoint, .deltaToControlPoint, .directionToControlPoint:
            // The initializer assigns the value into the point instead of reading it (full.s 594665-594776).
            let center = initializer ? SIMD3<Float>.zero : controlPointTranslation(remap.inputControlPoint)
            if remap.input == .controlPoint {
                return center
            }
            let delta = center - p
            if remap.input == .deltaToControlPoint {
                return delta
            }
            let lengthSquared = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
            return lengthSquared > 0 ? delta / lengthSquared.squareRoot() : .zero
        case .layerOrigin:
            return frameContext.layerOrigin
        case .unknown: return .zero
        }
    }

    private static func reduce(_ value: SIMD3<Float>, _ component: WPEParityParticleRemap.Component,
                               initializer: Bool) -> SIMD3<Float> {
        typealias Math = WPEParityParticleRemapMath
        switch component {
        case .x: return SIMD3(repeating: value.x)
        case .y: return SIMD3(repeating: value.y)
        case .z: return SIMD3(repeating: value.z)
        case .sum: return SIMD3(repeating: value.y + value.x + value.z)
        case .average: return SIMD3(repeating: (value.y + value.x + value.z) * Math.third)
        case .max:
            if initializer {
                let yz = value.z <= value.y ? value.y : value.z
                return SIMD3(repeating: yz <= value.x ? value.x : yz)
            }
            let xy = value.x > value.y ? value.x : value.y
            return SIMD3(repeating: xy > value.z ? xy : value.z)
        case .min:
            if initializer {
                let yz = value.y <= value.z ? value.y : value.z
                return SIMD3(repeating: value.x <= yz ? value.x : yz)
            }
            let xy = value.x < value.y ? value.x : value.y
            return SIMD3(repeating: xy < value.z ? xy : value.z)
        case .all, .unknown: return value
        }
    }

    /// Normalised input → transform → output range, per component (full.s 601324-601857; 594795-595083).
    private func remapValue(_ remap: WPEParityParticleRemap, slot: Int, initializer: Bool) -> SIMD3<Float> {
        typealias Math = WPEParityParticleRemapMath
        var value = remapInput(remap, slot: slot, initializer: initializer)
        let vectorInput = remap.input.isVector, vectorOutput = remap.output.isVector
        if vectorInput || initializer {
            if vectorInput {
                value = Self.reduce(value, remap.inputComponent, initializer: initializer)
            }
            for axis in 0 ..< 3 {
                let shifted = value[axis] - remap.inputMin[axis]
                value[axis] = initializer ? shifted / remap.inputRange[axis] : shifted * (1 / remap.inputRange[axis])
            }
        } else {
            value = SIMD3(repeating: (value.x - remap.inputMin.x) * (1 / remap.inputRange.x))
        }
        if remap.flags & 1 != 0 {
            for axis in 0 ..< 3 {
                value[axis] = initializer ? Math.clampScalar(value[axis]) : Math.clampSSE(value[axis])
            }
        }
        // y and z only matter, and are only transformed by the operator, for a vector output.
        let seeds = Math.seeds(birthU[slot])
        for axis in 0 ..< (vectorOutput ? 3 : 1) {
            value[axis] = initializer
                ? Self.transformInitial(value[axis], remap)
                : Self.transformOperator(value[axis], remap, seed: seeds[axis])
        }
        for axis in 0 ..< 3 {
            var mapped = initializer
                ? value[axis] * remap.outputRange[axis] + remap.outputMin[axis]
                : remap.outputRange[axis] * value[axis] + remap.outputMin[axis]
            if remap.flags & 2 != 0 {
                mapped = initializer ? Math.clampScalar(mapped) : Math.clampSSE(mapped)
            }
            value[axis] = mapped
        }
        return value
    }

    /// The operator's SSE transforms (full.s 601406-601836).
    private static func transformOperator(_ value: Float, _ remap: WPEParityParticleRemap, seed: Int32) -> Float {
        typealias Math = WPEParityParticleRemapMath
        let scale = remap.inputScale
        switch remap.transform {
        case .sine:
            return Math.sinPS(value * (scale * Math.pi) - Math.halfPi) * 0.5 + 0.5
        case .square:
            let scaled = value * scale
            let fraction = scaled - scaled.rounded(.towardZero)
            return fraction.rounded(.toNearestOrEven) + (scaled < 0 ? 1 : 0)
        case .saw:
            let scaled = value * scale
            return scaled - scaled.rounded(.towardZero) + (value < 0 ? 1 : 0)
        case .triangle:
            let scaled = abs(value * scale)
            return 1 - abs((scaled - scaled.rounded(.towardZero)) * 2 - 1)
        case .simplexNoise:
            return Math.simplex2(seed: seed, value * scale, 0) * 0.5 + 0.5
        case .fbmNoise:
            return Math.fbm2(seed: seed, octaves: remap.octaves, bounding: remap.fractalBounding, value * scale, 0)
                * 0.5 + 0.5
        case .none, .unknown:
            return value
        }
    }

    /// The initializer's scalar transforms (full.s 594861-595061): CRT sinf, floorf, roundf.
    private static func transformInitial(_ value: Float, _ remap: WPEParityParticleRemap) -> Float {
        typealias Math = WPEParityParticleRemapMath
        let scale = remap.inputScale
        switch remap.transform {
        case .sine:
            return WPEParityParticleMath.sin(value * Math.pi * scale - Math.halfPi) * 0.5 + 0.5
        case .square:
            let scaled = value * scale
            return (scaled - floorf(scaled)).rounded(.toNearestOrAwayFromZero) + (scaled < 0 ? 1 : 0)
        case .saw:
            let scaled = value * scale
            return scaled - floorf(scaled) + (value < 0 ? 1 : 0)
        case .triangle:
            let scaled = abs(value * scale)
            return 1 - abs((scaled - floorf(scaled)) * 2 - 1)
        case .simplexNoise:
            return Math.simplex1(value * scale) * 0.5 + 0.5
        case .fbmNoise:
            return Math.fbm1(value, octaves: remap.octaves, scale: scale) * 0.5 + 0.5
        case .none, .unknown:
            return value
        }
    }

    /// Writes the remapped value with the operation into the output (full.s 601858-603080; 595084-596357).
    mutating func applyRemap(_ remap: WPEParityParticleRemap, slot: Int, initializer: Bool) {
        let value = remapValue(remap, slot: slot, initializer: initializer)
        let operation = remap.operation
        func each(_ target: inout SIMD3<Float>) {
            switch remap.outputComponent {
            case .all:
                for axis in 0 ..< 3 {
                    target[axis] = operation.apply(target[axis], value[axis])
                }
            case .x: target.x = operation.apply(target.x, value.x)
            case .y: target.y = operation.apply(target.y, value.y)
            case .z: target.z = operation.apply(target.z, value.z)
            default: break
            }
        }
        func length(_ v: SIMD3<Float>) -> Float {
            (v.y * v.y + v.x * v.x + v.z * v.z).squareRoot()
        }
        switch remap.output {
        case .maxLifetime:
            // Zero would mark the slot free without `kill`; the next age check kills it instead.
            let next = operation.apply(lifetime[slot], value.x)
            lifetime[slot] = next == 0 ? .leastNonzeroMagnitude : next
        case .size:
            if initializer {
                initialSize[slot] = operation.apply(initialSize[slot], value.x)
            } else {
                size[slot] = operation.apply(size[slot], value.x)
            }
        case .opacity:
            if initializer {
                initialAlpha[slot] = operation.apply(initialAlpha[slot], value.x)
            } else {
                alpha[slot] = operation.apply(alpha[slot], value.x)
            }
        case .speed:
            let speed = length(velocity[slot])
            let next = operation.apply(speed, value.x)
            velocity[slot] *= speed > 0 ? next / speed : next
        case .rotation: rotation[slot].z = operation.apply(rotation[slot].z, value.x)
        case .angularSpeed: angularVelocity[slot].z = operation.apply(angularVelocity[slot].z, value.x)
        case .distanceToControlPoint:
            let center = controlPointTranslation(remap.outputControlPoint0)
            let offset = position[slot] - center
            let distance = length(offset)
            let direction = distance != 0 ? offset / distance : .zero
            position[slot] = direction * operation.apply(distance, value.x) + center
        case .positionBetweenControlPoints:
            let a = controlPointTranslation(remap.outputControlPoint0)
            let line = controlPointTranslation(remap.outputControlPoint1) - a
            let lineLength = length(line)
            let direction = lineLength != 0 ? line / lineLength : .zero
            let along = position[slot] - a
            let projected = along.y * direction.y + along.x * direction.x + along.z * direction.z
            let perpendicular = along - projected * direction
            let fraction = lineLength != 0 ? projected / lineLength : 0
            position[slot] = operation.apply(fraction, value.x) * lineLength * direction + perpendicular + a
        case .color:
            if initializer {
                each(&initialColor[slot])
            } else {
                each(&color[slot])
            }
        case .position: each(&position[slot])
        case .velocity: each(&velocity[slot])
        case .controlPoint:
            // Every 4-slot group writes its first lane; one write per live particle here.
            var center = controlPointTranslation(remap.outputControlPoint0)
            each(&center)
            controlPoints[remap.outputControlPoint0].columns.3 = SIMD4(center, 1)
        case .deltaToControlPoint:
            let center = controlPointTranslation(remap.outputControlPoint0)
            var delta = center - position[slot]
            each(&delta)
            position[slot] = center - delta
        case .directionToControlPoint:
            let center = controlPointTranslation(remap.outputControlPoint0)
            let delta = center - position[slot]
            let distance = length(delta)
            var direction = distance > 0 ? delta / distance : .zero
            each(&direction)
            let directionLength = length(direction)
            position[slot] = center - (directionLength > 0 ? direction / directionLength : .zero) * distance
        case .lifetimeFraction, .runtime, .timeOfDay, .particleSystemTime, .layerTime, .layerOrigin, .unknown:
            break
        }
        if initializer, remap.input == .controlPoint || remap.input == .deltaToControlPoint
            || remap.input == .directionToControlPoint {
            controlPoints[remap.inputControlPoint].columns.3 = SIMD4(0, 0, 0, 1)
        }
    }

    /// Operator 20: every particle takes the parent particle's current value while it lives (full.s 605733-606727).
    mutating func applyInherit(_ inherit: WPEParityParticleInherit, slot: Int, parent: WPEParityParticleParentSample) {
        switch inherit {
        case .setColor: color[slot] = parent.color
        case .multiplyColor: color[slot] *= parent.color
        case .setOpacity: alpha[slot] = parent.alpha
        case .multiplyOpacity: alpha[slot] *= parent.alpha
        case .setColorOpacity:
            color[slot] = parent.color
            alpha[slot] = parent.alpha
        case .multiplyColorOpacity:
            color[slot] *= parent.color
            alpha[slot] *= parent.alpha
        case .setVelocity: velocity[slot] = parent.velocity
        case .addVelocity: velocity[slot] += parent.velocity
        case .setSize: size[slot] = parent.size
        case .multiplySize: size[slot] *= parent.size
        case .setRotation: rotation[slot] = parent.rotation
        case .addRotation: rotation[slot] += parent.rotation
        case .setAngularVelocity: angularVelocity[slot] = parent.angularVelocity
        case .addAngularVelocity: angularVelocity[slot] += parent.angularVelocity
        case .unknown: break
        }
    }

    /// Initializer 16: the parent's current value into the initial one, alive or not (full.s 596358-596640).
    mutating func applyInitialInherit(_ inherit: WPEParityParticleInherit, slot: Int,
                                      parent: WPEParityParticleParentSample) {
        switch inherit {
        case .setColor: initialColor[slot] = parent.color
        case .multiplyColor: initialColor[slot] = parent.color * initialColor[slot]
        case .setOpacity: initialAlpha[slot] = parent.alpha
        case .multiplyOpacity: initialAlpha[slot] = parent.alpha * initialAlpha[slot]
        case .setColorOpacity:
            initialColor[slot] = parent.color
            initialAlpha[slot] = parent.alpha
        case .multiplyColorOpacity:
            initialColor[slot] = parent.color * initialColor[slot]
            initialAlpha[slot] = parent.alpha * initialAlpha[slot]
        case .setVelocity: velocity[slot] = parent.velocity
        case .addVelocity: velocity[slot] = parent.velocity + velocity[slot]
        case .setSize: initialSize[slot] = parent.size
        case .multiplySize: initialSize[slot] = parent.size * initialSize[slot]
        case .setRotation: rotation[slot] = parent.rotation
        case .addRotation: rotation[slot] = parent.rotation + rotation[slot]
        case .setAngularVelocity: angularVelocity[slot] = parent.angularVelocity
        case .addAngularVelocity: angularVelocity[slot] = parent.angularVelocity + angularVelocity[slot]
        case .unknown: break
        }
    }

    func parentSample(slot: Int) -> WPEParityParticleParentSample? {
        guard slot >= 0, slot < highWater, lifetime.indices.contains(slot) else { return nil }
        return WPEParityParticleParentSample(
            alive: lifetime[slot] > 0, color: color[slot], alpha: alpha[slot], velocity: velocity[slot],
            size: size[slot], rotation: rotation[slot], angularVelocity: angularVelocity[slot]
        )
    }
}
