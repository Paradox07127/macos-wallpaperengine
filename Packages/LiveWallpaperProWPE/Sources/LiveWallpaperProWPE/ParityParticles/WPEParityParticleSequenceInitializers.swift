import Foundation
import simd

/// hsvcolorrandom (D/1401ba3e0.c): hue in turns, quantised to `steps` by the CRT `rand()`.
struct WPEParityParticleHSVRandom: Equatable, Sendable {
    var hueMin: Float
    var hueStep: Float
    var steps: Int
    var saturation: SIMD2<Float>
    var value: SIMD2<Float>

    init(_ entry: WPEParityParticleEntry) {
        hueMin = entry.number("huemin", 0)
        let range = entry.number("huemax", 1) - hueMin
        steps = entry.integer("huesteps", 6)
        // A whole-turn range would repeat its first hue at the end, so it divides by steps instead.
        if steps <= 1 {
            hueStep = 0
        } else if abs(fmodf(range, 1)) < 1.0 / 360 {
            hueStep = range / Float(steps)
        } else {
            hueStep = range / Float(steps - 1)
        }
        saturation = SIMD2(entry.number("saturationmin", 0.5), entry.number("saturationmax", 1))
        value = SIMD2(entry.number("valuemin", 0.5), entry.number("valuemax", 1))
    }
}

/// turbulentvelocityrandom (D/1401bb030.c).
struct WPEParityParticleTurbulentVelocity: Equatable, Sendable {
    var speedMin: Float
    var speedMax: Float
    var phaseMin: Float
    var phaseMax: Float
    var timeScale: Float
    var scale: Float
    var offset: Float
    var forward: SIMD3<Float>
    var right: SIMD3<Float>

    init(_ entry: WPEParityParticleEntry, is3D: Bool) {
        speedMin = entry.number("speedmin", is3D ? 0.5 : 100)
        speedMax = entry.number("speedmax", is3D ? 1 : 250)
        phaseMin = entry.number("phasemin", 0)
        phaseMax = entry.number("phasemax", 0.1)
        timeScale = entry.number("timescale", 1)
        scale = entry.number("scale", 1)
        offset = entry.number("offset", 0)
        forward = entry.vector("forward", SIMD3(0, 1, 0))
        right = entry.vector("right", SIMD3(0, 0, 1))
    }
}

/// positionoffsetrandom (D/1401bb660.c).
struct WPEParityParticlePositionOffset: Equatable, Sendable {
    var directions: SIMD3<Float>
    var sign: SIMD3<Float>
    var scale: Float
    var distance: Float
    var timeScale: Float
    var octaves: Int

    init(_ entry: WPEParityParticleEntry, is3D: Bool) {
        directions = entry.vector("directions", is3D ? SIMD3(1, 1, 1) : SIMD3(1, 1, 0))
        sign = entry.vector("sign", .zero)
        scale = entry.number("scale", is3D ? 1 : 0.001)
        distance = entry.number("distance", is3D ? 0.1 : 100)
        timeScale = entry.number("timescale", 1)
        octaves = min(max(entry.integer("octaves", 6), 1), 8)
    }
}

/// mapsequencearoundcontrolpoint (D/1401bbc90.c). `t` advances by 1/count per birth, shared by the system.
struct WPEParityParticleSequenceAround: Equatable, Sendable {
    var count: Int
    var bounds: SIMD2<Float>
    var speedMin: SIMD3<Float>
    var speedMax: SIMD3<Float>
    var axis: SIMD3<Float>
    /// θ = 0 points along `cosineAxis`, θ = π/2 along `sineAxis` = axis × cosineAxis.
    var cosineAxis: SIMD3<Float>
    var sineAxis: SIMD3<Float>
    var mirror: Bool
    var controlPoint: Int

