import simd

/// turbulence (R19 算子 14; defaults D/1401beb80.c:20-126). Reads the birth u, draws nothing.
struct WPEParityParticleTurbulence: Equatable, Sendable {
    var mask: SIMD3<Float>
    var scale: Float
    var speedMin: Float
    var speedMax: Float
    var phaseMin: Float
    var phaseMax: Float
    var timeScale: Float

    init(_ entry: WPEParityParticleEntry, is3D: Bool) {
        mask = entry.vector("mask", is3D ? SIMD3(1, 1, 1) : SIMD3(1, 1, 0))
        scale = entry.number("scale", is3D ? 0.5 : 0.01)
        speedMin = entry.number("speedmin", is3D ? 1 : 500)
        speedMax = entry.number("speedmax", is3D ? 5 : 1000)
        phaseMin = entry.number("phasemin", 0)
        phaseMax = entry.number("phasemax", 0)
        timeScale = entry.number("timescale", is3D ? 1 : 20)
    }
}

/// controlpointattract (R19 算子 10; D/1401bdee0.c:20-140).
struct WPEParityParticleAttract: Equatable, Sendable {
    var controlPoint: Int
    var scale: Float
    var threshold: Float
    var deleteThresholdSquared: Float
    var flags: Int

    init(_ entry: WPEParityParticleEntry, is3D: Bool) {
        controlPoint = entry.controlPoint("controlpoint")
        scale = entry.number("scale", is3D ? 20 : 512)
        threshold = entry.number("threshold", is3D ? 5 : 512)
        let deleteThreshold = entry.number("deletethreshold", is3D ? 0.5 : 15)
        deleteThresholdSquared = deleteThreshold * deleteThreshold
        flags = entry.integer("flags", 2)
    }
}

/// vortex (R19 算子 15; D/1401bef00.c:19-142).
struct WPEParityParticleVortex: Equatable, Sendable {
    var controlPoint: Int
    var offset: SIMD3<Float>
    var axis: SIMD3<Float>
    var inner: Float
    var outer: Float
    var speedInner: Float
    var speedOuter: Float
    var flags: Int

    init(_ entry: WPEParityParticleEntry, is3D: Bool) {
        controlPoint = entry.controlPoint("controlpoint")
        offset = entry.vector("offset", .zero)
        axis = Self.normalizedAxis(entry.vector("axis", SIMD3(0, 0, 1)))
        inner = entry.number("distanceinner", is3D ? 1 : 500)
        outer = entry.number("distanceouter", is3D ? 2 : 650)
        speedInner = entry.number("speedinner", is3D ? 1 : 2500)
        speedOuter = entry.number("speedouter", 0)
        flags = entry.integer("flags", 0)
    }

    /// A degenerate axis falls back to +Z at parse.
    static func normalizedAxis(_ axis: SIMD3<Float>) -> SIMD3<Float> {
        simd_length(axis) < 1e-6 ? SIMD3(0, 0, 1) : simd_normalize(axis)
    }
}

/// vortex_v2 (R19 算子 16; D/1401bf2d0.c:21-146).
struct WPEParityParticleVortexRing: Equatable, Sendable {
    var controlPoint: Int
    var axis: SIMD3<Float>
    var inner: Float
    var outer: Float
    var speedInner: Float
    var speedOuter: Float
    var ringRadius: Float
    var ringWidth: Float
    var ringPullDistance: Float
    var ringPullForce: Float
    var centerForce: Float
    var flags: Int

    init(_ entry: WPEParityParticleEntry, is3D: Bool) {
        controlPoint = entry.controlPoint("controlpoint")
        axis = WPEParityParticleVortex.normalizedAxis(entry.vector("axis", SIMD3(0, 0, 1)))
        inner = entry.number("distanceinner", is3D ? 1 : 500)
        outer = entry.number("distanceouter", is3D ? 2 : 650)
        speedInner = entry.number("speedinner", is3D ? 1 : 2500)
        speedOuter = entry.number("speedouter", 0)
        ringRadius = entry.number("ringradius", is3D ? 1 : 300)
        ringWidth = entry.number("ringwidth", is3D ? 0.2 : 50)
        ringPullDistance = entry.number("ringpulldistance", is3D ? 0.25 : 50)
        ringPullForce = entry.number("ringpullforce", is3D ? 0.05 : 10)
        flags = entry.integer("flags", 0)
        centerForce = flags & 2 != 0 ? entry.number("centerforce", 1) : 0
    }
}

