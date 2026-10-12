/// GS-path vertex packing, g_RenderVar0 and combos per renderer entry (R16 Q1-Q3).
public extension WPEParityParticleSystem {
    var shaderOverride: String? {
        Self.shaderOverride(renderers: renderers)
    }

    /// Bytes are rewritten in place each call and stay valid until the next call for the same buffer.
    mutating func vertices(for renderer: WPEParityParticleRenderer) -> WPEParityParticleVertexBatch {
        switch renderer.kind {
        case .sprite, .spriteTrail:
            let stride = usesThickMainBuffer ? 60 : 44
            packMain(stride: stride)
            // spritetrail RV0 = (length, maxlength, minlength, kept) (D/1401c0af0.c:15-47).
            let renderVar0 = renderer.kind == .spriteTrail
                ? WPEParityRenderVar0(x: renderer.length, y: renderer.maxLength, z: renderer.minLength)
                : WPEParityRenderVar0()
            return WPEParityParticleVertexBatch(bytes: mainBytes, stride: stride, count: liveCount, renderVar0: renderVar0)
        case .rope:
            let count = packRope()
            return WPEParityParticleVertexBatch(
                bytes: ropeBytes, stride: 96, count: count, renderVar0: WPEParityRenderVar0(z: 0, w: Float(liveCount))
            )
        case .ropeTrail:
            let segments = Float(renderer.segments)
            packRopeTrail(renderer)
            // z = 1 − timer/(length/segments); uvscrolling writes x and scales w (R16 Q3, :115-129).
            let z = trailInterval > 0 ? 1 - max(trailTimer, 0) / trailInterval : 1
            let renderVar0 = renderer.uvScrolling
                ? WPEParityRenderVar0(x: segments - 1, z: z, w: (segments - 1) * renderer.uvScale)
                : WPEParityRenderVar0(z: z, w: segments - 0.5)
            return WPEParityParticleVertexBatch(
                bytes: ropeTrailBytes, stride: 76, count: liveCount * renderer.segments, renderVar0: renderVar0
            )
        }
    }

    func combos(for renderer: WPEParityParticleRenderer) -> [String: Int] {
        Self.combos(config: config, material: material, renderer: renderer)
    }
}

extension WPEParityParticleSystem {
    /// A system whose only renderers are `rope` draws with genericropeparticle (B/1401c5490.c:10109-10116).
    static func shaderOverride(renderers: [WPEParityParticleRenderer]) -> String? {
        !renderers.isEmpty && renderers.allSatisfy { $0.kind == .rope } ? "genericropeparticle" : nil
    }

    /// Sprite and spritetrail share one main VB; it is thick when any spritetrail or a spritesheet is present.
    static func usesThickMainBuffer(config: WPEParityParticleConfig, material: WPEParityParticleMaterial) -> Bool {
        material.spriteSheet || config.renderers.contains { $0.kind == .spriteTrail }
    }

    /// Combo values FUN_1401d2340 writes for this entry (R16 Q1).
    static func combos(config: WPEParityParticleConfig, material: WPEParityParticleMaterial,
                       renderer: WPEParityParticleRenderer) -> [String: Int] {
        var combos: [String: Int] = [:]
        switch renderer.kind {
        case .sprite:
            if usesThickMainBuffer(config: config, material: material) {
                combos["THICKFORMAT"] = 1
            }
        case .spriteTrail:
            combos["THICKFORMAT"] = 1
            combos["TRAILRENDERER"] = 1
        case .rope:
            combos["THICKFORMAT"] = 1
            combos["TRAILSUBDIVISION"] = renderer.subdivision
            combos["ORIENTATION"] = renderer.orientation
        case .ropeTrail:
            combos["TRAILRENDERER"] = 1
            combos["TRAILSUBDIVISION"] = renderer.subdivision
            combos["ORIENTATION"] = renderer.orientation
            if renderer.uvScrolling {
                combos["TRAILSCROLLALPHA"] = 1
            }
            if renderer.fadeAlpha {
                combos["TRAILFADEALPHA"] = 1
            }
            if renderer.fadeSize {
                combos["TRAILFADESIZE"] = 1
            }
        }
        if material.spriteSheet, renderer.kind == .sprite || renderer.kind == .spriteTrail {
            combos["SPRITESHEET"] = 1
            // !(flags & 2) && def[0xc] == 0, def[0xc] read as "not randomframe" [I] (:129-140).
            if config.flags & 2 == 0, !config.randomFrame {
                combos["SPRITESHEETBLEND"] = 1
                combos["SPRITESHEETBLENDNPOT"] = material.spriteSheetNPOT ? 1 : 0
            }
        }
        if let format = material.texture0Format, (8 ... 11).contains(format) {
            combos["TEX0FORMAT"] = format
        }
        return combos
    }