    init(_ entry: WPEParityParticleEntry) {
        count = max(entry.integer("count", 32), 1)
        let bounds = entry.vector("bounds", SIMD3(0, 1, 0))
        self.bounds = SIMD2(bounds.x, bounds.y)
        speedMin = entry.vector("speedmin", .zero)
        speedMax = entry.vector("speedmax", .zero)
        axis = WPEParityParticleVortex.normalizedAxis(entry.vector("axis", SIMD3(0, 0, 1)))
        let reference: SIMD3<Float> = abs(axis.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        cosineAxis = simd_normalize(reference - simd_dot(reference, axis) * axis)
        sineAxis = simd_cross(axis, cosineAxis)
        mirror = WPEParityParticleJSON.string(entry.json["limitbehavior"])?.lowercased() == "mirror"
        controlPoint = entry.controlPoint("controlpoint")
    }
}

/// mapsequencebetweencontrolpoints (D/1401bc080.c). `t` advances by 1/(count − 1) per birth.
struct WPEParityParticleSequenceBetween: Equatable, Sendable {
    var count: Int
    var bounds: SIMD2<Float>
    var mirror: Bool
    var start: Int
    var end: Int
    var flags: Int
    var arcAmount: Float
    var arcDirection: SIMD3<Float>
    var sizeReduction: Float

    init(_ entry: WPEParityParticleEntry) {
        count = max(entry.integer("count", 32), 2)
        let bounds = entry.vector("bounds", SIMD3(0, 1, 0))
        self.bounds = SIMD2(bounds.x, bounds.y)
        mirror = WPEParityParticleJSON.string(entry.json["limitbehavior"])?.lowercased() == "mirror"
        start = entry.controlPoint("controlpointstart")
        end = entry.controlPoint("controlpointend", 1)
        flags = entry.integer("flags", 0)
        arcAmount = entry.number("arcamount", 0.3)
        arcDirection = entry.vector("arcdirection", SIMD3(0, 1, 0))
        sizeReduction = entry.number("sizereductionamount", 0.9)
    }
}

/// Position of a mapsequence initializer along its sequence; one per initializer per system.
struct WPEParityParticleSequenceState {
    var t: Float = 0
    var step: Float = 0

    /// t += step; above 1 repeat wraps (`fmod` or back to 0), mirror reflects; below 0 reflects (D/14023b340.c:898-937).
    mutating func advance(mirror: Bool, wrapsByRemainder: Bool) {
        t += step
        if t > 1 {
            if mirror {
                t = 1 - (t - 1)
                step = -step
            } else {
                t = wrapsByRemainder ? fmodf(t, 1) : 0
            }
        } else if t < 0 {
            t = -t
            step = -step
        }
    }
}

extension WPEParityParticleSystem {
    /// k = clamp(⌊rand()/32767·(steps+1)⌋, 0, steps), then one U each for S and V (D/14023b340.c:412-437).
    mutating func initializeHSV(_ hsv: WPEParityParticleHSVRandom, slot: Int) {
        let k = min(max(Int(Float(crt.next()) / 32767 * Float(hsv.steps + 1)), 0), hsv.steps)
        let hue = hsv.hueMin + Float(k) * hsv.hueStep
        let saturation = rng.draw(hsv.saturation.x, hsv.saturation.y)
        let value = rng.draw(hsv.value.x, hsv.value.y)
        initialColor[slot] *= WPEParityParticleMath.hsvToRGB(hue: hue * 360, saturation: saturation, value: value)
    }

    /// One integer draw for the entry, then one U per HSV channel inside ±noise (D/14023b340.c:438-523).
    mutating func initializeColorList(_ colors: [SIMD3<Float>], noise: SIMD3<Float>, slot: Int) {
        let base = colors[Int(rng.integer(0, Int32(colors.count - 1)))]
        var hsv = SIMD3<Float>()
        for channel in 0 ..< 3 {
            hsv[channel] = rng.draw(max(base[channel] - noise[channel], 0), min(base[channel] + noise[channel], 1))
        }
        let hue = hsv.x - hsv.x.rounded(.down)
        let saturation = WPEParityParticleMath.saturate(hsv.y)
        let value = WPEParityParticleMath.saturate(hsv.z)
        initialColor[slot] *= WPEParityParticleMath.hsvToRGB(hue: hue * 360, saturation: saturation, value: value)
    }

