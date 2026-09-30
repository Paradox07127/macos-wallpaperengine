#if !LITE_BUILD
import Foundation

/// Scoped to its owning system. Recycling a slot must not retarget an old follower.
struct WPEParticleIdentity: Hashable, Codable, Sendable {
    let slot: Int
    let generation: UInt64
}

/// Both simulation and presentation values are explicit; consumers must choose
/// a coordinate/value contract rather than silently mixing the two.
struct WPEParticleSnapshot: Equatable, Sendable {
    let identity: WPEParticleIdentity
    let position: SIMD3<Float>
    let displayPosition: SIMD3<Float>
    let velocity: SIMD3<Float>
    let initialColor: SIMD3<Float>
    let currentColor: SIMD3<Float>
    let initialAlpha: Float
    let currentAlpha: Float
    let initialSize: Float
    let currentSize: Float
    let rotationZ: Float
    let age: Float
    let lifetime: Float
}

struct WPEParticleEvent: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case spawn, death }
    let kind: Kind
    /// Current simulator substep-end clock; exact lifetime crossing still needs
    /// its own integration contract. This timestamp is not a wall-clock event.
    let simulationTime: Double
    let particle: WPEParticleSnapshot
}
#endif
