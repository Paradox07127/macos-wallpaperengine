import simd

/// Gustavson simplex noise as WPE 2.8.42 evaluates it (R19 噪声): 3D for turbulence, 2D for
/// positionoffsetrandom, 1D for turbulentvelocityrandom. 1D/2D hash gradients follow D/14027b090.c and D/14027b170.c.
enum WPEParityParticleNoise {
    /// Ken Perlin's reference permutation.
    private static let permutation: [UInt8] = [
        151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142,
        8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117,
        35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71,
        134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41,
        55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89,
        18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226,
        250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182,
        189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43,
        172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97,
        228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107,
        49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138,
        236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
    ]

    private static let gradients3: [SIMD3<Float>] = [
        SIMD3(1, 1, 0), SIMD3(-1, 1, 0), SIMD3(1, -1, 0), SIMD3(-1, -1, 0),
        SIMD3(1, 0, 1), SIMD3(-1, 0, 1), SIMD3(1, 0, -1), SIMD3(-1, 0, -1),
        SIMD3(0, 1, 1), SIMD3(0, -1, 1), SIMD3(0, 1, -1), SIMD3(0, -1, -1),
    ]

    private static func hash(_ index: Int) -> Int {
        Int(permutation[index & 255])
    }

    private static func lattice(_ value: Float) -> Int {
        let truncated = Int(value)
        return Float(truncated) <= value ? truncated : truncated - 1
    }

    /// ×0.395, falloff (1 − x²)⁴, gradient ±(1 + h&7).
    static func simplex1(_ x: Float) -> Float {
        let cell = lattice(x)
        let x0 = x - Float(cell)
        let x1 = x0 - 1
        func corner(_ hashed: Int, _ offset: Float) -> Float {
            let gradient = Float(1 + (hashed & 7))
            let falloff = (1 - offset * offset) * (1 - offset * offset)
            return falloff * falloff * (hashed & 8 != 0 ? -gradient : gradient) * offset
        }
        return 0.395 * (corner(hash(cell), x0) + corner(hash(cell + 1), x1))
    }

    /// ×45.23065, falloff (0.5 − r²)⁴, gradient (±u) + (±2v) picked by h&0x3F.
    static func simplex2(_ x: Float, _ y: Float) -> Float {
        let f2: Float = 0.366_025_403
        let g2: Float = 0.211_324_865
        let skew = (x + y) * f2
        let i = lattice(x + skew)
        let j = lattice(y + skew)
        let unskew = Float(i + j) * g2
        let x0 = x - (Float(i) - unskew)
        let y0 = y - (Float(j) - unskew)
        let (i1, j1) = x0 > y0 ? (1, 0) : (0, 1)
        func corner(_ hashed: Int, _ cx: Float, _ cy: Float) -> Float {
            let falloff = 0.5 - cx * cx - cy * cy
            guard falloff >= 0 else { return 0 }
            let h = hashed & 0x3F
            let (u, v) = h < 4 ? (cx, cy) : (cy, cx)
            let gradient = (h & 1 != 0 ? -u : u) + (h & 2 != 0 ? -2 * v : 2 * v)
            return falloff * falloff * falloff * falloff * gradient
        }
        let n0 = corner(hash(i + hash(j)), x0, y0)
        let n1 = corner(hash(i + i1 + hash(j + j1)), x0 - Float(i1) + g2, y0 - Float(j1) + g2)
        let n2 = corner(hash(i + 1 + hash(j + 1)), x0 - 1 + 2 * g2, y0 - 1 + 2 * g2)
        return 45.230_65 * (n0 + n1 + n2)
    }

    /// ×32, falloff (0.6 − r²)⁴, the 12 cube-edge gradients through perm mod 12.
    static func simplex3(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let f3: Float = 1.0 / 3.0
        let g3: Float = 1.0 / 6.0
        let skew = (x + y + z) * f3
        let i = lattice(x + skew), j = lattice(y + skew), k = lattice(z + skew)
        let unskew = Float(i + j + k) * g3
        let p0 = SIMD3(x - (Float(i) - unskew), y - (Float(j) - unskew), z - (Float(k) - unskew))
        let first: SIMD3<Int>, second: SIMD3<Int>
        if p0.x >= p0.y {
            if p0.y >= p0.z {
                (first, second) = (SIMD3(1, 0, 0), SIMD3(1, 1, 0))
            } else if p0.x >= p0.z {
                (first, second) = (SIMD3(1, 0, 0), SIMD3(1, 0, 1))
            } else {
                (first, second) = (SIMD3(0, 0, 1), SIMD3(1, 0, 1))
            }
        } else if p0.y < p0.z {
            (first, second) = (SIMD3(0, 0, 1), SIMD3(0, 1, 1))
        } else if p0.x < p0.z {
            (first, second) = (SIMD3(0, 1, 0), SIMD3(0, 1, 1))
        } else {
            (first, second) = (SIMD3(0, 1, 0), SIMD3(1, 1, 0))
        }
        func corner(_ offset: SIMD3<Int>, _ point: SIMD3<Float>) -> Float {
            let falloff = 0.6 - simd_length_squared(point)
            guard falloff >= 0 else { return 0 }
            let index = hash(i + offset.x + hash(j + offset.y + hash(k + offset.z))) % 12
            return falloff * falloff * falloff * falloff * simd_dot(gradients3[index], point)
        }
        let n0 = corner(.zero, p0)
        let n1 = corner(first, p0 - SIMD3<Float>(first) + g3)
        let n2 = corner(second, p0 - SIMD3<Float>(second) + 2 * g3)
        let n3 = corner(SIMD3(1, 1, 1), p0 - 1 + 3 * g3)
        return 32 * (n0 + n1 + n2 + n3)
    }
}
