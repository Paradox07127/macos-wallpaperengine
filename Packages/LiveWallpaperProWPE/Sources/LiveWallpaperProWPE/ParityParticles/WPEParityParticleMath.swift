import Foundation
import simd

/// Frequency / scale / phase ranges of the oscillate* operators; each particle picks its point with its birth u.
struct WPEParityParticleOscillation: Equatable, Sendable {
    var frequencyMin: Float
    var frequencyMax: Float
    var scaleMin: Float
    var scaleMax: Float
    var phaseMin: Float
    var phaseMax: Float
}

/// Operator weight when blendin*/blendout* keys are present (D/1401c2a40.c:23-148).
/// The defaults keep each ramp at 1 over t ∈ [0, 1] for an operator that authors only one side.
struct WPEParityParticleBlend: Equatable, Sendable {
    var inStart: Float = -1
    var inEnd: Float = 0
    var outStart: Float = 1
    var outEnd: Float = 2

    func weight(t: Float) -> Float {
        WPEParityParticleMath.saturate((t - inStart) / (inEnd - inStart))
            * WPEParityParticleMath.saturate((outEnd - t) / (outEnd - outStart))
    }
}

enum WPEParityParticleMath {
    /// NaN (a zero-width ramp hit exactly at its start) maps to 0, as SSE maxss(x, 0) does.
    static func saturate(_ value: Float) -> Float {
        value > 0 ? min(value, 1) : 0
    }

    /// v' = (v + g·dt)·(1 − min(drag·dt, 0.9999999)), p' = p + (v + g·dt)·dt (B/14023fbc0.c:1464-1572).
    static func move(
        position: inout SIMD3<Float>, velocity: inout SIMD3<Float>,
        acceleration: SIMD3<Float>, drag: Float, dt: Float
    ) {
        let accelerated = velocity + acceleration * dt
        position += accelerated * dt
        velocity = accelerated * (1 - min(drag * dt, 0.999_999_9))
    }

    /// Both branches true ORs the two float bit patterns (S 597117-597153).
    static func alphaFade(t: Float, fadeIn: Float, fadeOut: Float) -> Float {
        let fadingIn = t < fadeIn
        let fadingOut = t > fadeOut
        let inValue = t / fadeIn
        let outValue = (1 - t) / (1 - fadeOut)
        switch (fadingIn, fadingOut) {
        case (true, true): return Float(bitPattern: inValue.bitPattern | outValue.bitPattern)
        case (true, false): return inValue
        case (false, true): return outValue
        case (false, false): return 1
        }
    }

    /// start + (end − start)·clamp((t − st)/(et − st)) (S 597154-597235).
    static func ramp(t: Float, startTime: Float, endTime: Float, start: Float, end: Float) -> Float {
        start + (end - start) * saturate((t - startTime) / (endTime - startTime))
    }

    static func ramp(
        t: Float, startTime: Float, endTime: Float, start: SIMD3<Float>, end: SIMD3<Float>
    ) -> SIMD3<Float> {
        start + (end - start) * saturate((t - startTime) / (endTime - startTime))
    }

    /// smin + Δs·u·(sin(f·(age + φ)) + 1)·0.5, unclamped (S 597788-597863).
    static func oscillation(age: Float, u: Float, wave: WPEParityParticleOscillation) -> Float {
        let frequency = wave.frequencyMin + u * (wave.frequencyMax - wave.frequencyMin)
        let phase = wave.phaseMin + u * (wave.phaseMax - wave.phaseMin)
        return wave.scaleMin + (wave.scaleMax - wave.scaleMin) * u * (sin(frequency * (age + phase)) + 1) * 0.5
    }

    /// A·mask·[sin(fT) − sin(f(T − dt))], y phase + 2π·u (S 597236-597502).
    static func oscillationOffset(
        age: Float, dt: Float, u: Float, wave: WPEParityParticleOscillation, mask: SIMD3<Float>
    ) -> SIMD3<Float> {
        let amplitude = wave.scaleMin + u * (wave.scaleMax - wave.scaleMin)
        let frequency = wave.frequencyMin + u * (wave.frequencyMax - wave.frequencyMin)
        let time = age + wave.phaseMin + u * (wave.phaseMax - wave.phaseMin)
        let timeY = time + 2 * .pi * u
        let swingXZ = sin(frequency * time) - sin(frequency * (time - dt))
        let swingY = sin(frequency * timeY) - sin(frequency * (timeY - dt))
        return amplitude * mask * SIMD3(swingXZ, swingY, swingXZ)
    }