/// boids (R19 算子 17; D/1401bf700.c:18-122).
struct WPEParityParticleBoids: Equatable, Sendable {
    var separationThreshold: Float
    var neighborThreshold: Float
    var maxSpeed: Float
    var separationFactor: Float
    var alignmentFactor: Float
    var cohesionFactor: Float
    var flags: Int

    init(_ entry: WPEParityParticleEntry, is3D: Bool) {
        separationThreshold = entry.number("separationthreshold", is3D ? 0.02 : 20)
        neighborThreshold = entry.number("neighborthreshold", is3D ? 0.2 : 50)
        maxSpeed = entry.number("maxspeed", is3D ? 1 : 500)
        separationFactor = entry.number("separationfactor", 15)
        alignmentFactor = entry.number("alignmentfactor", 1)
        cohesionFactor = entry.number("cohesionfactor", 2)
        flags = entry.integer("flags", 1)
    }
}

/// collisionplane / collisionsphere with the bounce behaviour (D/1401c00a0.c, D/1401c0540.c:32-67).
struct WPEParityParticleCollision: Equatable, Sendable {
    /// Plane normal, or sphere origin.
    var vector: SIMD3<Float>
    /// Plane distance, or sphere radius.
    var scalar: Float
    /// −(1 + bouncefactor), as WPE stores it.
    var bounce: Float
    var controlPoint: Int
    var flags: Int

    init(_ entry: WPEParityParticleEntry, sphere: Bool, is3D: Bool) {
        if sphere {
            vector = entry.vector("origin", is3D ? .zero : SIMD3(0, -200, 0))
            scalar = entry.number("radius", is3D ? 1 : 50)
        } else {
            vector = entry.vector("plane", SIMD3(0, 1, 0))
            scalar = entry.number("distance", is3D ? 0 : -150)
        }
        bounce = -(1 + entry.number("bouncefactor", 0.5))
        controlPoint = entry.controlPoint("controlpoint")
        flags = entry.integer("flags", 0)
    }
}

extension WPEParityParticleSystem {
    /// v += dt·mask·sp·N(…) with the coordinates rotated per axis (S599181-599420).
    mutating func applyTurbulence(_ field: WPEParityParticleTurbulence, slot: Int, weight: Float, dt: Float) {
        typealias Noise = WPEParityParticleNoise
        let u = birthU[slot]
        let phase = frameContext.time * field.timeScale + u * (field.phaseMax - field.phaseMin)
        let speed = field.speedMin + u * (field.speedMax - field.speedMin)
        let point = (position[slot] + phase) * field.scale
        let gain = dt * speed * weight
        if field.mask.x != 0 {
            velocity[slot].x += gain * field.mask.x * Noise.simplex3(point.x, point.y, point.z)
        }
        if field.mask.y != 0 {
            velocity[slot].y += gain * field.mask.y * Noise.simplex3(point.z, point.x, point.y)
        }
        if field.mask.z != 0 {
            velocity[slot].z += gain * field.mask.z * Noise.simplex3(point.y, point.z, point.x)
        }
    }

    /// Pull toward the point inside `threshold`; flags&1 ends a particle whose path this frame passes the point.
    mutating func applyAttract(_ field: WPEParityParticleAttract, slot: Int, weight: Float, dt: Float) {
        let center = controlPointTranslation(field.controlPoint)
        let delta = position[slot] - center
        let distance = simd_length(delta)
        if distance > .leastNormalMagnitude, distance < field.threshold {
            var force = dt * field.scale * (1 - distance / field.threshold)
            if field.flags & 2 != 0 {
                force = min(force, distance)
            }
            velocity[slot] -= delta / distance * force * weight
        }
        if field.flags & 1 != 0 {
            let start = previousPosition[slot], path = position[slot] - start
            let length = simd_length_squared(path)
            let along = length > 0 ? WPEParityParticleMath.saturate(simd_dot(center - start, path) / length) : 0
            if simd_length_squared(start + along * path - center) < field.deleteThresholdSquared {
                age[slot] = lifetime[slot]
            }
        }
    }

