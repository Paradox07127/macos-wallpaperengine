@testable import LiveWallpaperProWPE
import XCTest

final class ParityParticleVertexTests: XCTestCase {
    private typealias Support = ParityParticleTestSupport

    private func threeParticles(renderers: String,
                                material: WPEParityParticleMaterial = .init()) -> WPEParityParticleSystem {
        var particles = WPEParityParticleSystem(
            json: Support.json("""
            {"maxcount": 3,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 3, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                             {"name": "sizerandom", "min": 4, "max": 4},
                             {"name": "colorrandom", "min": "0 128 255", "max": "0 128 255"},
                             {"name": "alpharandom", "min": 0.5, "max": 0.5},
                             {"name": "rotationrandom"},
                             {"name": "velocityrandom", "min": "-10 -10 0", "max": "10 10 0"}],
             "operator": [{"name": "movement"}],
             "renderer": [\(renderers)]}
            """),
            rng: WPEParityMT19937(),
            material: material
        )
        particles.advance(dt: 0.1)
        particles.advance(dt: 0.4)
        XCTAssertEqual(particles.liveCount, 3)
        return particles
    }

    private func vec4(_ value: SIMD3<Float>, _ w: Float) -> [Float] {
        [value.x, value.y, value.z, w]
    }

    private func rendererCaseSystem(_ renderer: String?) -> WPEParityParticleSystem {
        let field = renderer.map { ", \"renderer\": \($0)" } ?? ""
        var system = WPEParityParticleSystem(
            json: Support.json("""
            {"maxcount": 1,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}]\(field)}
            """), rng: WPEParityMT19937()
        )
        system.advance(dt: 0.1)
        return system
    }

