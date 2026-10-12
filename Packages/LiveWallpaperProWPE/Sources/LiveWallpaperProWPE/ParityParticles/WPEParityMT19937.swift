/// std::mt19937 that WPE keeps once per scene (R18 RNG, D/14017c6d0.c:557-632).
/// A class, not Sendable: every particle system of a scene draws from this one stream in WPE's order.
public final class WPEParityMT19937 {
    private static let size = 624
    private var state = [UInt32](repeating: 0, count: WPEParityMT19937.size)
    private var index = WPEParityMT19937.size

    public init(seed: UInt32 = 5489) {
        reseed(seed)
    }

    public func reseed(_ seed: UInt32) {
        state[0] = seed
        for i in 1 ..< Self.size {
            let previous = state[i - 1]
            state[i] = 1_812_433_253 &* (previous ^ (previous >> 30)) &+ UInt32(i)
        }
        index = Self.size
    }

    public func next() -> UInt32 {
        if index >= Self.size {
            twist()
        }
        var value = state[index]
        index += 1
        value ^= value >> 11
        value ^= (value << 7) & 0x9D2C_5680
        value ^= (value << 15) & 0xEFC6_0000
        value ^= value >> 18
        return value
    }

    /// a + (b − a)·(x >> 8)·2⁻²⁴ (D/14017c6d0.c:20-23).
    public func draw(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * (Float(next() >> 8) * 0x1p-24)
    }

    /// [0, 1).
    public func unit() -> Float {
        draw(0, 1)
    }

    /// [1e-5, 1), the range the emitters use for φ and the sphere radius (D/1402378a0.c:851-853).
    public func unitAboveZero() -> Float {
        draw(1e-5, 1)
    }

    private func twist() {
        for i in 0 ..< Self.size {
            let bits = (state[i] & 0x8000_0000) | (state[(i + 1) % Self.size] & 0x7FFF_FFFF)
            var value = state[(i + 397) % Self.size] ^ (bits >> 1)
            if bits & 1 != 0 {
                value ^= 0x9908_B0DF
            }
            state[i] = value
        }
        index = 0
    }
}