    /// No guard at r = 0: the normal is NaN there, as in WPE.
    mutating func applyVortex(_ field: WPEParityParticleVortex, slot: Int, weight: Float, dt: Float) {
        var radial = position[slot] - (controlPointTranslation(field.controlPoint) + field.offset)
        if field.flags & 1 != 0 {
            radial -= simd_dot(radial, field.axis) * field.axis
        }
        let normal = radial / simd_length(radial)
        let s = WPEParityParticleMath.saturate((simd_length(radial) - field.inner) / (field.outer - field.inner))
        let speed = field.speedInner + s * (field.speedOuter - field.speedInner)
        velocity[slot] += simd_cross(normal, field.axis) * dt * speed * weight
    }

    /// S599760-600000: swirl plus a radial correction that keeps the next-step radius, and the ring pull.
    mutating func applyVortexRing(_ field: WPEParityParticleVortexRing, slot: Int, weight: Float, dt: Float) {
        let center = controlPointTranslation(field.controlPoint)
        let axis = simd_normalize(controlPointBasis(field.controlPoint) * field.axis)
        let offset = position[slot] - center
        let height = field.flags & 1 != 0 ? simd_dot(offset, axis) : 0
        let radial = offset - height * axis
        let radius = simd_length(radial)
        let normal = radial / radius
        let s: Float, pull: Float
        if field.flags & 4 != 0 {
            let gap = field.ringRadius - radius
            s = WPEParityParticleMath.saturate((abs(gap) - field.ringWidth) / field.ringPullDistance)
            let direction: Float = gap > 0 ? 1 : (gap < 0 ? -1 : 0)
            pull = direction * (s != 0 ? 1 - s : 0) * field.ringPullForce * dt
        } else {
            s = WPEParityParticleMath.saturate((radius - field.inner) / (field.outer - field.inner))
            pull = 0
        }
        let ahead = position[slot] + velocity[slot] * dt - center - height * axis
        let correction = (radius / simd_length(ahead) - 1) * field.centerForce / dt + pull
        let speed = field.speedInner + s * (field.speedOuter - field.speedInner)
        velocity[slot] += (dt * speed * simd_cross(normal, axis) + correction * ahead) * weight
    }

    /// One slot block of 4 in every G = ⌊slots/200⌋ + 1 runs per frame, with G·dt (S600519-600855).
    /// A block reads its neighbours before writing, as WPE's 4-wide SIMD pass does.
    mutating func applyBoids(_ field: WPEParityParticleBoids, blend: WPEParityParticleBlend?, dt: Float) {
        let groups = capacity / 200 + 1
        let gain = Float(groups) * dt
        let maxSpeedSquared = field.maxSpeed * field.maxSpeed
        var block = boidsFrame % groups
        while block * 4 < highWater {
            var next = (SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>())
            for lane in 0 ..< 4 {
                let slot = block * 4 + lane
                guard slot < highWater, lifetime[slot] != 0 else { continue }
                let target = boidsVelocity(field, slot: slot, gain: gain, maxSpeedSquared: maxSpeedSquared)
                let weight = blend?.weight(t: age[slot] / lifetime[slot]) ?? 1
                let blended = velocity[slot] + (target - velocity[slot]) * weight
                (next.0[lane], next.1[lane], next.2[lane]) = (blended.x, blended.y, blended.z)
            }
            for lane in 0 ..< 4 {
                let slot = block * 4 + lane
                if slot < highWater, lifetime[slot] != 0 {
                    velocity[slot] = SIMD3(next.0[lane], next.1[lane], next.2[lane])
                }
            }
            block += groups
        }
    }

    private func boidsVelocity(
        _ field: WPEParityParticleBoids, slot: Int, gain: Float, maxSpeedSquared: Float
    ) -> SIMD3<Float> {
        let here = position[slot], own = velocity[slot]
        var separation = SIMD3<Float>.zero, velocitySum = SIMD3<Float>.zero, positionSum = SIMD3<Float>.zero
        var separated: Float = 0, neighbours: Float = 0
        for other in 0 ..< highWater where lifetime[other] != 0 {
            let offset = here - position[other]
            let distance = simd_length(offset)
            if distance < field.separationThreshold, distance != 0 {
                separation += (field.separationThreshold / distance - 1) * offset
                separated += 1
            }
            // The particle itself counts as a neighbour ([I] in R19).
            if distance < field.neighborThreshold {
                velocitySum += velocity[other]
                positionSum += position[other]
                neighbours += 1
            }
        }
        var change = SIMD3<Float>.zero
        if separated > 0 {
            change += separation / separated * field.separationFactor
        }
        if neighbours > 0 {
            change += (velocitySum / neighbours - own) * field.alignmentFactor
            change += (positionSum / neighbours - here) * field.cohesionFactor
        }
        var next = own + change * gain
        let speedSquared = simd_length_squared(next)
        if field.flags & 1 != 0, speedSquared > max(simd_length_squared(own), maxSpeedSquared) {
            next *= field.maxSpeed / speedSquared.squareRoot()
        }
        return next
    }

