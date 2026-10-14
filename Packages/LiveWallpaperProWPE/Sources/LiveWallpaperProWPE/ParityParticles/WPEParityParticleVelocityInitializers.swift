import simd

extension WPEParityParticleSystem {
    /// 23bc32..23bdb7: current/history CP translations, previous global dt, optional world→update basis,
    /// one shared MT word, the emitter's birth 3×3, then add to the newborn's velocity. Zero dt is not clamped.
    mutating func initializeControlPointVelocity(_ point: Int, minimum: Float, maximum: Float, slot: Int,
                                                 birthBasis: simd_float3x3) {
        var delta = (controlPointTranslation(point) - previousControlPointTranslation(point))
            / frameContext.previousFrametime
        if frameContext.worldSpace, config.controlPoints[point].flags & 2 == 0 {
            let transformed = frameContext.objectMatrix.inverse * SIMD4(delta, 0)
            delta = SIMD3(transformed.x, transformed.y, transformed.z)
        }
        let scale = rng.unit() * (maximum - minimum) + minimum
        let value = delta * scale
        // 184440's actual ADDSS/ADDPS order, avoiding a second matrix or a guessed blend helper.
        let first = birthBasis.columns.0 * value.x
        let second = birthBasis.columns.1 * value.y
        let third = birthBasis.columns.2 * value.z
        velocity[slot] += SIMD3((second.x + first.x) + third.x,
                                (first.y + second.y) + third.y,
                                (first.z + second.z) + third.z)
    }
}