    /// θ = noise1(t)·π·scale + offset turns `forward` about `right`; U for phase, then U for speed (:622-667).
    mutating func initializeTurbulentVelocity(_ field: WPEParityParticleTurbulentVelocity, slot: Int) {
        let phase = rng.unit()
        let t = (phase * (field.phaseMax - field.phaseMin) + field.phaseMin + frameContext.time) * field.timeScale
        let theta = WPEParityParticleNoise.simplex1(t) * .pi * field.scale + field.offset
        let direction = simd_quatf(angle: theta, axis: simd_normalize(field.right)).act(field.forward)
        let speed = field.speedMin + rng.unit() * (field.speedMax - field.speedMin)
        velocity[slot] += direction * speed
    }

    /// fbm of 2D simplex per axis, no draws (D/14023b340.c:698-790).
    mutating func initializePositionOffset(_ field: WPEParityParticlePositionOffset, slot: Int) {
        let time = field.timeScale * frameContext.time
        let point = position[slot] * field.scale
        func fbm(_ x: Float, _ y: Float) -> Float {
            var sum: Float = 0, total: Float = 0, amplitude: Float = 1, frequency: Float = 1
            for _ in 0 ..< field.octaves {
                sum += amplitude * WPEParityParticleNoise.simplex2(frequency * x, frequency * y)
                total += amplitude
                amplitude *= 0.5
                frequency *= 2
            }
            return sum / total
        }
        var offset = SIMD3(fbm(point.x, time), fbm(time, point.y), fbm(point.z, -time)) * field.directions
        for axis in 0 ..< 3 where field.sign[axis] != 0 {
            offset[axis] = abs(offset[axis]) * field.sign[axis]
        }
        position[slot] += offset * field.distance
    }

    /// Keeps the height along the axis and the radius, sets the angle from t; 3 U for axial, tangential,
    /// radial speed (D/14023b340.c:826-937).
    mutating func initializeSequenceAround(_ field: WPEParityParticleSequenceAround, index: Int, slot: Int) {
        let basis = controlPointBasis(field.controlPoint)
        let axis = basis * field.axis, cosineAxis = basis * field.cosineAxis, sineAxis = basis * field.sineAxis
        let center = controlPointTranslation(field.controlPoint)
        var state = sequenceStates[index]
        let theta = 2 * Float.pi * (field.bounds.x + state.t * (field.bounds.y - field.bounds.x))
        let offset = position[slot] - center
        let height = simd_dot(offset, axis)
        let radius = simd_length(offset - height * axis)
        let radial = cos(theta) * cosineAxis + sin(theta) * sineAxis
        let tangent = -sin(theta) * cosineAxis + cos(theta) * sineAxis
        let delta = field.speedMax - field.speedMin
        let axial = field.speedMin.z + rng.unit() * delta.z
        let along = field.speedMin.x + rng.unit() * delta.x
        let outward = field.speedMin.y + rng.unit() * delta.y
        velocity[slot] += tangent * along + radial * outward + axis * axial
        position[slot] = center + height * axis + radius * radial
        state.advance(mirror: field.mirror, wrapsByRemainder: true)
        sequenceStates[index] = state
    }

    /// Places the particle at bmin + t·Δb along A→B, keeping its offset perpendicular to the line (D/14023b340.c:938-1032).
    mutating func initializeSequenceBetween(_ field: WPEParityParticleSequenceBetween, index: Int, slot: Int) {
        let a = controlPointTranslation(field.start)
        let line = controlPointTranslation(field.end) - a
        let length = max(simd_length(line), .leastNormalMagnitude)
        let direction = line / length
        var state = sequenceStates[index]
        let fraction = field.bounds.x + state.t * (field.bounds.y - field.bounds.x)
        let centred = 2 * state.t - 1
        let w = 1 - centred * centred
        var perpendicular = position[slot] - simd_dot(position[slot], direction) * direction
        if field.flags & 1 != 0 {
            perpendicular *= w
        }
        position[slot] = perpendicular + fraction * length * direction + a
        if field.flags & 8 != 0 {
            position[slot] += field.arcDirection * w * length * field.arcAmount
        }
        if field.flags & 2 != 0 {
            velocity[slot] *= w
        }
        if field.flags & 4 != 0 {
            initialSize[slot] *= 1 - field.sizeReduction + field.sizeReduction * w
        }
        state.advance(mirror: field.mirror, wrapsByRemainder: false)
        sequenceStates[index] = state
    }
}