    /// Follows the point's last move, then pulls toward `distance` through M = inverse(CP 3×3) (S598357-598520).
    mutating func applyMaintainDistance(
        controlPoint: Int, distance: Float, variableStrength: Float, slot: Int, weight: Float, dt: Float
    ) {
        let center = controlPointTranslation(controlPoint)
        let moved = position[slot] + (center - previousControlPointTranslation(controlPoint))
        let offset = moved - center
        let strength = variableStrength != 0 ? WPEParityParticleMath.saturate(variableStrength * dt) : 1
        let local = controlPointBasis(controlPoint).inverse * offset
        let target = moved + strength * (distance / simd_length(local) - 1) * offset
        position[slot] += (target - position[slot]) * weight
    }

    /// Keeps the particle's place along A0→B0 and its perpendicular offset on the moved segment A→B (S598712-598880).
    mutating func applyMaintainBetween(start: Int, end: Int, slot: Int, weight: Float) {
        let a = controlPointTranslation(start), b = controlPointTranslation(end)
        let a0 = previousControlPointTranslation(start), b0 = previousControlPointTranslation(end)
        let previous = b0 - a0
        guard simd_length_squared(b - a) > 1.42e-14, simd_length_squared(previous) > 1.42e-14 else { return }
        let length = simd_length(previous)
        let direction = previous / length
        let along = simd_dot(position[slot] - a0, direction)
        let s = WPEParityParticleMath.saturate(along / length)
        let target = a + s * (b - a) + (position[slot] - a0 - along * direction)
        position[slot] += (target - position[slot]) * weight
    }

    mutating func applyReduceMovement(
        controlPoint: Int, inner: Float, outer: Float, reductionInner: Float, reductionDelta: Float,
        slot: Int, weight: Float, dt: Float
    ) {
        let distance = simd_length(position[slot] - controlPointTranslation(controlPoint))
        let s = WPEParityParticleMath.saturate((distance - inner) / (outer - inner))
        let reduction = WPEParityParticleMath.saturate((reductionInner + s * reductionDelta) * dt)
        velocity[slot] *= 1 - reduction * weight
    }

    /// Plane bounce (D/14024f5e0.c:20-120): below the plane, push back onto it and reflect v·n.
    mutating func applyCollisionPlane(_ field: WPEParityParticleCollision, slot: Int, weight: Float) {
        var normal = field.vector, distance = field.scalar
        if field.flags & 1 != 0 {
            normal = controlPointBasis(field.controlPoint) * field.vector
            distance = simd_dot(normal, controlPointTranslation(field.controlPoint))
        }
        let height = simd_dot(position[slot], normal)
        if height < distance, field.flags & 2 != 0 {
            // 24f5e0→252140 receives System+258; +40/+48/+50 are the angular velocity SoA pointers.
            angularVelocity[slot] = .zero
        }
        bounce(slot: slot, normal: normal, height: height, floor: distance, field, weight)
    }

    /// [I] The sphere repels from outside: the plane rule on the tangent plane under the particle.
    mutating func applyCollisionSphere(_ field: WPEParityParticleCollision, slot: Int, weight: Float) {
        let center = field.flags & 1 != 0 ? controlPointTranslation(field.controlPoint) : field.vector
        let offset = position[slot] - center
        let distance = simd_length(offset)
        guard distance > 0 else { return }
        bounce(slot: slot, normal: offset / distance, height: distance, floor: field.scalar, field, weight)
    }

    private mutating func bounce(
        slot: Int, normal: SIMD3<Float>, height: Float, floor: Float, _ field: WPEParityParticleCollision,
        _ weight: Float
    ) {
        guard height < floor else { return }
        position[slot] -= (height - floor) * normal * weight
        velocity[slot] += field.bounce * simd_dot(velocity[slot], normal) * normal * weight
    }
}
