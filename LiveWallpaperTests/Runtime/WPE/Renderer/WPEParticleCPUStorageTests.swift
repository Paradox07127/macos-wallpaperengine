import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Particle CPU storage reuse")
struct WPEParticleCPUStorageTests {
    private func definition(renderer: String = "sprite", capacity: Int = 16) -> WPEParticleDefinition {
        WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": capacity,
            "emitter": [["name": "boxrandom", "instantaneous": 5, "rate": 12,
                         "distancemax": "2 2 0"]],
            "initializer": [["name": "lifetimerandom", "min": 0.3, "max": 1],
                            ["name": "velocityrandom", "min": "-2 -1 0", "max": "3 2 0"]],
            "renderer": [["name": renderer, "subdivision": 3]],
        ])
    }

    private func system(_ device: MTLDevice, definition: WPEParticleDefinition, seed: UInt64 = 1,
                        pool: WPEParticleCPUStoragePool?) throws -> WPEParticleSystem {
        try #require(WPEParticleSystem(definition: definition, device: device, seed: seed, cpuStoragePool: pool))
    }

    @Test("Retained old instances keep their storage; only deinit returns it")
    func retainedIdentityAndReset() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEParticleCPUStoragePool(maximumRetainedBytes: 1024 * 1024)
        let prototype = try system(device, definition: definition(), pool: pool)
        var old = prototype.makeEventInstance(device: device, seed: 2)
        weak var weakOld = old
        let oldStorage = try #require(old).cpuStorageIdentity
        old?.tick(now: 0)
        old?.tick(now: 0.1)
        let oldIdentity = try #require(old?.primaryLiveParticleIdentity)
        let oldSnapshot = try #require(old?.snapshot(for: oldIdentity))
        var other = prototype.makeEventInstance(device: device, seed: 3)
        #expect(other?.cpuStorageIdentity != oldStorage)
        other?.tick(now: 0)
        other?.tick(now: 0.2)
        #expect(old?.snapshot(for: oldIdentity)?.position == oldSnapshot.position)
        withExtendedLifetime(other) {}
        other = nil
        #expect(pool.stats.retainedStorages == 1)
        withExtendedLifetime(old) {}
        old = nil
        #expect(weakOld == nil)
        #expect(pool.stats.retainedStorages == 2)
        let reused = try #require(prototype.makeEventInstance(device: device, seed: 77))
        #expect(reused.cpuStorageIdentity == oldStorage)
        #expect(reused.liveInstanceCount == 0 && reused.primaryLiveParticleIdentity == nil)
        #expect(pool.stats.reuses == 1)
        let fresh = try system(device, definition: definition(), seed: 77, pool: nil)
        for frame in 0 ... 120 {
            reused.tick(now: Double(frame) / 60)
            fresh.tick(now: Double(frame) / 60)
            #expect(reused.primaryLiveParticleIdentity == fresh.primaryLiveParticleIdentity)
            if let identity = fresh.primaryLiveParticleIdentity {
                #expect(reused.snapshot(for: identity)?.position == fresh.snapshot(for: identity)?.position)
            }
        }
        pool.trim()
        #expect(pool.stats.retainedBytes == 0 && pool.stats.retainedStorages == 0)
        #expect(reused.liveInstanceCount == fresh.liveInstanceCount)
    }

    @Test("Recycled sprite, rope and trail data matches fresh storage", arguments: ["sprite", "rope", "ropetrail"])
    func recycledOutput(renderer: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEParticleCPUStoragePool()
        let definition = definition(renderer: renderer)
        var first: WPEParticleSystem? = try system(device, definition: definition, pool: pool)
        for frame in 0 ... 100 {
            first?.tick(now: Double(frame) / 60)
        }
        let storage = try #require(first).cpuStorageIdentity
        withExtendedLifetime(first) {}
        first = nil
        let reused = try system(device, definition: definition, seed: 321, pool: pool)
        let fresh = try system(device, definition: definition, seed: 321, pool: nil)
        #expect(reused.cpuStorageIdentity == storage)
        for frame in 0 ... 180 {
            reused.tick(now: Double(frame) / 60)
            fresh.tick(now: Double(frame) / 60)
            #expect(reused.liveInstanceCount == fresh.liveInstanceCount)
            #expect(reused.ropeVertexCount == fresh.ropeVertexCount)
            if reused.usesRibbonGeometry {
                let count = reused.ropeVertexCount * MemoryLayout<WPEParticleRopeVertex>.stride
                if count > 0 {
                    let a = try #require(reused.ropeVertexBuffer)
                    let b = try #require(fresh.ropeVertexBuffer)
                    #expect(Data(bytes: a.contents(), count: count) == Data(bytes: b.contents(), count: count))
                }
            } else {
                let count = reused.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
                #expect(Data(bytes: reused.instanceBuffer.contents(), count: count)
                    == Data(bytes: fresh.instanceBuffer.contents(), count: count))
            }
        }
    }

    @Test("Retention byte cap and zero-cache mode bound idle storage")
    func boundedRetention() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let key = WPEParticleCPUStorage.Key(capacity: 8, trailSamples: 0)
        let bytes = WPEParticleCPUStorage(key: key).payloadBytes
        for limit in [0, bytes] {
            let pool = WPEParticleCPUStoragePool(maximumRetainedBytes: limit)
            var a: WPEParticleSystem? = try system(device, definition: definition(capacity: 8), pool: pool)
            var b: WPEParticleSystem? = try system(device, definition: definition(capacity: 8), pool: pool)
            withExtendedLifetime((a, b)) {}
            a = nil
            b = nil
            #expect(pool.stats.retainedBytes <= limit)
            #expect(pool.stats.retainedStorages == (limit == 0 ? 0 : 1))
            pool.trim()
            #expect(pool.stats.retainedStorages == 0)
        }
    }
}
