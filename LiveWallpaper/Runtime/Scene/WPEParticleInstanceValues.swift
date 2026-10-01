#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

enum WPEParticleInstanceProperty: String, CaseIterable, Sendable {
    case alpha, size, count, speed, lifetime, rate, colorn
    case controlpoint0, controlpoint1, controlpoint2, controlpoint3
    case controlpoint4, controlpoint5, controlpoint6, controlpoint7

    var controlPointIndex: Int? {
        Int(rawValue.replacingOccurrences(of: "controlpoint", with: ""))
    }

    var isVector: Bool {
        self == .colorn || controlPointIndex != nil
    }
}

struct WPEParticleInstanceMutation: Equatable, Sendable {
    let property: WPEParticleInstanceProperty
    /// Scalars use x; vectors retain all three authored components.
    let value: SIMD3<Double>
}

struct WPEParticleInstanceValues: Equatable, Sendable {
    var alpha: Double = 1
    var size: Double = 1
    var count: Double = 1
    var speed: Double = 1
    var lifetime: Double = 1
    var rate: Double = 1
    /// 0…1 per channel. Authored `instanceoverride.colorn` multiplies the sampled colour; only a script write replaces it.
    var colorn = SIMD3<Double>(repeating: 1)
    var replacesColor = false
    var controlPoints: [Int: SIMD3<Double>] = [:]

    init(override: WPESceneParticleInstanceOverride? = nil) {
        guard let override else { return }
        // The keyframed alpha is applied per frame at draw time; seeding it here would multiply it twice.
        alpha = override.alphaAnimation != nil ? 1 : override.alpha ?? 1
        size = override.size ?? 1
        count = override.count ?? 1
        speed = override.speed ?? 1
        lifetime = override.lifetime ?? 1
        rate = override.rate ?? 1
        if let color = override.color {
            colorn = color / 255
        }
        controlPoints = override.controlPointOffsets
    }

    func value(for property: WPEParticleInstanceProperty) -> SIMD3<Double> {
        if let index = property.controlPointIndex {
            return controlPoints[index] ?? .zero
        }
        switch property {
        case .alpha: return SIMD3(repeating: alpha)
        case .size: return SIMD3(repeating: size)
        case .count: return SIMD3(repeating: count)
        case .speed: return SIMD3(repeating: speed)
        case .lifetime: return SIMD3(repeating: lifetime)
        case .rate: return SIMD3(repeating: rate)
        default: return colorn
        }
    }

    mutating func apply(_ mutation: WPEParticleInstanceMutation) {
        if let index = mutation.property.controlPointIndex {
            controlPoints[index] = mutation.value
            return
        }
        let scalar = max(0, mutation.value.x)
        switch mutation.property {
        case .alpha: alpha = scalar
        case .size: size = scalar
        case .count: count = scalar
        case .speed: speed = scalar
        case .lifetime: lifetime = scalar
        case .rate: rate = scalar
        case .colorn: colorn = mutation.value; replacesColor = true
        default: break
        }
    }
}
#endif
