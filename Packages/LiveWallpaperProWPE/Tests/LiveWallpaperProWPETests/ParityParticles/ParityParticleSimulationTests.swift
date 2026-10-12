@testable import LiveWallpaperProWPE
import XCTest

final class ParityParticleSimulationTests: XCTestCase {
    private func system(_ text: String, rng: WPEParityMT19937 = WPEParityMT19937()) -> WPEParityParticleSystem {
        WPEParityParticleSystem(json: ParityParticleTestSupport.json(text), rng: rng)
    }

    func testDyingParticleFreesItsSlotForThisFramesEmitAndNewbornMoves() {
        var particles = system("""
        {"maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 20, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05},
                         {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}],
         "operator": [{"name": "movement"}]}
        """)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 1)
        XCTAssertEqual(particles.age[0], 0)
        XCTAssertEqual(particles.position[0].x, 1, accuracy: 1e-6)
        particles.advance(dt: 0.1)
        // The first particle (age 0.1 > 0.05) dies before this frame's emit, which reuses slot 0.
        XCTAssertEqual(particles.liveCount, 1)
        XCTAssertEqual(particles.age[0], 0)
        XCTAssertEqual(particles.position[0].x, 1, accuracy: 1e-6)
        XCTAssertEqual(particles.lifetime.count, 1)
    }

    func testOperatorsResetToInitialValuesEveryStep() {
        var particles = system("""
        {"maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
         "operator": [{"name": "sizechange", "startvalue": 1, "endvalue": 0},
                      {"name": "sizechange", "startvalue": 1, "endvalue": 0}]}
        """)
        particles.advance(dt: 1)
        // t = 0 on the birth frame: both ramps are 1 and the birth size is 0.5.
        XCTAssertEqual(particles.size[0], 0.5)
        particles.advance(dt: 5)
        // t = 0.5: two sizechange entries multiply once each, from the reset initial size.
        XCTAssertEqual(particles.size[0], 0.5 * 0.5 * 0.5, accuracy: 1e-6)
        particles.advance(dt: 0.5)
        XCTAssertEqual(particles.size[0], 0.5 * 0.45 * 0.45, accuracy: 1e-6)
    }

    func testStartTimePrewarmStepDependsOnMaxCount() {
        let small = system("""
        {"maxcount": 100, "starttime": 0.12,
         "emitter": [{"name": "sphererandom", "rate": 10}]}
        """)
        XCTAssertEqual(small.prewarmStep, 0.05)
        XCTAssertEqual(small.prewarmStepCount, 3)
        XCTAssertEqual(small.liveCount, 1)

        let large = system("""
        {"maxcount": 500, "starttime": 0.3,
         "emitter": [{"name": "sphererandom", "rate": 10}]}
        """)
        XCTAssertEqual(large.prewarmStep, 0.2)
        XCTAssertEqual(large.prewarmStepCount, 2)
        XCTAssertEqual(large.liveCount, 4)
    }

    func testBurstIsClampedToMaxCountAndExcessIsDropped() {
        var particles = system("""
        {"maxcount": 10,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 50}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05}]}
        """)
        particles.advance(dt: 0.01)
        XCTAssertEqual(particles.liveCount, 10)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 0)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 0)
    }

    func testDelayAndDurationGateEmission() {
        var particles = system("""
        {"maxcount": 100,
         "emitter": [{"name": "sphererandom", "rate": 4, "delay": 0.5, "duration": 0.5}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """)
        particles.advance(dt: 0.25)
        particles.advance(dt: 0.25)
        XCTAssertEqual(particles.liveCount, 0)
        for _ in 0 ..< 10 {
            particles.advance(dt: 0.25)
        }
        XCTAssertEqual(particles.liveCount, 2)
    }

    func testEveryEmitterRuns() {
        var particles = system("""
        {"maxcount": 100,
         "emitter": [{"name": "sphererandom", "rate": 10}, {"name": "boxrandom", "rate": 20}]}
        """)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 3)
    }

    func testInstanceRateScalesTheFrameStep() {
        var particles = WPEParityParticleSystem(
            json: ParityParticleTestSupport.json("""
            {"maxcount": 100, "emitter": [{"name": "sphererandom", "rate": 10}],
             "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
            """),
            instanceOverride: WPESceneParticleInstanceOverride(rate: 2),
            rng: WPEParityMT19937()
        )
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 2)
        XCTAssertEqual(particles.age[0], 0)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 4)
        XCTAssertEqual(particles.age[0], 0.2)
    }

    func testUnknownComponentsAreReported() {
        let particles = system("""
        {"maxcount": 1,
         "initializer": [{"name": "turbulentvelocityrandom"}],
         "operator": [{"name": "vortex"}, {"name": "movement"}]}
        """)
        XCTAssertTrue(particles.diagnostics.contains { $0.contains("turbulentvelocityrandom") })
        XCTAssertTrue(particles.diagnostics.contains { $0.contains("vortex") })
        XCTAssertFalse(particles.diagnostics.contains { $0.contains("movement") })
    }

    func testEventDeathChildSpawnsAtTheDeathPosition() {
        let child = """
        {"maxcount": 4, "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 4, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 1}]}
        """
        var particles = WPEParityParticleSystem(
            json: ParityParticleTestSupport.json("""
            {"maxcount": 1,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05},
                             {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}],
             "operator": [{"name": "movement"}],
             "children": [{"name": "child.json", "type": "eventdeath", "probability": 1}]}
            """),
            rng: WPEParityMT19937(),
            resolveChild: { $0 == "child.json" ? ParityParticleTestSupport.json(child) : nil }
        )
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.eventChildren[0].count, 0)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 0)
        XCTAssertEqual(particles.eventChildren[0].count, 1)
        let spawned = particles.eventChildren[0][0]
        XCTAssertEqual(spawned.liveCount, 4)
        XCTAssertEqual(spawned.position[0].x, 1, accuracy: 1e-6)
    }

    func testTimingThousandParticleSphereSystem() {
        var particles = system("""
        {"maxcount": 1000,
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 50, "speedmin": 10, "speedmax": 20}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 1}],
         "operator": [{"name": "movement", "gravity": "0 -10 0", "drag": 0.1},
                      {"name": "alphafade"}, {"name": "sizechange"}]}
        """)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< 600 {
            particles.advance(dt: 1.0 / 60)
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print(String(format: "particle timing: 1000 sphererandom, 600 frames, %.1f ms", milliseconds))
        XCTAssertGreaterThan(particles.liveCount, 900)
    }
}
