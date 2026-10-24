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

/// Operator weight when blendin*/blendout* keys are present (1401c2a40.c:23-148).
/// The defaults keep each ramp at 1 over t ∈ [0, 1] for an operator that authors only one side.
struct WPEParityParticleBlend: Equatable, Sendable {
    var inStart: Float = -1
    var inEnd: Float = 0
    var outStart: Float = 1
    var outEnd: Float = 2

    /// 1c2a40 compiles 0/0 and 1/1 defaults, widens ramps, then conditionally changes the operator opcode.
    static func compiled(inStart: Float, inEnd: Float, outStart: Float, outEnd: Float) -> Self? {
        let epsilon = Float(bitPattern: 0x38D1_B717)
        var inStart = inStart, outEnd = outEnd
        if inStart > inEnd - epsilon {
            inStart = inEnd - epsilon
        }
        if !(outEnd > outStart + epsilon) {
            outEnd = outStart + epsilon
        }
        let threshold = Float(bitPattern: 0x3C23_D70A)
        guard inEnd > threshold || outStart < Float(bitPattern: 0x3F7D_70A4),
              outStart - inEnd > threshold || inEnd - inStart > threshold || outEnd - outStart > threshold
        else { return nil }
        return Self(inStart: inStart, inEnd: inEnd, outStart: outStart, outEnd: outEnd)
    }

    func weight(t: Float) -> Float {
        WPEParityParticleMath.saturate((t - inStart) / (inEnd - inStart))
            * WPEParityParticleMath.saturate((outEnd - t) / (outEnd - outStart))
    }
}

enum WPEParityParticleMath {
    /// Separate sinf/cosf calls, as WPE makes. Inlined, -O fuses a sin/cos pair of one angle into
    /// __sincosf_stret, which rounds some inputs differently, so Debug and Release particles diverge.
    @inline(never) static func sin(_ x: Float) -> Float {
        sinf(x)
    }

    @inline(never) static func cos(_ x: Float) -> Float {
        cosf(x)
    }

    /// NaN (a zero-width ramp hit exactly at its start) maps to 0, as SSE maxss(x, 0) does.
    static func saturate(_ value: Float) -> Float {
        value > 0 ? min(value, 1) : 0
    }

    /// v' = (v + g·dt)·(1 − min(drag·dragDt, 0.9999999)), p' = p + (v + g·dt)·dt (14023fbc0.c:1464-1572).
    static func move(
        position: inout SIMD3<Float>, velocity: inout SIMD3<Float>,
        acceleration: SIMD3<Float>, drag: Float, dt: Float, dragDt: Float? = nil
    ) {
        let accelerated = velocity + acceleration * dt
        position += accelerated * dt
        velocity = accelerated * (1 - min(drag * (dragDt ?? dt), 0.999_999_9))
    }

    /// 140236cd0.c:363-371: drag alone runs on dt·powf(min(0.025/frametime, 1), 0.7).
    static func dragStep(dt: Float, frametime: Float?) -> Float {
        guard let frametime else { return dt }
        return powf(min(0.025 / frametime, 1), 0.7) * dt
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
        let base: SIMD3<Float> = switch WPEAuthoredInteger.truncated(Double(wrapped), as: Int.self) ?? 0 {
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
    /// One native birth: shape, optional CP basis, position/fallback, then normalized direction and speed.
    /// A nil basis is the local CP0 branch; even a rotated CP0 contributes only its translation.
    func sample(rng: WPEParityMT19937, at center: SIMD3<Float> = .zero, basis: simd_float3x3? = nil)
        -> (position: SIMD3<Float>, velocity: SIMD3<Float>) {
        let localOffset: SIMD3<Float> = switch shape {
        case .sphere: sphereOffset(rng: rng)
        case .box: boxOffset(rng: rng)
        }
        let offset = basis.map { $0 * localOffset } ?? localOffset
        let position = center + offset
        // Sphere tests its transformed offset. Box tests what survived the Float position write/subtract
        // (2378a0:611–655, 989–1026); a large center can therefore consume three extra fallback words.
        let candidate = shape == .box ? position - center : offset
        let needsFallback = shape == .box ? simd_length(candidate) < 1e-4 : simd_length_squared(candidate) < 1e-4
        let direction: SIMD3<Float>
        if needsFallback {
            let fallback = fallbackDirection(rng: rng)
            direction = WPEParityParticleMath.normalizedOrZero(basis.map { $0 * fallback } ?? fallback)
        } else {
            direction = simd_normalize(candidate)
        }
        // scene+0x28/+0x2c is [1e-5, 1); birthU uses the separate [0, 1) distribution.
        let speed = speedMin + (speedMax - speedMin) * rng.unitAboveZero()
        return (position, direction * speed)
    }

    /// S 590288-590540; S/C taken as sin/cos.
    private func sphereOffset(rng: WPEParityMT19937) -> SIMD3<Float> {
        let phi = 2 * Float.pi * rng.unitAboveZero()
        let coneFloor = -cos(Float.pi * cone)
        let cosTheta = coneFloor + (1 - coneFloor) * rng.unit()
        let radius = cbrt(rng.unitAboveZero())
        let sinTheta = max(0, 1 - cosTheta * cosTheta).squareRoot()
        let point = radius * SIMD3(cosTheta, sinTheta * WPEParityParticleMath.sin(phi), sinTheta * WPEParityParticleMath.cos(phi)) * directions
        let length = simd_length(point)
        guard length > 0 else { return .zero }
        // The sign mask forces the unit direction's components before the distance scales it (0x140237ee0-0x140237f18).
        var unit = point / length
        for axis in 0 ..< 3 where sign[axis] != 0 {
            unit[axis] = abs(unit[axis]) * (sign[axis] > 0 ? 1 : -1)
        }
        return unit * (distanceMin.x + (distanceMax.x - distanceMin.x) * length)
    }

    /// s_i = (2U − 1)·dir_i, offset_i = sign(s_i)·(dmin_i + |s_i|·Δd_i); native draws Z, Y, X
    /// (1402385a0/5d8/610), even though the output is stored X, Y, Z.
    private func boxOffset(rng: WPEParityMT19937) -> SIMD3<Float> {
        var offset = SIMD3<Float>.zero
        for axis in (0 ..< 3).reversed() {
            let sample = (2 * rng.unitAboveZero() - 1) * directions[axis]
            let magnitude = distanceMin[axis] + abs(sample) * (distanceMax[axis] - distanceMin[axis])
            offset[axis] = sample > 0 ? magnitude : (sample < 0 ? -magnitude : 0)
        }
        return offset
    }

    private func fallbackDirection(rng: WPEParityMT19937) -> SIMD3<Float> {
        let first = 2 * rng.unitAboveZero() - 1
        let second = 2 * rng.unitAboveZero() - 1
        let third = 2 * rng.unitAboveZero() - 1
        // Sphere packs first/second/third into XYZ (238077–082); box assigns ZYX (238a43–afa).
        let vector = shape == .box ? SIMD3(third, second, first) : SIMD3(first, second, third)
        return vector * directions
    }
}
