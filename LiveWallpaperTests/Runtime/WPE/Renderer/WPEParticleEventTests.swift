#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Particle identity and immutable lifecycle observations", .serialized)
struct WPEParticleEventTests {
    @Test func naturalExpiryKeepsItsBirthIdentityAndEventsRemainOrdered() throws {
        let system = try system(capacity: 1, rate: 60, lifetime: 0.001)
        system.beginRecordingParticleEvents()
        system.tick(now: 0)
        system.tick(now: 1.0 / 60)
        let events = system.particleEventsThisTick
        #expect(events.map(\.kind) == [.spawn, .death])
        let birth = try #require(events.first)
        let death = try #require(events.last)
        #expect(birth.particle.identity == death.particle.identity)
        #expect(birth.particle.age == 0)
        #expect(death.particle.age == death.particle.lifetime)
        #expect(system.snapshot(for: birth.particle.identity) == nil)
        #expect(events.map(\.simulationTime) == events.map(\.simulationTime).sorted())
        system.tick(now: 2.0 / 60)
        #expect(system.particleEventsThisTick.first?.particle.identity.generation == birth.particle.identity.generation + 1)
        #expect(birth.particle.age == 0, "Recycling must not mutate a saved event")
    }

    @Test func clearInvalidatesFollowersWithoutResettingGenerationOrSynthesizingDeath() throws {
        let system = try system(capacity: 1, rate: 60, lifetime: 10)
        system.beginRecordingParticleEvents()
        system.tick(now: 0)
        system.tick(now: 1.0 / 60)
        let first = try #require(system.primaryLiveParticleIdentity)
        #expect(system.snapshot(for: first) != nil)
        system.clearLiveParticles()
        #expect(system.primaryLiveParticleIdentity == nil)
        #expect(system.particleEventsThisTick.isEmpty)
        #expect(system.snapshot(for: first) == nil)
        system.tick(now: 2.0 / 60)
        let next = try #require(system.primaryLiveParticleIdentity)
        #expect(next.slot == first.slot && next.generation > first.generation)
        #expect(system.snapshot(for: first) == nil)
        #expect(system.snapshot(for: .init(slot: -1, generation: 1)) == nil)
        #expect(system.snapshot(for: .init(slot: system.capacity, generation: 1)) == nil)
    }

    @Test func observingEventsDoesNotChangeSeededSimulationOrUploadedInstances() throws {
        let ordinary = try system(capacity: 8, rate: 120, lifetime: 0.2)
        let observed = try system(capacity: 8, rate: 120, lifetime: 0.2)
        observed.beginRecordingParticleEvents()
        for step in 0 ... 40 {
            let time = Double(step) / 60
            ordinary.tick(now: time)
            observed.tick(now: time)
            #expect(ordinary.liveInstanceCount == observed.liveInstanceCount)
            let bytes = ordinary.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
            #expect(Data(bytes: ordinary.instanceBuffer.contents(), count: bytes)
                == Data(bytes: observed.instanceBuffer.contents(), count: bytes))
            #expect(ordinary.particleEventsThisTick.isEmpty)
        }
    }

    @Test func eventStorageIsBoundedAndOverflowIsObservable() throws {
        let system = try system(capacity: WPEParticleSystem.absoluteCap, rate: 1e9, lifetime: 0.0001)
        system.beginRecordingParticleEvents()
        system.tick(now: 0)
        system.tick(now: 0.1)
        #expect(system.particleEventsThisTick.count == WPEParticleSystem.maximumRecordedParticleEvents)
        #expect(system.droppedParticleEventsThisTick > 0)
        system.tick(now: 0.1)
        // The existing continuous emitter may retain one token after a full pool.
        // A zero-dt publication must preserve that birth while resetting overflow.
        #expect(system.particleEventsThisTick.count <= 1)
        #expect(system.droppedParticleEventsThisTick == 0)
    }

    private func system(capacity: Int, rate: Double, lifetime: Double) throws -> WPEParticleSystem {
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": capacity,
            "emitter": [["rate": rate, "distancemin": 1, "distancemax": 4]],
            "initializer": [["name": "lifetimerandom", "min": lifetime, "max": lifetime],
                            ["name": "velocityrandom", "min": "-1 -2 0", "max": "3 4 0"]],
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try #require(WPEParticleSystem(definition: definition, device: device, seed: 0x12AB_34CD))
    }
}
#endif
