#if !LITE_BUILD
import Foundation
import simd

struct WPEParticleCPUState: Sendable {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var speedScale: Float
    var size: Float
    var color: SIMD3<Float>
    var rotationZ: Float
    var angularVelocityZ: Float
    var alphaBase: Float
    var lifetime: Float
    var age: Float
    var turbulenceSpeed: Float
    var turbulencePhase: Float
    var staticFrame: Float
    var oscPosFrequency: Float
    var oscPosScale: Float
    var oscPosPhase: Float
    var oscAlphaFrequency: Float
    var oscAlphaPhase: Float
    var oscSizeFrequency: Float
    var oscSizePhase: Float

    static let inactive = Self(
        position: .zero, velocity: .zero, speedScale: 1, size: 0, color: SIMD3(1, 1, 1),
        rotationZ: 0, angularVelocityZ: 0, alphaBase: 1, lifetime: 0, age: .greatestFiniteMagnitude,
        turbulenceSpeed: 0, turbulencePhase: 0, staticFrame: 0,
        oscPosFrequency: 0, oscPosScale: 0, oscPosPhase: 0,
        oscAlphaFrequency: 0, oscAlphaPhase: 0, oscSizeFrequency: 0, oscSizePhase: 0
    )
}

final class WPEParticleCPUStorage {
    struct Key: Hashable {
        let capacity: Int
        let trailSamples: Int
    }

    let key: Key
    var particles: [WPEParticleCPUState]
    var generations: [UInt64]
    var liveSlots: WPEParticleSlotIndex
    var trailSamples: [SIMD2<Float>]
    var trailHeads: [Int]
    var trailFills: [Int]

    var payloadBytes: Int {
        key.capacity * (MemoryLayout<WPEParticleCPUState>.stride + MemoryLayout<UInt64>.stride)
            + liveSlots.wordCount * MemoryLayout<UInt64>.stride
            + trailSamples.count * MemoryLayout<SIMD2<Float>>.stride
            + (trailHeads.count + trailFills.count) * MemoryLayout<Int>.stride
    }

    init(key: Key) {
        self.key = key
        particles = .init(repeating: .inactive, count: key.capacity)
        generations = .init(repeating: 0, count: key.capacity)
        liveSlots = .init(capacity: key.capacity)
        trailSamples = .init(repeating: .zero, count: key.capacity * key.trailSamples)
        trailHeads = .init(repeating: 0, count: key.trailSamples > 0 ? key.capacity : 0)
        trailFills = .init(repeating: 0, count: trailHeads.count)
    }

    func reset() {
        particles.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.update(repeating: .inactive, count: buffer.count)
        }
        generations.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.update(repeating: 0, count: buffer.count)
        }
        liveSlots.removeAll()
        trailSamples.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.update(repeating: .zero, count: buffer.count)
        }
        trailHeads.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.update(repeating: 0, count: buffer.count)
        }
        trailFills.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.update(repeating: 0, count: buffer.count)
        }
    }
}

final class WPEParticleCPUStoragePool {
    struct Stats {
        let allocations: Int
        let reuses: Int
        let retainedBytes: Int
        let retainedStorages: Int
    }

    let maximumRetainedBytes: Int
    // ARC may release the last system reference outside its display actor.
    private let lock = NSLock()
    private var free: [WPEParticleCPUStorage.Key: [WPEParticleCPUStorage]] = [:]
    private var retainedBytes = 0
    private var allocations = 0
    private var reuses = 0

    init(maximumRetainedBytes: Int = 16 * 1024 * 1024) {
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
    }

    var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return .init(allocations: allocations, reuses: reuses, retainedBytes: retainedBytes,
                     retainedStorages: free.values.reduce(0) { $0 + $1.count })
    }

    func acquire(_ key: WPEParticleCPUStorage.Key) -> WPEParticleCPUStorage {
        lock.lock()
        if let storage = free[key]?.popLast() {
            retainedBytes -= storage.payloadBytes
            reuses += 1
            if free[key]?.isEmpty == true {
                free[key] = nil
            }
            lock.unlock()
            storage.reset()
            return storage
        }
        allocations += 1
        lock.unlock()
        return .init(key: key)
    }

    /// Only the owning system's deinit may return its storage.
    func recycle(_ storage: WPEParticleCPUStorage) {
        let bytes = storage.payloadBytes
        lock.lock()
        if bytes <= maximumRetainedBytes - retainedBytes {
            free[storage.key, default: []].append(storage)
            retainedBytes += bytes
        }
        lock.unlock()
    }

    func trim() {
        lock.lock()
        let released = free
        free = [:]
        retainedBytes = 0
        lock.unlock()
        withExtendedLifetime(released) {}
    }
}
#endif