    var usesThickMainBuffer: Bool {
        Self.usesThickMainBuffer(config: config, material: material)
    }

    /// POSITION f3 | TEXCOORD0 (rot, size) | [TEXCOORD1 (vel, life)] | COLOR, live slots in slot order.
    private mutating func packMain(stride: Int) {
        var bytes = mainBytes
        mainBytes = []
        Self.resize(&bytes, to: liveCount * stride)
        let thick = stride == 60
        bytes.withUnsafeMutableBytes { raw in
            var writer = WPEParityVertexWriter(raw: raw)
            for slot in 0 ..< highWater where lifetime[slot] != 0 {
                writer.put(position[slot])
                writer.put(rotation[slot], size[slot])
                if thick {
                    writer.put(velocity[slot], config.randomFrame ? frame[slot] : age[slot] / lifetime[slot])
                }
                writer.put(color[slot] * instance.brightness, alpha[slot])
            }
        }
        mainBytes = bytes
    }

    /// One vertex per neighbour pair in birth order: (p, size) | (p_next, live) | (p_prev, k) | (p_next2, size_next)
    /// | colour_next | colour [I: field meaning from genericropeparticle.vert].
    private mutating func packRope() -> Int {
        let count = max(liveCount - 1, 0)
        var bytes = ropeBytes
        ropeBytes = []
        Self.resize(&bytes, to: count * 96)
        bytes.withUnsafeMutableBytes { raw in
            var writer = WPEParityVertexWriter(raw: raw)
            var previous = Int(birthHead)
            var current = Int(birthHead)
            var index: Float = 0
            while current >= 0, birthNext[current] >= 0 {
                let next = Int(birthNext[current])
                let afterNext = birthNext[next] >= 0 ? Int(birthNext[next]) : next
                writer.put(position[current], size[current])
                writer.put(position[next], Float(liveCount))
                writer.put(position[previous], index)
                writer.put(position[afterNext], size[next])
                writer.put(color[next] * instance.brightness, alpha[next])
                writer.put(color[current] * instance.brightness, alpha[current])
                previous = current
                current = next
                index += 1
            }
        }
        ropeBytes = bytes
        return count
    }

    /// `segments` vertices per live slot through [current, history newest → oldest]:
    /// (P_j, size) | (P_j+1, pushed count or j when scrolling) | (P_j−1, j) | P_j+2 f3 | colour.
    private mutating func packRopeTrail(_ renderer: WPEParityParticleRenderer) {
        let segments = renderer.segments
        var bytes = ropeTrailBytes
        ropeTrailBytes = []
        Self.resize(&bytes, to: liveCount * segments * 76)
        bytes.withUnsafeMutableBytes { raw in
            var writer = WPEParityVertexWriter(raw: raw)
            for slot in 0 ..< highWater where lifetime[slot] != 0 {
                let pushed = trailSegments > 0 ? Int(trailCount[slot]) : 0
                for index in 0 ..< segments {
                    writer.put(trailPoint(slot, index, pushed: pushed), size[slot])
                    writer.put(
                        trailPoint(slot, index + 1, pushed: pushed),
                        renderer.uvScrolling ? Float(index) : Float(pushed)
                    )
                    writer.put(trailPoint(slot, index - 1, pushed: pushed), Float(index))
                    writer.put(trailPoint(slot, index + 2, pushed: pushed))
                    writer.put(color[slot] * instance.brightness, alpha[slot])
                }
            }
        }
        ropeTrailBytes = bytes
    }

    /// Point 0 is the live position, point k the k-th newest pushed sample, clamped to the oldest pushed.
    private func trailPoint(_ slot: Int, _ index: Int, pushed: Int) -> SIMD3<Float> {
        let point = min(max(index, 0), pushed)
        guard point > 0 else { return position[slot] }
        let ring = (Int(trailHead[slot]) - (point - 1) + trailSegments) % trailSegments
        return trailPoints[slot * trailSegments + ring]
    }

    /// Keeps the array's capacity so steady-state frames do not reallocate.
    private static func resize(_ bytes: inout [UInt8], to count: Int) {
        if bytes.count > count {
            bytes.removeLast(bytes.count - count)
        } else if bytes.count < count {
            bytes.append(contentsOf: repeatElement(0, count: count - bytes.count))
        }
    }
}

struct WPEParityVertexWriter {
    let raw: UnsafeMutableRawBufferPointer
    var offset = 0

    mutating func put(_ value: Float) {
        raw.storeBytes(of: value, toByteOffset: offset, as: Float.self)
        offset += 4
    }

    mutating func put(_ value: SIMD3<Float>) {
        put(value.x)
        put(value.y)
        put(value.z)
    }

    mutating func put(_ value: SIMD3<Float>, _ w: Float) {
        put(value)
        put(w)
    }
}