    func testMissingRendererDrawsOneDefaultSprite() throws {
        var system = rendererCaseSystem(nil)
        XCTAssertEqual(system.liveCount, 1)
        XCTAssertEqual(system.renderers.map(\.kind), [.sprite])
        let batches = system.drawBatches(objectID: "owner")
        XCTAssertEqual(batches.count, 1)
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batch.vertices.count, 1)
        XCTAssertEqual(batch.vertices.stride, 44)
        XCTAssertEqual(batch.vertices.bytes.count, 44)
    }

    func testNonArrayRendererDrawsTheDefaultSprite() throws {
        for renderer in ["null", "false", "5", #""rope""#, #"{"name": "rope"}"#] {
            var system = rendererCaseSystem(renderer)
            XCTAssertEqual(system.liveCount, 1, renderer)
            XCTAssertEqual(system.renderers.map(\.kind), [.sprite], renderer)
            let batches = system.drawBatches(objectID: "owner")
            XCTAssertEqual(batches.count, 1, renderer)
            let batch = try XCTUnwrap(batches.first, renderer)
            XCTAssertEqual(batch.vertices.count, 1, renderer)
            XCTAssertEqual(batch.vertices.stride, 44, renderer)
        }
    }

    func testExplicitEmptyRendererKeepsLiveParticlesWithoutAnyDraw() {
        var system = rendererCaseSystem("[]")
        XCTAssertEqual(system.liveCount, 1)
        XCTAssertTrue(system.renderers.isEmpty)
        XCTAssertTrue(system.drawBatches(objectID: "owner").isEmpty)
    }

    func testSpriteVertexIs44BytesPerLiveSlot() {
        var particles = threeParticles(renderers: #"{"name": "sprite"}"#)
        let batch = particles.vertices(for: particles.renderers[0])
        XCTAssertEqual(batch.stride, 44)
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch.bytes.count, 132)
        XCTAssertEqual(batch.renderVar0, WPEParityRenderVar0())
        for slot in 0 ..< 3 {
            let base = slot * 44
            let expected = [particles.position[slot].x, particles.position[slot].y, particles.position[slot].z]
                + vec4(particles.rotation[slot], particles.size[slot])
                + vec4(particles.color[slot], particles.alpha[slot])
            XCTAssertEqual(Support.floats(batch.bytes, at: base, count: 11), expected)
        }
        XCTAssertEqual(particles.size[0], 2)
        XCTAssertEqual(particles.color[0], SIMD3<Float>(0, 128.0 / 255, 1))
        XCTAssertEqual(particles.alpha[0], 0.5)
    }

    func testSpriteTrailMakesTheSharedMainBufferThick() {
        var particles = threeParticles(renderers: #"{"name": "sprite"}, {"name": "spritetrail"}"#)
        let sprite = particles.vertices(for: particles.renderers[0])
        let trail = particles.vertices(for: particles.renderers[1])
        XCTAssertEqual(sprite.stride, 60)
        XCTAssertEqual(trail.stride, 60)
        XCTAssertEqual(sprite.bytes, trail.bytes)
        XCTAssertEqual(trail.count, 3)
        XCTAssertEqual(trail.renderVar0, WPEParityRenderVar0(x: 0.05, y: 10, z: 0))
        for slot in 0 ..< 3 {
            let base = slot * 60
            let life = particles.age[slot] / particles.lifetime[slot]
            let expected = [particles.position[slot].x, particles.position[slot].y, particles.position[slot].z]
                + vec4(particles.rotation[slot], particles.size[slot])
                + vec4(particles.color[slot], particles.alpha[slot])
                + vec4(particles.velocity[slot], life)
            XCTAssertEqual(Support.floats(trail.bytes, at: base, count: 15), expected)
        }
        XCTAssertEqual(particles.combos(for: particles.renderers[0]), ["THICKFORMAT": 1])
        XCTAssertEqual(particles.combos(for: particles.renderers[1]), ["THICKFORMAT": 1, "TRAILRENDERER": 1])
    }

    func testSequenceMultiplierScalesTheThickBufferPhase() {
        var particles = WPEParityParticleSystem(
            json: Support.json("""
            {"maxcount": 1, "sequencemultiplier": 2,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 1, "max": 1}],
             "renderer": [{"name": "spritetrail"}]}
            """),
            rng: WPEParityMT19937()
        )
        particles.advance(dt: 0.1)
        particles.advance(dt: 0.5)
        XCTAssertEqual(particles.age[0], 0.5)
        let batch = particles.vertices(for: particles.renderers[0])
        XCTAssertEqual(batch.stride, 60)
        // POSITION f3, TEXCOORD0 f4, COLOR f4, then TEXCOORD1 (velocity, phase).
        XCTAssertEqual(Support.float(batch.bytes, at: 56), 1)
    }

    func testRopeWritesOneSegmentPerNeighbourPairInBirthOrder() {
        var particles = threeParticles(renderers: #"{"name": "rope"}"#)
        let batch = particles.vertices(for: particles.renderers[0])
        XCTAssertEqual(batch.stride, 96)
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.bytes.count, 192)
        XCTAssertEqual(batch.renderVar0, WPEParityRenderVar0(z: 0, w: 3))
        let p = particles.position, s = particles.size
        let first = vec4(p[0], s[0]) + vec4(p[1], 3) + vec4(p[0], 0) + vec4(p[2], s[1])
            + vec4(particles.color[1], particles.alpha[1]) + vec4(particles.color[0], particles.alpha[0])
        XCTAssertEqual(Support.floats(batch.bytes, at: 0, count: 24), first)
        let second = vec4(p[1], s[1]) + vec4(p[2], 3) + vec4(p[0], 1) + vec4(p[2], s[2])
            + vec4(particles.color[2], particles.alpha[2]) + vec4(particles.color[1], particles.alpha[1])
        XCTAssertEqual(Support.floats(batch.bytes, at: 96, count: 24), second)
        XCTAssertEqual(particles.shaderOverride, "genericropeparticle")
        XCTAssertEqual(
            particles.combos(for: particles.renderers[0]),
            ["THICKFORMAT": 1, "TRAILSUBDIVISION": 4, "ORIENTATION": 0]
        )
    }

    func testRopeTrailWritesSegmentsVerticesPerParticle() {
        var particles = threeParticles(renderers: #"{"name": "ropetrail", "segments": 4, "length": 0.4}"#)
        let batch = particles.vertices(for: particles.renderers[0])
        XCTAssertEqual(batch.stride, 76)
        XCTAssertEqual(batch.count, 12)
        XCTAssertEqual(batch.bytes.count, 12 * 76)
        XCTAssertEqual(batch.renderVar0.w, 3.5)
        XCTAssertNil(batch.renderVar0.x)
        XCTAssertNotNil(batch.renderVar0.z)
        XCTAssertNil(particles.shaderOverride)
        let p0 = particles.position[0]
        let head = Support.floats(batch.bytes, at: 0, count: 19)
        XCTAssertEqual(Array(head[0 ..< 4]), vec4(p0, particles.size[0]))
        XCTAssertEqual(head[7], 2) // two history samples were pushed (t = 0.1, 0.5)
        XCTAssertEqual(head[11], 0)
        XCTAssertEqual(Array(head[15 ..< 19]), vec4(particles.color[0], particles.alpha[0]))
        XCTAssertEqual(Support.float(batch.bytes, at: 76 + 7 * 4), 2)
        XCTAssertEqual(Support.float(batch.bytes, at: 76 + 11 * 4), 1)
        XCTAssertEqual(
            particles.combos(for: particles.renderers[0]),
            ["TRAILRENDERER": 1, "TRAILSUBDIVISION": 1, "ORIENTATION": 0]
        )
    }

    func testStaticCombosEqualTheSystemCombosForEveryRendererKind() {
        let sheet = WPEParityParticleMaterial(spriteSheet: true, spriteSheetNPOT: true, texture0Format: 8)
        let renderers = [
            #"{"name": "sprite"}"#, #"{"name": "sprite"}, {"name": "spritetrail"}"#, #"{"name": "rope"}"#,
            #"{"name": "ropetrail", "segments": 4, "uvscrolling": 1, "fadealpha": 1, "fadesize": 1}"#,
        ]
        for json in renderers {
            for material in [WPEParityParticleMaterial(), sheet] {
                let particles = threeParticles(renderers: json, material: material)
                for renderer in particles.renderers {
                    XCTAssertEqual(
                        WPEParityParticleSystem.combos(config: particles.config, material: material, renderer: renderer),
                        particles.combos(for: renderer), json
                    )
                }
                XCTAssertEqual(WPEParityParticleSystem.shaderOverride(renderers: particles.renderers),
                               particles.shaderOverride, json)
            }
        }
        let sheetSprite = threeParticles(renderers: #"{"name": "sprite"}"#, material: sheet)
        XCTAssertEqual(sheetSprite.combos(for: sheetSprite.renderers[0]), [
            "THICKFORMAT": 1, "SPRITESHEET": 1, "SPRITESHEETBLEND": 1, "SPRITESHEETBLENDNPOT": 1, "TEX0FORMAT": 8,
        ])
    }
}