    static func normalizedOrZero(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(value)
        return lengthSquared > 0 ? value / lengthSquared.squareRoot() : .zero
    }

    static func hsvToRGB(hue: Float, saturation: Float, value: Float) -> SIMD3<Float> {
        let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
        let wrapped = sector < 0 ? sector + 6 : sector
        let chroma = value * saturation
        let x = chroma * (1 - abs(wrapped.truncatingRemainder(dividingBy: 2) - 1))
        let base: SIMD3<Float> = switch Int(wrapped) {
        case 0: SIMD3(chroma, x, 0)
        case 1: SIMD3(x, chroma, 0)
        case 2: SIMD3(0, chroma, x)
        case 3: SIMD3(0, x, chroma)
        case 4: SIMD3(x, 0, chroma)
        default: SIMD3(chroma, 0, x)
        }
        return base + (value - chroma)
    }

    /// Hue in turns [0, 1); grey maps to hue 0, saturation 0.
    static func rgbToHSV(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let high = rgb.max(), chroma = high - rgb.min()
        guard chroma > 0 else { return SIMD3(0, 0, high) }
        var hue: Float = if high == rgb.x {
            (rgb.y - rgb.z) / chroma
        } else if high == rgb.y {
            (rgb.z - rgb.x) / chroma + 2
        } else {
            (rgb.x - rgb.y) / chroma + 4
        }
        hue /= 6
        return SIMD3(hue < 0 ? hue + 1 : hue, chroma / high, high)
    }
}

extension WPEParityParticleEmitterConfig {
    /// Offset from the emitter origin and the launch velocity of one birth.
    func sample(rng: WPEParityMT19937) -> (offset: SIMD3<Float>, velocity: SIMD3<Float>) {
        let offset: SIMD3<Float>
        let direction: SIMD3<Float>
        switch shape {
        case .sphere:
            offset = sphereOffset(rng: rng)
            // |offset|² < 1e-4 launches along (2U − 1)³ ⊙ directions (D/1401b9100.c:62-155).
            direction = simd_length_squared(offset) < 1e-4 ? fallbackDirection(rng: rng) : simd_normalize(offset)
        case .box:
            offset = boxOffset(rng: rng)
            direction = simd_length(offset) < 1e-4 ? fallbackDirection(rng: rng) : simd_normalize(offset)
        }
        let speed = speedMin + (speedMax - speedMin) * rng.unit()
        return (offset, direction * speed)
    }

    /// S 590288-590540; S/C taken as sin/cos.
    private func sphereOffset(rng: WPEParityMT19937) -> SIMD3<Float> {
        let phi = 2 * Float.pi * rng.unitAboveZero()
        let coneFloor = -cos(Float.pi * cone)
        let cosTheta = coneFloor + (1 - coneFloor) * rng.unit()
        let radius = cbrt(rng.unitAboveZero())
        let sinTheta = max(0, 1 - cosTheta * cosTheta).squareRoot()
        let point = radius * SIMD3(cosTheta, sinTheta * sin(phi), sinTheta * cos(phi)) * directions
        let length = simd_length(point)
        guard length > 0 else { return .zero }
        // The sign mask forces the unit direction's components before the distance scales it (0x140237ee0-0x140237f18).
        var unit = point / length
        for axis in 0 ..< 3 where sign[axis] != 0 {
            unit[axis] = abs(unit[axis]) * (sign[axis] > 0 ? 1 : -1)
        }
        return unit * (distanceMin.x + (distanceMax.x - distanceMin.x) * length)
    }

    /// s_i = (2U − 1)·dir_i, offset_i = sign(s_i)·(dmin_i + |s_i|·Δd_i) (D/1402378a0.c:811-1061).
    private func boxOffset(rng: WPEParityMT19937) -> SIMD3<Float> {
        var offset = SIMD3<Float>.zero
        for axis in 0 ..< 3 {
            let sample = (2 * rng.unit() - 1) * directions[axis]
            let magnitude = distanceMin[axis] + abs(sample) * (distanceMax[axis] - distanceMin[axis])
            offset[axis] = sample > 0 ? magnitude : (sample < 0 ? -magnitude : 0)
        }
        return offset
    }

    private func fallbackDirection(rng: WPEParityMT19937) -> SIMD3<Float> {
        let x = 2 * rng.unit() - 1
        let y = 2 * rng.unit() - 1
        let z = 2 * rng.unit() - 1
        return WPEParityParticleMath.normalizedOrZero(SIMD3(x, y, z) * directions)
    }
}
